#if os(macOS)
import Darwin
import Foundation

protocol AKShareProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data
    ) throws -> Data
}

struct FoundationAKShareProcessRunner: AKShareProcessRunning {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data
    ) throws -> Data {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.environment = Self.sanitizedEnvironment(
            ProcessInfo.processInfo.environment
        )
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
        try inputPipe.fileHandleForWriting.close()
        guard termination.wait(
            timeout: .now() + timeout
        ) == .success else {
            process.terminate()
            if termination.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
            throw AKShareProcessError.timedOut
        }
        guard process.terminationStatus == 0 else {
            throw AKShareProcessError.failed(process.terminationStatus)
        }
        return outputPipe.fileHandleForReading.readDataToEndOfFile()
    }

    static func sanitizedEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        var sanitized = environment
        sanitized.removeValue(forKey: "OPENAI_API_KEY")
        sanitized.removeValue(forKey: "CODEX_API_KEY")
        return sanitized
    }
}

private enum AKShareProcessError: Error {
    case failed(Int32)
    case timedOut
}

public actor AKShareInstrumentVerifier: InstrumentVerifying {
    private struct HelperRequest: Encodable {
        let positions: [HelperPosition]
    }

    private struct HelperPosition: Encodable {
        let productName: String
        let productCode: String?
        let currency: String
        let kind: String
    }

    private struct HelperResponse: Decodable {
        let results: [HelperResult]?
        let error: String?
    }

    private struct HelperResult: Decodable {
        let status: String
        let matchedName: String?
        let matchedCode: String?
        let currency: String?
        let kind: String?
    }

    private static let sourceName = "AKShare 港股目录"

    private let pythonExecutablePath: String?
    private let helperURL: URL?
    private let runner: any AKShareProcessRunning

    public init() {
        self.pythonExecutablePath = Self.trimmedNonEmpty(
            ProcessInfo.processInfo.environment["FIRE_AKSHARE_PYTHON"]
        )
        self.helperURL = Bundle.module.url(
            forResource: "akshare_instrument_helper",
            withExtension: "py"
        )
        self.runner = FoundationAKShareProcessRunner()
    }

    init(
        pythonExecutablePath: String?,
        helperURL: URL?,
        runner: any AKShareProcessRunning
    ) {
        self.pythonExecutablePath = Self.trimmedNonEmpty(
            pythonExecutablePath
        )
        self.helperURL = helperURL
        self.runner = runner
    }

    public func verify(
        positions: [RecognizedAssetPositionV1]
    ) async -> [RecognizedAssetPositionV1] {
        var outputs = positions
        let candidateIndices = positions.indices.filter {
            if positions[$0].kind == .cash {
                outputs[$0] = enriched(
                    positions[$0],
                    verification: InstrumentVerificationV1(
                        status: .notApplicable,
                        sourceName: Self.sourceName,
                        message: "现金无需 AKShare 产品目录校验。"
                    )
                )
                return false
            }
            return true
        }
        guard !candidateIndices.isEmpty else { return outputs }

        guard let pythonExecutablePath else {
            return markingUnavailable(
                outputs,
                at: candidateIndices,
                message: "未配置 FIRE_AKSHARE_PYTHON，已跳过 AKShare 校验。"
            )
        }
        guard pythonExecutablePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(
                  atPath: pythonExecutablePath
              ) else {
            return markingUnavailable(
                outputs,
                at: candidateIndices,
                message: "FIRE_AKSHARE_PYTHON 不是可执行的绝对路径，已跳过 AKShare 校验。"
            )
        }
        guard let helperURL else {
            return markingUnavailable(
                outputs,
                at: candidateIndices,
                message: "AKShare 本地校验组件不可用，已保留截图结果。"
            )
        }

        let request = HelperRequest(
            positions: candidateIndices.map { index in
                let position = positions[index]
                return HelperPosition(
                    productName: position.productName,
                    productCode: canonicalCode(
                        position.productCode,
                        currency: position.currency
                    ),
                    currency: position.currency.rawValue,
                    kind: position.kind.rawValue
                )
            }
        )

        do {
            let standardInput = try JSONEncoder().encode(request)
            let data = try runner.run(
                executableURL: URL(fileURLWithPath: pythonExecutablePath),
                arguments: [helperURL.path],
                standardInput: standardInput
            )
            let response = try JSONDecoder().decode(
                HelperResponse.self,
                from: data
            )
            guard response.error == nil,
                  let results = response.results,
                  results.count == candidateIndices.count else {
                throw AKShareProcessError.failed(-1)
            }
            for (index, result) in zip(candidateIndices, results) {
                outputs[index] = resolve(
                    position: positions[index],
                    result: result
                )
            }
            return outputs
        } catch {
            return markingUnavailable(
                outputs,
                at: candidateIndices,
                message: "AKShare 或其本地依赖不可用，已保留截图结果。"
            )
        }
    }

    private func resolve(
        position: RecognizedAssetPositionV1,
        result: HelperResult
    ) -> RecognizedAssetPositionV1 {
        let matchedCurrency = result.currency.flatMap(
            RecognizedAssetCurrencyV1.init(rawValue:)
        ) ?? position.currency
        let matchedKind = result.kind.flatMap(
            RecognizedAssetKindV1.init(rawValue:)
        ) ?? position.kind
        let matchedCode = canonicalCode(
            result.matchedCode,
            currency: matchedCurrency
        )

        switch result.status {
        case InstrumentVerificationStatusV1.verified.rawValue:
            guard let matchedCode else {
                return unavailable(position)
            }
            guard let suppliedCode = canonicalCode(
                position.productCode,
                currency: position.currency
            ) else {
                return enriched(
                    position,
                    verification: InstrumentVerificationV1(
                        status: .ambiguous,
                        sourceName: Self.sourceName,
                        matchedName: result.matchedName,
                        matchedCode: matchedCode,
                        message: "AKShare 找到唯一名称候选，但截图没有产品代码，仍需用户确认。"
                    )
                )
            }
            if suppliedCode != matchedCode {
                return enriched(
                    position,
                    verification: InstrumentVerificationV1(
                        status: .notFound,
                        sourceName: Self.sourceName,
                        message: "AKShare 返回的产品代码与截图代码不一致；已保留截图代码，不会按名称改写。"
                    )
                )
            }
            return RecognizedAssetPositionV1(
                imageIndex: position.imageIndex,
                productName: position.productName,
                productCode: matchedCode,
                kind: matchedKind,
                currency: matchedCurrency,
                originalMarketValue: position.originalMarketValue,
                confidence: position.confidence,
                evidence: position.evidence,
                verification: InstrumentVerificationV1(
                    status: .verified,
                    sourceName: Self.sourceName,
                    matchedName: result.matchedName,
                    matchedCode: matchedCode,
                    message: "产品已通过 AKShare 港股目录匹配；保留截图中的产品名称。"
                )
            )
        case InstrumentVerificationStatusV1.ambiguous.rawValue:
            return enriched(
                position,
                verification: InstrumentVerificationV1(
                    status: .ambiguous,
                    sourceName: Self.sourceName,
                    matchedName: result.matchedName,
                    matchedCode: matchedCode,
                    message: "AKShare 找到多个可能产品，需要按代码确认。"
                )
            )
        case InstrumentVerificationStatusV1.notFound.rawValue:
            return enriched(
                position,
                verification: InstrumentVerificationV1(
                    status: .notFound,
                    sourceName: Self.sourceName,
                    message: position.productCode == nil
                        ? "AKShare 港股目录未找到唯一名称候选。"
                        : "AKShare 港股目录未匹配截图代码；已保留原代码。"
                )
            )
        case InstrumentVerificationStatusV1.unavailable.rawValue:
            return unavailable(position)
        default:
            return unavailable(position)
        }
    }

    private func unavailable(
        _ position: RecognizedAssetPositionV1
    ) -> RecognizedAssetPositionV1 {
        enriched(
            position,
            verification: InstrumentVerificationV1(
                status: .unavailable,
                sourceName: Self.sourceName,
                message: "AKShare 或其本地依赖不可用，已保留截图结果。"
            )
        )
    }

    private func markingUnavailable(
        _ positions: [RecognizedAssetPositionV1],
        at indices: [Int],
        message: String
    ) -> [RecognizedAssetPositionV1] {
        var outputs = positions
        for index in indices {
            outputs[index] = enriched(
                outputs[index],
                verification: InstrumentVerificationV1(
                    status: .unavailable,
                    sourceName: Self.sourceName,
                    message: message
                )
            )
        }
        return outputs
    }

    private func canonicalCode(
        _ value: String?,
        currency: RecognizedAssetCurrencyV1
    ) -> String? {
        guard let value = Self.trimmedNonEmpty(value) else { return nil }
        let prepared = value
            .precomposedStringWithCompatibilityMapping
            .uppercased()
        let hasHongKongMarker = prepared.hasSuffix(".HK")
            || prepared.hasPrefix("HK.")
        let bareCode = prepared
            .replacingOccurrences(of: ".HK", with: "")
            .replacingOccurrences(of: "HK.", with: "")
            .filter { $0.isLetter || $0.isNumber }
        guard !bareCode.isEmpty else { return nil }
        if bareCode.allSatisfy(\.isNumber),
           hasHongKongMarker
                || currency == .HKD
                || (4...5).contains(bareCode.count) {
            return bareCode.leftPadded(to: 5, with: "0")
        }
        return bareCode
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

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count)
            + self
    }
}
#endif
