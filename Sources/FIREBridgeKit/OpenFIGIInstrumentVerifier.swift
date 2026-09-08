#if os(macOS)
import Foundation

public actor OpenFIGIInstrumentVerifier: InstrumentVerifying {
    private struct MappingJob: Encodable {
        let idType: String
        let idValue: String
        let micCode: String?
        let exchCode: String?
    }

    private struct MappingResponse: Decodable {
        let data: [MappingItem]?
        let warning: String?
        let error: String?
    }

    private struct MappingItem: Decodable {
        let figi: String
        let name: String?
        let ticker: String?
        let exchCode: String?
        let compositeFIGI: String?
        let securityType: String?
        let marketSector: String?
        let securityType2: String?
    }

    private struct MappingPlan {
        let positionIndex: Int
        let job: MappingJob
        let canonicalCode: String
    }

    private static let sourceName = "OpenFIGI"
    private static let anonymousBatchLimit = 10

    private let session: URLSession
    private let endpoint: URL
    private let apiKey: String?

    public init(
        session: URLSession? = nil,
        endpoint: URL = URL(string: "https://api.openfigi.com/v3/mapping")!,
        apiKey: String? = ProcessInfo.processInfo.environment[
            "OPENFIGI_API_KEY"
        ]
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.urlCache = URLCache(
                memoryCapacity: 2 * 1_024 * 1_024,
                diskCapacity: 0
            )
            self.session = URLSession(configuration: configuration)
        }
        self.endpoint = endpoint
        self.apiKey = apiKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty
    }

    public func verify(
        positions: [RecognizedAssetPositionV1]
    ) async -> [RecognizedAssetPositionV1] {
        var results = positions
        var plans: [MappingPlan] = []

        for (index, position) in positions.enumerated() {
            if position.kind == .cash {
                results[index] = enriched(
                    position,
                    verification: InstrumentVerificationV1(
                        status: .notApplicable,
                        sourceName: Self.sourceName,
                        message: "现金无需证券身份校验。"
                    )
                )
                continue
            }
            guard let code = position.productCode?.nilIfEmpty,
                  let plan = mappingPlan(
                      positionIndex: index,
                      code: code,
                      currency: position.currency
                  ) else {
                results[index] = enriched(
                    position,
                    verification: InstrumentVerificationV1(
                        status: .notFound,
                        sourceName: Self.sourceName,
                        message: "缺少可用于 OpenFIGI 映射的产品代码。"
                    )
                )
                continue
            }
            plans.append(plan)
        }

        for start in stride(
            from: 0,
            to: plans.count,
            by: Self.anonymousBatchLimit
        ) {
            let end = min(start + Self.anonymousBatchLimit, plans.count)
            let batch = Array(plans[start..<end])
            do {
                let responses = try await map(batch.map(\.job))
                guard responses.count == batch.count else {
                    throw URLError(.cannotParseResponse)
                }
                for (plan, response) in zip(batch, responses) {
                    results[plan.positionIndex] = resolve(
                        position: results[plan.positionIndex],
                        canonicalCode: plan.canonicalCode,
                        response: response
                    )
                }
            } catch {
                for plan in batch {
                    results[plan.positionIndex] = enriched(
                        results[plan.positionIndex],
                        verification: InstrumentVerificationV1(
                            status: .unavailable,
                            sourceName: Self.sourceName,
                            message: "OpenFIGI 联网校验暂不可用，已保留截图代码。"
                        )
                    )
                }
            }
        }

        return results
    }

    private func map(
        _ jobs: [MappingJob]
    ) async throws -> [MappingResponse] {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 12
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "FIRE-Freedom/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-OPENFIGI-APIKEY")
        }
        request.httpBody = try JSONEncoder().encode(jobs)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([MappingResponse].self, from: data)
    }

    private func mappingPlan(
        positionIndex: Int,
        code: String,
        currency: RecognizedAssetCurrencyV1
    ) -> MappingPlan? {
        let prepared = code
            .precomposedStringWithCompatibilityMapping
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHongKongSuffix = prepared.hasSuffix(".HK")
            || prepared.hasPrefix("HK.")
        let bareCode = prepared
            .replacingOccurrences(of: ".HK", with: "")
            .replacingOccurrences(of: "HK.", with: "")
            .filter { $0.isLetter || $0.isNumber }
        guard !bareCode.isEmpty else { return nil }

        if bareCode.allSatisfy(\.isNumber),
           hasHongKongSuffix
                || currency == .HKD
                || (4...5).contains(bareCode.count) {
            let ticker = bareCode.drop(while: { $0 == "0" })
            let idValue = ticker.isEmpty ? "0" : String(ticker)
            return MappingPlan(
                positionIndex: positionIndex,
                job: MappingJob(
                    idType: "TICKER",
                    idValue: idValue,
                    micCode: "XHKG",
                    exchCode: nil
                ),
                canonicalCode: bareCode.leftPadded(to: 5, with: "0")
            )
        }

        if bareCode.count == 6, bareCode.allSatisfy(\.isNumber) {
            let micCode: String
            switch bareCode.first {
            case "5", "6", "9":
                micCode = "XSHG"
            case "4", "8":
                micCode = "XBEI"
            default:
                micCode = "XSHE"
            }
            return MappingPlan(
                positionIndex: positionIndex,
                job: MappingJob(
                    idType: "TICKER",
                    idValue: bareCode,
                    micCode: micCode,
                    exchCode: nil
                ),
                canonicalCode: bareCode
            )
        }

        return MappingPlan(
            positionIndex: positionIndex,
            job: MappingJob(
                idType: "TICKER",
                idValue: bareCode,
                micCode: nil,
                exchCode: currency == .HKD ? "HK" : "US"
            ),
            canonicalCode: bareCode
        )
    }

    private func resolve(
        position: RecognizedAssetPositionV1,
        canonicalCode: String,
        response: MappingResponse
    ) -> RecognizedAssetPositionV1 {
        let compatible = (response.data ?? []).filter {
            isCompatible($0, with: position.kind)
        }
        let unique = Dictionary(
            compatible.map {
                (($0.compositeFIGI ?? $0.figi), $0)
            },
            uniquingKeysWith: { first, _ in first }
        ).values

        guard unique.count == 1, let match = unique.first else {
            let status: InstrumentVerificationStatusV1 = unique.isEmpty
                ? .notFound
                : .ambiguous
            let detail: String
            if status == .ambiguous {
                detail = "OpenFIGI 返回多个证券身份，已保留截图代码等待确认。"
            } else if response.error != nil || response.warning != nil {
                detail = "OpenFIGI 未找到该代码，已保留截图代码等待其他目录校验。"
            } else {
                detail = "OpenFIGI 未找到该代码，已保留截图代码。"
            }
            return enriched(
                position,
                code: canonicalCode,
                verification: InstrumentVerificationV1(
                    status: status,
                    sourceName: Self.sourceName,
                    message: detail
                )
            )
        }

        let matchedName = match.name?.nilIfEmpty ?? position.productName
        let matchedKind = recognizedKind(
            for: match,
            fallback: position.kind
        )
        let matchedCurrency = recognizedCurrency(
            exchangeCode: match.exchCode,
            fallback: position.currency
        )
        return RecognizedAssetPositionV1(
            imageIndex: position.imageIndex,
            productName: position.productName,
            productCode: canonicalCode,
            kind: matchedKind,
            currency: matchedCurrency,
            originalMarketValue: position.originalMarketValue,
            confidence: position.confidence,
            evidence: position.evidence,
            verification: InstrumentVerificationV1(
                status: .verified,
                sourceName: Self.sourceName,
                matchedName: matchedName,
                matchedCode: canonicalCode,
                message: "截图代码已通过 OpenFIGI 证券身份映射；保留截图中的产品名称。"
            )
        )
    }

    private func isCompatible(
        _ item: MappingItem,
        with kind: RecognizedAssetKindV1
    ) -> Bool {
        let recognized = recognizedKind(for: item, fallback: kind)
        return recognized == kind
            || (kind == .stock && recognized == .fund)
            || (kind == .fund && recognized == .stock)
    }

    private func recognizedKind(
        for item: MappingItem,
        fallback: RecognizedAssetKindV1
    ) -> RecognizedAssetKindV1 {
        let description = [
            item.securityType,
            item.securityType2,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .uppercased()
        if description.contains("ETP")
            || description.contains("FUND")
            || description.contains("ETF") {
            return .fund
        }
        if item.marketSector?.uppercased() == "EQUITY" {
            return .stock
        }
        return fallback
    }

    private func recognizedCurrency(
        exchangeCode: String?,
        fallback: RecognizedAssetCurrencyV1
    ) -> RecognizedAssetCurrencyV1 {
        switch exchangeCode?.uppercased() {
        case "HK":
            return .HKD
        case "US", "UN", "UW", "UR":
            return .USD
        case "CS", "CG":
            return .CNY
        default:
            return fallback
        }
    }

    private func enriched(
        _ position: RecognizedAssetPositionV1,
        code: String? = nil,
        verification: InstrumentVerificationV1
    ) -> RecognizedAssetPositionV1 {
        RecognizedAssetPositionV1(
            imageIndex: position.imageIndex,
            productName: position.productName,
            productCode: code ?? position.productCode,
            kind: position.kind,
            currency: position.currency,
            originalMarketValue: position.originalMarketValue,
            confidence: position.confidence,
            evidence: position.evidence,
            verification: verification
        )
    }
}

public struct LayeredInstrumentVerifier: InstrumentVerifying {
    private let verifiers: [any InstrumentVerifying]

    public init(verifiers: [any InstrumentVerifying]) {
        self.verifiers = verifiers
    }

    public func verify(
        positions: [RecognizedAssetPositionV1]
    ) async -> [RecognizedAssetPositionV1] {
        var results = positions

        for verifier in verifiers {
            let unresolvedIndices = results.indices.filter {
                !Self.isFinal(results[$0].verification?.status)
            }
            guard !unresolvedIndices.isEmpty else { break }

            let candidates = await verifier.verify(
                positions: unresolvedIndices.map { results[$0] }
            )
            guard candidates.count == unresolvedIndices.count else {
                continue
            }
            for (index, candidate) in zip(unresolvedIndices, candidates) {
                if Self.rank(candidate.verification?.status)
                    > Self.rank(results[index].verification?.status) {
                    results[index] = candidate
                }
            }
        }

        return results
    }

    private static func isFinal(
        _ status: InstrumentVerificationStatusV1?
    ) -> Bool {
        status == .verified
            || status == .ambiguous
            || status == .notApplicable
    }

    private static func rank(
        _ status: InstrumentVerificationStatusV1?
    ) -> Int {
        switch status {
        case .verified, .notApplicable:
            return 4
        case .ambiguous:
            return 3
        case .notFound:
            return 2
        case .unavailable:
            return 1
        case nil:
            return 0
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}
#endif
