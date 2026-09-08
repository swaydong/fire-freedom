import CryptoKit
import Foundation

public struct KapiSnapshotItem: Codable, Equatable, Sendable {
    public var transaction: TransactionRecord
    public var splitDetails: String

    public init(
        transaction: TransactionRecord,
        splitDetails: String = ""
    ) {
        self.transaction = transaction
        self.splitDetails = splitDetails
    }

    public var semanticFingerprint: String {
        KapiSnapshotFingerprint.make(for: self)
    }
}

public enum KapiSnapshotFingerprint {
    public static func make(
        for transaction: TransactionRecord,
        splitDetails: String = ""
    ) -> String {
        make(
            for: KapiSnapshotItem(
                transaction: transaction,
                splitDetails: splitDetails
            )
        )
    }

    public static func make(for item: KapiSnapshotItem) -> String {
        digest(SemanticKey.make(for: item))
    }

    fileprivate static func digest(_ semanticKey: String) -> String {
        SHA256.hash(data: Data(semanticKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct KapiSnapshotMatch: Equatable, Sendable {
    public var previous: KapiSnapshotItem
    public var incoming: KapiSnapshotItem

    public init(previous: KapiSnapshotItem, incoming: KapiSnapshotItem) {
        self.previous = previous
        self.incoming = incoming
    }
}

public struct KapiSnapshotMultiplicityChange: Equatable, Sendable {
    public var semanticFingerprint: String
    public var previousCount: Int
    public var incomingCount: Int

    public init(
        semanticFingerprint: String,
        previousCount: Int,
        incomingCount: Int
    ) {
        self.semanticFingerprint = semanticFingerprint
        self.previousCount = previousCount
        self.incomingCount = incomingCount
    }

    public var unchangedCount: Int {
        min(previousCount, incomingCount)
    }

    public var addedCount: Int {
        max(incomingCount - previousCount, 0)
    }

    public var removedCount: Int {
        max(previousCount - incomingCount, 0)
    }
}

public enum KapiSnapshotMatchingField: String, Codable, Equatable, Sendable {
    case occurredAt
    case calendarDay
    case direction
    case amount
    case primaryCategory
    case secondaryCategory
    case merchantNote
    case tags
    case accountName
    case ledgerName
    case includedInCashFlow
    case includedInBudget
    case internalTransfer
    case investmentTrade
    case loanPrincipal
    case refund
    case splitDetails
}

/// A non-authoritative hint for explaining a remove/add pair in a diff UI.
///
/// These pairs never change `unchanged`, `added`, or `removed`, and must not be
/// used to inherit adjustments or mutate imported data.
public struct KapiSnapshotPossibleModification: Equatable, Sendable {
    public var previous: KapiSnapshotItem
    public var incoming: KapiSnapshotItem
    public var matchingFields: [KapiSnapshotMatchingField]

    public init(
        previous: KapiSnapshotItem,
        incoming: KapiSnapshotItem,
        matchingFields: [KapiSnapshotMatchingField]
    ) {
        self.previous = previous
        self.incoming = incoming
        self.matchingFields = matchingFields
    }
}

public struct KapiSnapshotReconciliation: Equatable, Sendable {
    public var unchanged: [KapiSnapshotMatch]
    public var added: [KapiSnapshotItem]
    public var removed: [KapiSnapshotItem]
    public var multiplicityChanges: [KapiSnapshotMultiplicityChange]
    public var possibleModifications: [KapiSnapshotPossibleModification]

    public init(
        unchanged: [KapiSnapshotMatch],
        added: [KapiSnapshotItem],
        removed: [KapiSnapshotItem],
        multiplicityChanges: [KapiSnapshotMultiplicityChange],
        possibleModifications: [KapiSnapshotPossibleModification]
    ) {
        self.unchanged = unchanged
        self.added = added
        self.removed = removed
        self.multiplicityChanges = multiplicityChanges
        self.possibleModifications = possibleModifications
    }
}

public enum KapiSnapshotReconciler {
    public static func reconcile(
        previous: [KapiSnapshotItem],
        incoming: [KapiSnapshotItem],
        suggestsPossibleModifications: Bool = true
    ) -> KapiSnapshotReconciliation {
        let previousKeys = previous.map(SemanticKey.make)
        let incomingKeys = incoming.map(SemanticKey.make)
        var incomingIndicesByKey: [String: [Int]] = [:]
        for (index, key) in incomingKeys.enumerated() {
            incomingIndicesByKey[key, default: []].append(index)
        }

        var nextIncomingOffset: [String: Int] = [:]
        var consumedIncoming = Array(repeating: false, count: incoming.count)
        var unchanged: [KapiSnapshotMatch] = []
        var removed: [KapiSnapshotItem] = []

        for (index, item) in previous.enumerated() {
            let key = previousKeys[index]
            let offset = nextIncomingOffset[key, default: 0]
            guard let candidateIndices = incomingIndicesByKey[key],
                  offset < candidateIndices.count else {
                removed.append(item)
                continue
            }

            let incomingIndex = candidateIndices[offset]
            nextIncomingOffset[key] = offset + 1
            consumedIncoming[incomingIndex] = true
            unchanged.append(
                KapiSnapshotMatch(
                    previous: item,
                    incoming: incoming[incomingIndex]
                )
            )
        }

        let added = incoming.enumerated().compactMap { index, item in
            consumedIncoming[index] ? nil : item
        }
        let multiplicityChanges = multiplicityChanges(
            previousKeys: previousKeys,
            incomingKeys: incomingKeys
        )
        let possibleModifications = suggestsPossibleModifications
            ? PossibleModificationSuggester.suggestions(
                removed: removed,
                added: added
            )
            : []

        return KapiSnapshotReconciliation(
            unchanged: unchanged,
            added: added,
            removed: removed,
            multiplicityChanges: multiplicityChanges,
            possibleModifications: possibleModifications
        )
    }

    private static func multiplicityChanges(
        previousKeys: [String],
        incomingKeys: [String]
    ) -> [KapiSnapshotMultiplicityChange] {
        let previousCounts = counts(previousKeys)
        let incomingCounts = counts(incomingKeys)
        return Set(previousCounts.keys)
            .union(incomingCounts.keys)
            .sorted()
            .compactMap { key in
                let previousCount = previousCounts[key, default: 0]
                let incomingCount = incomingCounts[key, default: 0]
                guard previousCount != incomingCount else { return nil }
                return KapiSnapshotMultiplicityChange(
                    semanticFingerprint: KapiSnapshotFingerprint.digest(key),
                    previousCount: previousCount,
                    incomingCount: incomingCount
                )
            }
    }

    private static func counts(_ keys: [String]) -> [String: Int] {
        keys.reduce(into: [:]) { result, key in
            result[key, default: 0] += 1
        }
    }
}

private enum SemanticKey {
    static func make(for item: KapiSnapshotItem) -> String {
        let transaction = item.transaction
        let tags = normalizedTags(transaction.tags)
        let fields = [
            "kapi-snapshot-v1",
            String(Int64(transaction.occurredAt.timeIntervalSince1970)),
            transaction.direction.rawValue,
            NSDecimalNumber(decimal: transaction.amount).stringValue,
            transaction.currency.rawValue,
            normalizedText(transaction.primaryCategory),
            normalizedText(transaction.secondaryCategory),
            normalizedText(transaction.merchantNote),
            lengthPrefixed(tags),
            normalizedText(transaction.accountName),
            normalizedText(transaction.ledgerName),
            transaction.includedInCashFlow ? "1" : "0",
            transaction.includedInBudget ? "1" : "0",
            transaction.isInternalTransfer ? "1" : "0",
            transaction.isInvestmentTrade ? "1" : "0",
            transaction.isLoanPrincipal ? "1" : "0",
            transaction.isRefund ? "1" : "0",
            normalizedText(item.splitDetails),
        ]
        return lengthPrefixed(fields)
    }

    static func normalizedText(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    static func normalizedTags(_ values: [String]) -> [String] {
        Array(
            Set(
                values
                    .map(normalizedText)
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }

    private static func lengthPrefixed(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

private enum PossibleModificationSuggester {
    private struct Candidate {
        var removedIndex: Int
        var addedIndex: Int
        var fields: [KapiSnapshotMatchingField]
        var score: Int
    }

    static func suggestions(
        removed: [KapiSnapshotItem],
        added: [KapiSnapshotItem]
    ) -> [KapiSnapshotPossibleModification] {
        var candidates: [Candidate] = []
        for (removedIndex, previous) in removed.enumerated() {
            for (addedIndex, incoming) in added.enumerated() {
                guard let fields = matchingFields(
                    previous: previous,
                    incoming: incoming
                ) else {
                    continue
                }
                candidates.append(
                    Candidate(
                        removedIndex: removedIndex,
                        addedIndex: addedIndex,
                        fields: fields,
                        score: score(fields)
                    )
                )
            }
        }

        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.removedIndex != $1.removedIndex {
                return $0.removedIndex < $1.removedIndex
            }
            return $0.addedIndex < $1.addedIndex
        }

        var usedRemoved = Set<Int>()
        var usedAdded = Set<Int>()
        var result: [KapiSnapshotPossibleModification] = []
        for candidate in candidates
            where !usedRemoved.contains(candidate.removedIndex)
                && !usedAdded.contains(candidate.addedIndex) {
            usedRemoved.insert(candidate.removedIndex)
            usedAdded.insert(candidate.addedIndex)
            result.append(
                KapiSnapshotPossibleModification(
                    previous: removed[candidate.removedIndex],
                    incoming: added[candidate.addedIndex],
                    matchingFields: candidate.fields
                )
            )
        }
        return result
    }

    private static func matchingFields(
        previous: KapiSnapshotItem,
        incoming: KapiSnapshotItem
    ) -> [KapiSnapshotMatchingField]? {
        let lhs = previous.transaction
        let rhs = incoming.transaction
        guard lhs.direction == rhs.direction else { return nil }

        let exactTime = Int64(lhs.occurredAt.timeIntervalSince1970)
            == Int64(rhs.occurredAt.timeIntervalSince1970)
        let sameDay = calendar.isDate(lhs.occurredAt, inSameDayAs: rhs.occurredAt)
        let sameAmount = lhs.amount == rhs.amount
        let samePrimary = sameNonemptyText(
            lhs.primaryCategory,
            rhs.primaryCategory
        )
        let sameSecondary = sameNonemptyText(
            lhs.secondaryCategory,
            rhs.secondaryCategory
        )
        let sameNote = sameNonemptyText(lhs.merchantNote, rhs.merchantNote)
        let sameAccount = sameNonemptyText(lhs.accountName, rhs.accountName)
        let hasDescriptiveMatch = samePrimary || sameSecondary || sameNote
            || sameAccount

        guard (exactTime && (sameAmount || hasDescriptiveMatch))
            || (sameDay && sameAmount && hasDescriptiveMatch) else {
            return nil
        }

        var fields: [KapiSnapshotMatchingField] = [.direction]
        if exactTime {
            fields.append(.occurredAt)
        } else if sameDay {
            fields.append(.calendarDay)
        }
        if sameAmount { fields.append(.amount) }
        if samePrimary { fields.append(.primaryCategory) }
        if sameSecondary { fields.append(.secondaryCategory) }
        if sameNote { fields.append(.merchantNote) }
        let normalizedTags = SemanticKey.normalizedTags(lhs.tags)
        if !normalizedTags.isEmpty
            && normalizedTags == SemanticKey.normalizedTags(rhs.tags) {
            fields.append(.tags)
        }
        if sameAccount { fields.append(.accountName) }
        if sameNonemptyText(lhs.ledgerName, rhs.ledgerName) {
            fields.append(.ledgerName)
        }
        if lhs.includedInCashFlow == rhs.includedInCashFlow {
            fields.append(.includedInCashFlow)
        }
        if lhs.includedInBudget == rhs.includedInBudget {
            fields.append(.includedInBudget)
        }
        if lhs.isInternalTransfer == rhs.isInternalTransfer {
            fields.append(.internalTransfer)
        }
        if lhs.isInvestmentTrade == rhs.isInvestmentTrade {
            fields.append(.investmentTrade)
        }
        if lhs.isLoanPrincipal == rhs.isLoanPrincipal {
            fields.append(.loanPrincipal)
        }
        if lhs.isRefund == rhs.isRefund {
            fields.append(.refund)
        }
        if sameNonemptyText(previous.splitDetails, incoming.splitDetails) {
            fields.append(.splitDetails)
        }
        return fields
    }

    private static func score(_ fields: [KapiSnapshotMatchingField]) -> Int {
        fields.reduce(0) { result, field in
            let weight = switch field {
            case .occurredAt: 100
            case .calendarDay: 20
            case .amount: 30
            case .merchantNote: 15
            case .primaryCategory, .secondaryCategory, .accountName: 10
            case .tags, .ledgerName, .includedInCashFlow,
                 .includedInBudget, .internalTransfer, .investmentTrade,
                 .loanPrincipal, .refund, .splitDetails: 5
            case .direction: 1
            }
            return result + weight
        }
    }

    private static func sameNonemptyText(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = SemanticKey.normalizedText(lhs)
        return !lhs.isEmpty && lhs == SemanticKey.normalizedText(rhs)
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
}
