import Foundation

public enum TransactionFingerprint {
    public static func make(for transaction: TransactionRecord) -> String {
        make(
            occurredAt: transaction.occurredAt,
            direction: transaction.direction,
            amount: transaction.amount,
            primaryCategory: transaction.primaryCategory,
            secondaryCategory: transaction.secondaryCategory,
            merchantNote: transaction.merchantNote,
            accountName: transaction.accountName
        )
    }

    public static func make(
        occurredAt: Date,
        direction: TransactionDirection,
        amount: Decimal,
        primaryCategory: String,
        secondaryCategory: String,
        merchantNote: String,
        accountName: String
    ) -> String {
        let fields = [
            String(Int64(occurredAt.timeIntervalSince1970)),
            direction.rawValue,
            NSDecimalNumber(decimal: amount).stringValue,
            normalized(primaryCategory),
            normalized(secondaryCategory),
            normalized(merchantNote),
            normalized(accountName),
        ]

        return String(fnv1a64(fields.joined(separator: "\u{1F}")), radix: 16)
            .leftPadded(to: 16, with: "0")
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

public enum DuplicateDetector {
    public static func markSuspectedDuplicates(
        _ transactions: [TransactionRecord]
    ) -> [TransactionRecord] {
        var seen = Set<String>()
        return transactions.map { original in
            var transaction = original
            let fingerprint = original.fingerprint.isEmpty
                ? TransactionFingerprint.make(for: original)
                : original.fingerprint
            transaction.fingerprint = fingerprint

            if seen.contains(fingerprint) {
                transaction.suspectedDuplicate = true
                transaction.duplicateOfFingerprint = fingerprint
            } else {
                transaction.suspectedDuplicate = false
                transaction.duplicateOfFingerprint = nil
                seen.insert(fingerprint)
            }
            return transaction
        }
    }
}

public enum TransactionImportReconciler {
    public static func transactionsToInsert(
        existingFingerprints: [String],
        incoming: [TransactionRecord]
    ) -> [TransactionRecord] {
        var remainingExistingCounts = Dictionary(
            grouping: existingFingerprints,
            by: { $0 }
        ).mapValues(\.count)

        return incoming.filter { transaction in
            let fingerprint = transaction.fingerprint
            guard let remaining = remainingExistingCounts[fingerprint],
                  remaining > 0 else {
                return true
            }
            remainingExistingCounts[fingerprint] = remaining - 1
            return false
        }
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}
