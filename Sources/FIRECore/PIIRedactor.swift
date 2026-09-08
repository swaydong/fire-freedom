import Foundation

public enum PIIRedactor {
    public static func redact(packet: AnalysisPacketV1) -> AnalysisPacketV1 {
        var packet = packet
        let opaqueIDByFingerprint = packet.transactions.reduce(
            into: [String: String]()
        ) { result, transaction in
            let sourceFingerprint = transaction.fingerprint.isEmpty
                ? TransactionFingerprint.make(for: transaction)
                : transaction.fingerprint
            result[sourceFingerprint, default: transaction.id.uuidString.lowercased()]
                = result[sourceFingerprint]
                    ?? transaction.id.uuidString.lowercased()
        }
        packet.transactions = packet.transactions.map { source in
            var transaction = redact(transaction: source)
            transaction.duplicateOfFingerprint = source.duplicateOfFingerprint
                .flatMap { opaqueIDByFingerprint[$0] }
            return transaction
        }
        if var spendingAnalysis = packet.spendingAnalysis {
            spendingAnalysis.categoryChanges = spendingAnalysis.categoryChanges.map {
                var change = $0
                change.primaryCategory = redact(text: change.primaryCategory)
                return change
            }
            spendingAnalysis.largestExpenses = spendingAnalysis.largestExpenses.map {
                redact(signal: $0, opaqueIDByFingerprint: opaqueIDByFingerprint)
            }
            spendingAnalysis.unusualExpenses = spendingAnalysis.unusualExpenses.map {
                redact(signal: $0, opaqueIDByFingerprint: opaqueIDByFingerprint)
            }
            packet.spendingAnalysis = spendingAnalysis
        }

        packet.assetSnapshot.positions = packet.assetSnapshot.positions.map { position in
            var position = position
            position.sourceImportID = nil
            position.instrument.name = redact(text: position.instrument.name)
            return position
        }
        packet.assetSnapshot.liabilities = packet.assetSnapshot.liabilities.map { liability in
            var liability = liability
            liability.name = "[负债]"
            return liability
        }
        packet.assetSnapshot.dataIssues = packet.assetSnapshot.dataIssues.map { redact(text: $0) }
        return packet
    }

    private static func redact(
        signal: MonthlyExpenseSignalV1,
        opaqueIDByFingerprint: [String: String]
    ) -> MonthlyExpenseSignalV1 {
        var signal = signal
        signal.fingerprint = opaqueIDByFingerprint[signal.fingerprint]
            ?? signal.fingerprint
        signal.merchantNote = redact(text: signal.merchantNote)
        signal.primaryCategory = redact(text: signal.primaryCategory)
        signal.secondaryCategory = redact(text: signal.secondaryCategory)
        signal.reason = signal.reason.map { redact(text: $0) }
        return signal
    }

    public static func redact(transaction: TransactionRecord) -> TransactionRecord {
        var transaction = transaction
        transaction.merchantNote = redact(text: transaction.merchantNote)
        transaction.primaryCategory = redact(text: transaction.primaryCategory)
        transaction.secondaryCategory = redact(text: transaction.secondaryCategory)
        transaction.tags = transaction.tags.map { redact(text: $0) }
        transaction.accountName = transaction.accountName.isEmpty ? "" : "[已移除]"
        transaction.ledgerName = redact(text: transaction.ledgerName)
        transaction.fingerprint = transaction.id.uuidString.lowercased()
        transaction.duplicateOfFingerprint = nil
        return transaction
    }

    public static func redact(text: String) -> String {
        var result = text
        for replacement in replacements {
            guard let expression = try? NSRegularExpression(
                pattern: replacement.pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement.template
            )
        }
        return result
    }

    private struct Replacement: Sendable {
        var pattern: String
        var template: String
    }

    private static let replacements = [
        Replacement(
            pattern: #"((?:转给|付款给|红包发给))\s*[\p{Han}·]{2,4}(?=$|[\s，,。；;、])"#,
            template: "$1[已移除]"
        ),
        Replacement(
            pattern: #"((?:(?:微信|支付宝|银行)?(?:转账|收款|还款|借款))(?:给|至|到|自|来自)?)\s*[-—_：:]?\s*[\p{Han}·]{2,4}(?=$|[\s，,。；;、])"#,
            template: "$1[已移除]"
        ),
        Replacement(
            pattern: #"((?:收到|来自))\s*[\p{Han}·]{2,4}?(\s*(?:的)?(?:转账|还款|付款))"#,
            template: "$1[已移除]$2"
        ),
        Replacement(
            pattern: #"((?:收款人|付款人|转账人|对方))\s*[:：]?\s*[\p{Han}·]{2,4}(?=$|[\s，,。；;、])"#,
            template: "$1：[已移除]"
        ),
        Replacement(
            pattern: #"((?:姓名|持有人|开户人))\s*[:：]\s*[\p{Han}A-Z·]{2,30}"#,
            template: "$1：[已移除]"
        ),
        Replacement(
            pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            template: "[已移除]"
        ),
        Replacement(
            pattern: #"(?<![0-9])(?:\+?86[\s\-]?)?1[3-9][0-9]{9}(?![0-9])"#,
            template: "[已移除]"
        ),
        Replacement(
            pattern: #"(?<![0-9])[1-9][0-9]{5}(?:18|19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9X](?![0-9A-Z])"#,
            template: "[已移除]"
        ),
        Replacement(
            pattern: #"(?<![0-9])(?:[0-9][\s\-]?){12,19}(?![0-9])"#,
            template: "[已移除]"
        ),
        Replacement(
            pattern: #"(?:账号|帐号|卡号|身份证号|证件号)\s*[:：]?\s*[A-Z0-9][A-Z0-9\-\s]{5,}"#,
            template: "[已移除]"
        ),
    ]
}
