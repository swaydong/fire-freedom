#if os(macOS)
import Foundation

public struct LocalInstrumentVerifier: InstrumentVerifying {
    private let directory: LocalInstrumentDirectory

    public init(directory: LocalInstrumentDirectory) {
        self.directory = directory
    }

    public static func bundled() throws -> LocalInstrumentVerifier {
        try LocalInstrumentVerifier(
            directory: LocalInstrumentDirectory.bundled()
        )
    }

    public func verify(
        positions: [RecognizedAssetPositionV1]
    ) async -> [RecognizedAssetPositionV1] {
        positions.map(verify)
    }

    private func verify(
        _ position: RecognizedAssetPositionV1
    ) -> RecognizedAssetPositionV1 {
        guard position.kind != .cash else {
            return enriched(
                position,
                verification: InstrumentVerificationV1(
                    status: .notApplicable,
                    sourceName: "本地产品目录",
                    message: "现金无需产品目录校验。"
                )
            )
        }

        if let suppliedCode = position.productCode?.trimmedNonEmpty {
            let allCodeMatches = directory.candidates(code: suppliedCode)
            let matches = preferredMatches(
                allCodeMatches,
                currency: position.currency
            )
            guard matches.count == 1, let match = matches.first else {
                return enriched(
                    position,
                    verification: InstrumentVerificationV1(
                        status: matches.isEmpty ? .notFound : .ambiguous,
                        sourceName: "本地产品目录",
                        message: matches.isEmpty
                            ? "本地候选库未找到截图代码，已保留原代码。"
                            : "本地候选库中该代码对应多个产品，已保留原代码。"
                    )
                )
            }
            return verified(position, candidate: match)
        }

        let sameCurrencyMatches = directory.candidates(
            name: position.productName,
            currency: position.currency
        )
        let matches = sameCurrencyMatches.isEmpty
            ? directory.candidates(name: position.productName)
            : sameCurrencyMatches
        guard !matches.isEmpty else {
            return enriched(
                position,
                verification: InstrumentVerificationV1(
                    status: .notFound,
                    sourceName: "本地产品目录",
                    message: "本地候选库未找到名称候选。"
                )
            )
        }
        return enriched(
            position,
            verification: InstrumentVerificationV1(
                status: .ambiguous,
                sourceName: "本地产品目录",
                matchedName: matches.count == 1 ? matches[0].name : nil,
                matchedCode: matches.count == 1
                    ? canonicalCode(for: matches[0])
                    : nil,
                message: matches.count == 1
                    ? "名称找到一个离线候选，但没有截图代码，仍需用户确认。"
                    : "名称对应多个离线候选，需要按市场或代码确认。"
            )
        )
    }

    private func preferredMatches(
        _ matches: [LocalInstrumentCandidate],
        currency: RecognizedAssetCurrencyV1
    ) -> [LocalInstrumentCandidate] {
        let sameCurrency = matches.filter { $0.currency == currency }
        return sameCurrency.isEmpty ? matches : sameCurrency
    }

    private func verified(
        _ position: RecognizedAssetPositionV1,
        candidate: LocalInstrumentCandidate
    ) -> RecognizedAssetPositionV1 {
        let sources = directory.sources(for: candidate)
        let sourceName = sources.contains { $0.kind == .officialOverlay }
            ? "官方产品资料（离线）"
            : "FinanceDatabase 离线候选库"
        let latestAsOf = sources.map(\.asOf).max()
        let dateSuffix = latestAsOf.map { "，数据日期 \($0)" } ?? ""
        return RecognizedAssetPositionV1(
            imageIndex: position.imageIndex,
            productName: position.productName,
            productCode: canonicalCode(for: candidate),
            kind: candidate.kind,
            currency: candidate.currency,
            originalMarketValue: position.originalMarketValue,
            confidence: position.confidence,
            evidence: position.evidence,
            verification: InstrumentVerificationV1(
                status: .verified,
                sourceName: sourceName,
                matchedName: candidate.name,
                matchedCode: canonicalCode(for: candidate),
                message: "截图代码已与本地产品目录匹配\(dateSuffix)。"
            )
        )
    }

    private func canonicalCode(
        for candidate: LocalInstrumentCandidate
    ) -> String {
        guard candidate.exchange.uppercased() == "HKEX" else {
            return candidate.code.uppercased()
        }
        let bareCode = candidate.code
            .uppercased()
            .replacingOccurrences(of: ".HK", with: "")
            .filter(\.isNumber)
        return bareCode.leftPadded(to: 5, with: "0")
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
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}
#endif
