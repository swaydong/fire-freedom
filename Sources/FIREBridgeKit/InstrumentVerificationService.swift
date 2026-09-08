#if os(macOS)
import Foundation

public protocol InstrumentVerifying: Sendable {
    func verify(
        positions: [RecognizedAssetPositionV1]
    ) async -> [RecognizedAssetPositionV1]
}

public struct PassthroughInstrumentVerifier: InstrumentVerifying {
    public init() {}

    public func verify(
        positions: [RecognizedAssetPositionV1]
    ) async -> [RecognizedAssetPositionV1] {
        positions
    }
}

public actor EastmoneyInstrumentVerifier: InstrumentVerifying {
    private struct SearchResponse: Decodable {
        let ErrCode: Int
        let Datas: [SearchItem]?
    }

    private struct SearchItem: Decodable {
        let CODE: String?
        let NAME: String?
        let CATEGORYDESC: String?
        let STOCKMARKET: String?
        let NEWTEXCH: String?
        let FundBaseInfo: FundBaseInfo?
    }

    private struct FundBaseInfo: Decodable {
        let OTHERNAME: String?
    }

    private static let sourceName = "东方财富产品搜索"

    private let session: URLSession
    private let endpoint: URL

    public init(
        session: URLSession? = nil,
        endpoint: URL = URL(
            string: "https://fundsuggest.eastmoney.com/FundSearch/api/FundSearchAPI.ashx"
        )!
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.urlCache = URLCache(
                memoryCapacity: 2 * 1_024 * 1_024,
                diskCapacity: 0
            )
            self.session = URLSession(configuration: configuration)
        }
        self.endpoint = endpoint
    }

    public func verify(
        positions: [RecognizedAssetPositionV1]
    ) async -> [RecognizedAssetPositionV1] {
        var results: [RecognizedAssetPositionV1] = []
        results.reserveCapacity(positions.count)
        for position in positions {
            results.append(await verify(position))
        }
        return results
    }

    private func verify(
        _ position: RecognizedAssetPositionV1
    ) async -> RecognizedAssetPositionV1 {
        guard position.kind != .cash else {
            return enriched(
                position,
                verification: InstrumentVerificationV1(
                    status: .notApplicable,
                    sourceName: Self.sourceName,
                    message: "现金无需产品目录校验。"
                )
            )
        }

        let nameQuery = normalizedQuery(position.productName)
        let suppliedCode = position.productCode?.trimmedNonEmpty
        guard suppliedCode != nil || !nameQuery.isEmpty else {
            return enriched(
                position,
                verification: unavailable("产品名称或代码为空。")
            )
        }

        do {
            if let suppliedCode {
                let codeItems = try await search(
                    query: normalizeCode(suppliedCode),
                    kind: position.kind
                )
                .filter { isCompatible($0, with: position.kind) }
                let codeMatches = bestCodeMatches(
                    code: suppliedCode,
                    name: position.productName,
                    in: codeItems
                )
                if codeMatches.count == 1, let match = codeMatches.first {
                    return verifiedPosition(
                        position,
                        match: match,
                        kind: position.kind,
                        message: "名称和代码已与公开产品目录匹配。"
                    )
                }
                if codeMatches.count > 1 {
                    return enriched(
                        position,
                        verification: InstrumentVerificationV1(
                            status: .ambiguous,
                            sourceName: Self.sourceName,
                            message: "识别代码对应多个产品，名称仍无法唯一确认。"
                        )
                    )
                }
                return enriched(
                    position,
                    verification: InstrumentVerificationV1(
                        status: .notFound,
                        sourceName: Self.sourceName,
                        message: "公开产品目录未匹配截图中的代码；已保留原代码，不会按名称改写。"
                    )
                )
            }

            let primaryNameMatches = try await nameMatches(
                for: position.productName,
                kind: position.kind,
                allowPrefix: true
            )
            if primaryNameMatches.count == 1,
               let match = primaryNameMatches.first {
                return verifiedPosition(
                    position,
                    match: match,
                    kind: position.kind,
                    message: "名称和代码已与公开产品目录匹配。"
                )
            }
            if primaryNameMatches.count > 1 {
                return enriched(
                    position,
                    verification: InstrumentVerificationV1(
                        status: .ambiguous,
                        sourceName: Self.sourceName,
                        message: "产品名称对应多个可能结果，暂时无法确认具体份额。"
                    )
                )
            }

            if let alternateKind = alternateKind(for: position.kind) {
                let alternateMatches = try await nameMatches(
                    for: position.productName,
                    kind: alternateKind,
                    allowPrefix: false
                )
                if alternateMatches.count == 1,
                   let match = alternateMatches.first {
                    return verifiedPosition(
                        position,
                        match: match,
                        kind: alternateKind,
                        message: "识别类型未匹配，已按产品名称找到唯一结果并更正类型。"
                    )
                }
                if alternateMatches.count > 1 {
                    return enriched(
                        position,
                        verification: InstrumentVerificationV1(
                            status: .ambiguous,
                            sourceName: Self.sourceName,
                            message: "产品名称在其他类型目录中对应多个可能结果。"
                        )
                    )
                }
            }

            return enriched(
                position,
                verification: InstrumentVerificationV1(
                    status: .notFound,
                    sourceName: Self.sourceName,
                    message: "公开产品目录中没有找到匹配产品。"
                )
            )
        } catch {
            return enriched(
                position,
                verification: unavailable("联网校验暂不可用。")
            )
        }
    }

    private func search(
        query: String,
        kind: RecognizedAssetKindV1
    ) async throws -> [SearchItem] {
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            // m=9 limits results to funds. The broader m=1 search is needed
            // for A/H/US equities and is filtered again by market below.
            URLQueryItem(name: "m", value: kind == .fund ? "9" : "1"),
            URLQueryItem(name: "key", value: String(query.prefix(120))),
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 10
        )
        request.setValue(
            "FIRE-Freedom/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard decoded.ErrCode == 0 else {
            throw URLError(.cannotParseResponse)
        }
        return decoded.Datas ?? []
    }

    private func bestCodeMatches(
        code: String,
        name: String,
        in items: [SearchItem]
    ) -> [SearchItem] {
        let normalizedCode = normalizeCode(code)
        let exactCodeMatches = items.filter {
            guard let candidate = $0.CODE else { return false }
            return normalizeCode(candidate) == normalizedCode
        }
        if exactCodeMatches.count <= 1 {
            return exactCodeMatches
        }
        let normalizedName = normalizeName(name)
        let exactNameMatches = exactCodeMatches.filter {
            normalizedNames(for: $0).contains(normalizedName)
        }
        return exactNameMatches.isEmpty ? exactCodeMatches : exactNameMatches
    }

    private func bestNameMatches(
        name: String,
        in items: [SearchItem],
        allowPrefix: Bool
    ) -> [SearchItem] {
        let normalizedName = normalizeName(name)
        let primaryExactMatches = items.filter {
            guard let candidateName = $0.NAME else { return false }
            return normalizeName(candidateName) == normalizedName
        }
        if !primaryExactMatches.isEmpty {
            return uniqueItems(primaryExactMatches)
        }
        let aliasExactMatches = items.filter {
            normalizedAliases(for: $0).contains(normalizedName)
        }
        guard allowPrefix, normalizedName.count >= 6 else {
            return uniqueItems(aliasExactMatches)
        }
        let prefixMatches = items.filter {
            normalizedNames(for: $0).contains { candidate in
                candidate.hasPrefix(normalizedName)
                    || normalizedName.hasPrefix(candidate)
            }
        }
        return uniqueItems(aliasExactMatches + prefixMatches)
    }

    private func nameMatches(
        for name: String,
        kind: RecognizedAssetKindV1,
        allowPrefix: Bool
    ) async throws -> [SearchItem] {
        let query = normalizedQuery(name)
        guard !query.isEmpty else { return [] }
        let items = try await search(query: query, kind: kind)
            .filter { isCompatible($0, with: kind) }
        return bestNameMatches(
            name: name,
            in: items,
            allowPrefix: allowPrefix
        )
    }

    private func alternateKind(
        for kind: RecognizedAssetKindV1
    ) -> RecognizedAssetKindV1? {
        switch kind {
        case .fund:
            return .stock
        case .stock:
            return .fund
        case .cash:
            return nil
        }
    }

    private func isCompatible(
        _ item: SearchItem,
        with kind: RecognizedAssetKindV1
    ) -> Bool {
        let category = item.CATEGORYDESC ?? ""
        switch kind {
        case .fund:
            return category == "基金"
        case .stock:
            return Self.stockCategories.contains(category)
        case .cash:
            return false
        }
    }

    private static let stockCategories: Set<String> = [
        "沪市",
        "深市",
        "北交所",
        "京市",
        "港股",
        "美股",
    ]

    private func verifiedCurrency(
        category: String?,
        fallback: RecognizedAssetCurrencyV1
    ) -> RecognizedAssetCurrencyV1 {
        switch category {
        case "美股":
            return .USD
        case "港股":
            return .HKD
        default:
            return fallback
        }
    }

    private func normalizedQuery(_ value: String) -> String {
        value
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "⋯", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(
                in: .whitespacesAndNewlines.union(.punctuationCharacters)
            )
    }

    private func normalizeName(_ value: String) -> String {
        normalizedQuery(value)
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func normalizeCode(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .uppercased()
            .replacingOccurrences(of: ".HK", with: "")
            .replacingOccurrences(of: "HK.", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    private func normalizedNames(for item: SearchItem) -> Set<String> {
        Set(
            [item.NAME].compactMap { $0 }.map(normalizeName)
                + normalizedAliases(for: item)
        )
        .subtracting([""])
    }

    private func normalizedAliases(for item: SearchItem) -> [String] {
        let aliases = item.FundBaseInfo?.OTHERNAME?
            .split(separator: ",")
            .map(String.init) ?? []
        return aliases.map(normalizeName).filter { !$0.isEmpty }
    }

    private func uniqueItems(_ items: [SearchItem]) -> [SearchItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = [
                item.CATEGORYDESC ?? "",
                item.CODE.map(normalizeCode) ?? "",
                item.NAME.map(normalizeName) ?? "",
            ].joined(separator: "::")
            return seen.insert(key).inserted
        }
    }

    private func unavailable(_ message: String) -> InstrumentVerificationV1 {
        InstrumentVerificationV1(
            status: .unavailable,
            sourceName: Self.sourceName,
            message: message
        )
    }

    private func verifiedPosition(
        _ position: RecognizedAssetPositionV1,
        match: SearchItem,
        kind: RecognizedAssetKindV1,
        message: String
    ) -> RecognizedAssetPositionV1 {
        guard let matchedName = match.NAME?.trimmedNonEmpty,
              let matchedCode = match.CODE?.trimmedNonEmpty else {
            return enriched(
                position,
                verification: InstrumentVerificationV1(
                    status: .notFound,
                    sourceName: Self.sourceName,
                    message: "产品目录候选缺少名称或代码。"
                )
            )
        }
        return RecognizedAssetPositionV1(
            imageIndex: position.imageIndex,
            productName: matchedName,
            productCode: matchedCode.uppercased(),
            kind: kind,
            currency: verifiedCurrency(
                category: match.CATEGORYDESC,
                fallback: position.currency
            ),
            originalMarketValue: position.originalMarketValue,
            confidence: position.confidence,
            evidence: position.evidence,
            verification: InstrumentVerificationV1(
                status: .verified,
                sourceName: Self.sourceName,
                matchedName: matchedName,
                matchedCode: matchedCode.uppercased(),
                message: message
            )
        )
    }

    private func enriched(
        _ position: RecognizedAssetPositionV1,
        verification: InstrumentVerificationV1
    ) -> RecognizedAssetPositionV1 {
        RecognizedAssetPositionV1(
            imageIndex: position.imageIndex,
            productName: position.productName,
            productCode: position.productCode,
            kind: position.kind,
            currency: position.currency,
            originalMarketValue: position.originalMarketValue,
            confidence: position.confidence,
            evidence: position.evidence,
            verification: verification
        )
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
