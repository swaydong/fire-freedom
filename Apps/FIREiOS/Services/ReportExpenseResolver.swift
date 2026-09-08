import FIRECore
import Foundation

struct ReportExpenseItem: Identifiable, Equatable {
    let id: String
    let occurredAt: Date
    let amount: Decimal
    let currency: CurrencyCode
    let merchantNote: String
    let primaryCategory: String
    let secondaryCategory: String
    let referenceKeys: Set<String>
    let monthlyExpenseShare: Decimal?
    let reason: String?

    init(transaction: TransactionRecord) {
        id = transaction.id.uuidString.lowercased()
        occurredAt = transaction.occurredAt
        amount = transaction.amount
        currency = transaction.currency
        merchantNote = transaction.merchantNote
        primaryCategory = transaction.primaryCategory
        secondaryCategory = transaction.secondaryCategory
        referenceKeys = Set(
            [transaction.id.uuidString, transaction.fingerprint]
                .map { $0.lowercased() }
                .filter { !$0.isEmpty }
        )
        monthlyExpenseShare = nil
        reason = nil
    }

    init(signal: MonthlyExpenseSignalV1) {
        let normalizedFingerprint = signal.fingerprint.lowercased()
        id = [
            normalizedFingerprint,
            String(signal.occurredAt.timeIntervalSince1970),
            NSDecimalNumber(decimal: signal.amount).stringValue,
        ].joined(separator: "|")
        occurredAt = signal.occurredAt
        amount = signal.amount
        currency = signal.currency
        merchantNote = signal.merchantNote
        primaryCategory = signal.primaryCategory
        secondaryCategory = signal.secondaryCategory
        referenceKeys = normalizedFingerprint.isEmpty
            ? []
            : [normalizedFingerprint]
        monthlyExpenseShare = signal.monthlyExpenseShare
        reason = signal.reason
    }

    var merchantDisplayName: String {
        let merchant = merchantNote.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return merchant.isEmpty ? categoryDisplayName : merchant
    }

    var categoryDisplayName: String {
        [primaryCategory, secondaryCategory]
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                guard result.last != value else { return }
                result.append(value)
            }
            .joined(separator: " · ")
    }

    var amountText: String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return "\(currency.rawValue) \(value.formatted(.number.precision(.fractionLength(0...2))))"
    }
}

enum ReportExpenseResolver {
    static let maximumDisplayedCount = 3
    static let maximumLargestExpenseCount = 10

    static func linkedExpenses(
        evidenceRefs: [String],
        evidenceByID: [String: AnalysisEvidenceV1],
        report: AnalysisReportV1,
        transactions: [TransactionRecord]
    ) -> [ReportExpenseItem] {
        let eligible = eligibleTransactions(
            report: report,
            transactions: transactions
        )
        var transactionByFingerprint: [String: TransactionRecord] = [:]
        for transaction in eligible {
            transactionByFingerprint[
                transaction.id.uuidString.lowercased()
            ] = transaction
            if !transaction.fingerprint.isEmpty {
                transactionByFingerprint[
                    transaction.fingerprint.lowercased()
                ] = transaction
            }
        }

        var result: [ReportExpenseItem] = []
        var includedIDs = Set<UUID>()
        for reference in evidenceRefs {
            guard let evidence = evidenceByID[reference] else { continue }
            for fingerprint in evidence.transactionFingerprints {
                guard let transaction = transactionByFingerprint[
                    fingerprint.lowercased()
                ], includedIDs.insert(transaction.id).inserted else {
                    continue
                }
                result.append(ReportExpenseItem(transaction: transaction))
                if result.count == maximumDisplayedCount {
                    return result
                }
            }
        }
        return result
    }

    static func notableExpenses(
        report: AnalysisReportV1,
        transactions: [TransactionRecord]
    ) -> [ReportExpenseItem] {
        let eligible = eligibleTransactions(
            report: report,
            transactions: transactions
        )
        guard !eligible.isEmpty else { return [] }

        let monthlyExpense = report.monthlySummary?.livingExpense
            ?? eligible.reduce(Decimal.zero) { $0 + $1.amount }
        let threshold = max(
            Decimal(2_000),
            monthlyExpense / 10
        )
        let sorted = eligible.sorted {
            if $0.amount == $1.amount {
                return $0.occurredAt > $1.occurredAt
            }
            return $0.amount > $1.amount
        }
        let notable = sorted.filter { $0.amount >= threshold }
        let selected = notable.isEmpty
            ? Array(sorted.prefix(1))
            : Array(notable.prefix(maximumDisplayedCount))
        return selected.map(ReportExpenseItem.init(transaction:))
    }

    static func largestExpenses(
        report: AnalysisReportV1,
        transactions: [TransactionRecord],
        limit: Int = maximumLargestExpenseCount
    ) -> [ReportExpenseItem] {
        guard limit > 0 else { return [] }
        return eligibleTransactions(
            report: report,
            transactions: transactions
        )
        .sorted {
            if $0.amount == $1.amount {
                if $0.occurredAt == $1.occurredAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.occurredAt > $1.occurredAt
            }
            return $0.amount > $1.amount
        }
        .prefix(limit)
        .map(ReportExpenseItem.init(transaction:))
    }

    static func largestExpenses(
        analysis: MonthlySpendingAnalysisV1
    ) -> [ReportExpenseItem] {
        analysis.largestExpenses
            .sorted {
                if $0.amount == $1.amount {
                    if $0.occurredAt == $1.occurredAt {
                        return $0.fingerprint < $1.fingerprint
                    }
                    return $0.occurredAt > $1.occurredAt
                }
                return $0.amount > $1.amount
            }
            .prefix(maximumLargestExpenseCount)
            .map(ReportExpenseItem.init(signal:))
    }

    private static func eligibleTransactions(
        report: AnalysisReportV1,
        transactions: [TransactionRecord]
    ) -> [TransactionRecord] {
        guard let summary = report.monthlySummary else { return [] }
        let exclusivePeriodEnd = summary.periodEnd.addingTimeInterval(1)
        return transactions.filter {
            $0.occurredAt >= summary.periodStart
                && $0.occurredAt < exclusivePeriodEnd
                && $0.direction == .expense
                && !TransactionRules.isExcludedFromLivingExpenses($0)
        }
    }
}
