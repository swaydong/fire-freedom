import Foundation

public struct MonthlySpendingAnalysisV1: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var periodStart: Date
    public var periodEnd: Date
    public var comparisonMonthCount: Int
    public var livingExpense: Decimal
    public var categoryChanges: [MonthlyCategoryChangeV1]
    public var largestExpenses: [MonthlyExpenseSignalV1]
    public var unusualExpenses: [MonthlyExpenseSignalV1]

    public init(
        schemaVersion: String = "1.0",
        periodStart: Date,
        periodEnd: Date,
        comparisonMonthCount: Int,
        livingExpense: Decimal,
        categoryChanges: [MonthlyCategoryChangeV1],
        largestExpenses: [MonthlyExpenseSignalV1],
        unusualExpenses: [MonthlyExpenseSignalV1]
    ) {
        self.schemaVersion = schemaVersion
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.comparisonMonthCount = comparisonMonthCount
        self.livingExpense = livingExpense
        self.categoryChanges = categoryChanges
        self.largestExpenses = largestExpenses
        self.unusualExpenses = unusualExpenses
    }
}

public struct MonthlyCategoryChangeV1: Codable, Equatable, Sendable {
    public var primaryCategory: String
    public var currency: CurrencyCode
    public var currentAmount: Decimal
    public var baselineMedianAmount: Decimal
    public var changeAmount: Decimal
    public var changeRate: Decimal?
    public var currentMonthShare: Decimal

    public init(
        primaryCategory: String,
        currency: CurrencyCode,
        currentAmount: Decimal,
        baselineMedianAmount: Decimal,
        changeAmount: Decimal,
        changeRate: Decimal?,
        currentMonthShare: Decimal
    ) {
        self.primaryCategory = primaryCategory
        self.currency = currency
        self.currentAmount = currentAmount
        self.baselineMedianAmount = baselineMedianAmount
        self.changeAmount = changeAmount
        self.changeRate = changeRate
        self.currentMonthShare = currentMonthShare
    }
}

public struct MonthlyExpenseSignalV1: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var occurredAt: Date
    public var amount: Decimal
    public var currency: CurrencyCode
    public var merchantNote: String
    public var primaryCategory: String
    public var secondaryCategory: String
    public var monthlyExpenseShare: Decimal
    public var reason: String?

    public init(
        fingerprint: String,
        occurredAt: Date,
        amount: Decimal,
        currency: CurrencyCode,
        merchantNote: String,
        primaryCategory: String,
        secondaryCategory: String,
        monthlyExpenseShare: Decimal,
        reason: String? = nil
    ) {
        self.fingerprint = fingerprint
        self.occurredAt = occurredAt
        self.amount = amount
        self.currency = currency
        self.merchantNote = merchantNote
        self.primaryCategory = primaryCategory
        self.secondaryCategory = secondaryCategory
        self.monthlyExpenseShare = monthlyExpenseShare
        self.reason = reason
    }
}

public enum MonthlySpendingAnalyzer {
    public static func analyze(
        transactions: [TransactionRecord],
        reportDate: Date,
        coverage explicitCoverage: TransactionCoverage? = nil
    ) -> MonthlySpendingAnalysisV1 {
        let calendar = SpendingMonth.calendar
        let interval = calendar.dateInterval(of: .month, for: reportDate)
            ?? DateInterval(start: reportDate, duration: 1)
        let periodEnd = calendar.date(
            byAdding: .second,
            value: -1,
            to: interval.end
        ) ?? interval.end
        let selectedMonth = SpendingMonth(date: reportDate)
        let eligible = transactions.filter(isEligibleLivingExpense)
        let currentExpenses = eligible.filter {
            SpendingMonth(date: $0.occurredAt) == selectedMonth
        }
        let comparisonMonths = comparisonMonths(
            before: selectedMonth,
            eligibleExpenses: eligible,
            explicitCoverage: explicitCoverage
        )
        let comparisonSet = Set(comparisonMonths)
        let historicalExpenses = eligible.filter {
            comparisonSet.contains(SpendingMonth(date: $0.occurredAt))
        }
        let livingExpense = currentExpenses
            .reduce(Decimal.zero) { $0 + $1.amount }
            .rounded()

        return MonthlySpendingAnalysisV1(
            periodStart: interval.start,
            periodEnd: periodEnd,
            comparisonMonthCount: comparisonMonths.count,
            livingExpense: livingExpense,
            categoryChanges: categoryChanges(
                currentExpenses: currentExpenses,
                historicalExpenses: historicalExpenses,
                comparisonMonths: comparisonMonths,
                livingExpense: livingExpense
            ),
            largestExpenses: Array(
                currentExpenses
                    .sorted(by: expenseSort)
                    .prefix(10)
            ).map {
                signal(
                    from: $0,
                    monthlyExpense: livingExpense,
                    reason: nil
                )
            },
            unusualExpenses: unusualExpenses(
                currentExpenses: currentExpenses,
                historicalExpenses: historicalExpenses,
                comparisonMonthCount: comparisonMonths.count,
                livingExpense: livingExpense
            )
        )
    }

    private static func isEligibleLivingExpense(
        _ transaction: TransactionRecord
    ) -> Bool {
        transaction.direction == .expense
            && !TransactionRules.isExcludedFromLivingExpenses(transaction)
    }

    private static func comparisonMonths(
        before selectedMonth: SpendingMonth,
        eligibleExpenses: [TransactionRecord],
        explicitCoverage: TransactionCoverage?
    ) -> [SpendingMonth] {
        let candidates: [SpendingMonth]
        if let explicitCoverage {
            candidates = completeMonths(in: explicitCoverage).filter {
                $0 < selectedMonth
            }
        } else {
            candidates = Set(
                eligibleExpenses.lazy
                    .map { SpendingMonth(date: $0.occurredAt) }
                    .filter { $0 < selectedMonth }
            ).sorted()
        }
        return Array(candidates.suffix(3))
    }

    private static func completeMonths(
        in coverage: TransactionCoverage
    ) -> [SpendingMonth] {
        guard coverage.start <= coverage.end else { return [] }
        let calendar = SpendingMonth.calendar
        var first = SpendingMonth(date: coverage.start)
        if calendar.component(.day, from: coverage.start) != 1 {
            first = first.advanced(by: 1)
        }

        var last = SpendingMonth(date: coverage.end)
        let lastDay = calendar.range(
            of: .day,
            in: .month,
            for: coverage.end
        )?.count ?? 31
        if calendar.component(.day, from: coverage.end) != lastDay {
            last = last.advanced(by: -1)
        }
        guard first <= last else { return [] }

        var months: [SpendingMonth] = []
        var cursor = first
        while cursor <= last {
            months.append(cursor)
            cursor = cursor.advanced(by: 1)
        }
        return months
    }

    private static func categoryChanges(
        currentExpenses: [TransactionRecord],
        historicalExpenses: [TransactionRecord],
        comparisonMonths: [SpendingMonth],
        livingExpense: Decimal
    ) -> [MonthlyCategoryChangeV1] {
        guard !comparisonMonths.isEmpty else { return [] }
        let current = totalsByCategory(currentExpenses)
        let historicalByMonth = Dictionary(
            grouping: historicalExpenses,
            by: { SpendingMonth(date: $0.occurredAt) }
        ).mapValues(totalsByCategory)
        let keys = Set(current.keys).union(
            historicalExpenses.map(CategoryKey.init)
        )

        return keys.compactMap { key in
            let currentAmount = current[key, default: 0]
            let historicalAmounts = comparisonMonths.map {
                historicalByMonth[$0]?[key] ?? 0
            }
            let baseline = median(historicalAmounts)
            let difference = currentAmount - baseline
            let absoluteDifference = absolute(difference)
            guard absoluteDifference >= 500 else { return nil }

            let changeRate: Decimal?
            if baseline == 0 {
                guard currentAmount >= 1_000 else { return nil }
                changeRate = nil
            } else {
                let rate = difference / baseline
                guard absolute(rate) >= Decimal(string: "0.20")! else {
                    return nil
                }
                changeRate = rate.rounded(scale: 4)
            }

            let share = livingExpense > 0
                ? (currentAmount / livingExpense).rounded(scale: 4)
                : 0
            guard share >= Decimal(string: "0.05")!
                    || absoluteDifference >= 2_000
            else {
                return nil
            }

            return MonthlyCategoryChangeV1(
                primaryCategory: key.primaryCategory,
                currency: key.currency,
                currentAmount: currentAmount.rounded(),
                baselineMedianAmount: baseline.rounded(),
                changeAmount: difference.rounded(),
                changeRate: changeRate,
                currentMonthShare: share
            )
        }
        .sorted {
            let lhsDifference = absolute($0.changeAmount)
            let rhsDifference = absolute($1.changeAmount)
            if lhsDifference != rhsDifference {
                return lhsDifference > rhsDifference
            }
            if $0.primaryCategory != $1.primaryCategory {
                return $0.primaryCategory < $1.primaryCategory
            }
            return $0.currency.rawValue < $1.currency.rawValue
        }
        .prefix(6)
        .map { $0 }
    }

    private static func totalsByCategory(
        _ transactions: [TransactionRecord]
    ) -> [CategoryKey: Decimal] {
        transactions.reduce(into: [:]) { totals, transaction in
            totals[CategoryKey(transaction), default: 0] += transaction.amount
        }
    }

    private static func unusualExpenses(
        currentExpenses: [TransactionRecord],
        historicalExpenses: [TransactionRecord],
        comparisonMonthCount: Int,
        livingExpense: Decimal
    ) -> [MonthlyExpenseSignalV1] {
        guard comparisonMonthCount >= 2 else { return [] }
        let historyByCategory = Dictionary(
            grouping: historicalExpenses,
            by: ExpenseCategoryKey.init
        )

        return currentExpenses.compactMap { transaction in
            guard transaction.amount >= 2_000 else { return nil }
            let history = historyByCategory[ExpenseCategoryKey(transaction)] ?? []
            guard history.count >= 5 else { return nil }
            let historicalMedian = median(history.map(\.amount))
            guard historicalMedian > 0,
                  transaction.amount >= historicalMedian * 3,
                  !isFixedSameAmountRent(transaction, history: history)
            else {
                return nil
            }

            let ratio = (transaction.amount / historicalMedian).rounded(scale: 1)
            return signal(
                from: transaction,
                monthlyExpense: livingExpense,
                reason: "金额是历史同类单笔中位数的 \(ratio) 倍"
            )
        }
        .sorted(by: signalSort)
        .prefix(10)
        .map { $0 }
    }

    private static func isFixedSameAmountRent(
        _ transaction: TransactionRecord,
        history: [TransactionRecord]
    ) -> Bool {
        let classification = [
            transaction.primaryCategory,
            transaction.secondaryCategory,
            transaction.merchantNote,
        ].joined(separator: " ").lowercased()
        guard ["房租", "租金", "rent"].contains(where: classification.contains)
        else {
            return false
        }

        let matchingMonths = Set(history.compactMap { historical -> SpendingMonth? in
            guard historical.amount == transaction.amount else { return nil }
            return SpendingMonth(date: historical.occurredAt)
        })
        return matchingMonths.count >= 2
    }

    private static func signal(
        from transaction: TransactionRecord,
        monthlyExpense: Decimal,
        reason: String?
    ) -> MonthlyExpenseSignalV1 {
        MonthlyExpenseSignalV1(
            fingerprint: transaction.fingerprint.isEmpty
                ? TransactionFingerprint.make(for: transaction)
                : transaction.fingerprint,
            occurredAt: transaction.occurredAt,
            amount: transaction.amount.rounded(),
            currency: transaction.currency,
            merchantNote: transaction.merchantNote,
            primaryCategory: normalizedCategory(transaction.primaryCategory),
            secondaryCategory: transaction.secondaryCategory,
            monthlyExpenseShare: monthlyExpense > 0
                ? (transaction.amount / monthlyExpense).rounded(scale: 4)
                : 0,
            reason: reason
        )
    }

    private static func expenseSort(
        _ lhs: TransactionRecord,
        _ rhs: TransactionRecord
    ) -> Bool {
        if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt > rhs.occurredAt
        }
        return stableFingerprint(lhs) < stableFingerprint(rhs)
    }

    private static func signalSort(
        _ lhs: MonthlyExpenseSignalV1,
        _ rhs: MonthlyExpenseSignalV1
    ) -> Bool {
        if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt > rhs.occurredAt
        }
        return lhs.fingerprint < rhs.fingerprint
    }

    private static func stableFingerprint(
        _ transaction: TransactionRecord
    ) -> String {
        transaction.fingerprint.isEmpty
            ? TransactionFingerprint.make(for: transaction)
            : transaction.fingerprint
    }

    private static func normalizedCategory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分类" : trimmed
    }

    private static func median(_ values: [Decimal]) -> Decimal {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func absolute(_ value: Decimal) -> Decimal {
        value < 0 ? -value : value
    }

    private struct CategoryKey: Hashable {
        var primaryCategory: String
        var currency: CurrencyCode

        init(_ transaction: TransactionRecord) {
            primaryCategory = normalizedCategory(transaction.primaryCategory)
            currency = transaction.currency
        }
    }

    private struct ExpenseCategoryKey: Hashable {
        var primaryCategory: String
        var secondaryCategory: String
        var currency: CurrencyCode

        init(_ transaction: TransactionRecord) {
            primaryCategory = normalizedCategory(transaction.primaryCategory)
            secondaryCategory = transaction.secondaryCategory
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currency = transaction.currency
        }
    }
}

private struct SpendingMonth: Hashable, Comparable {
    var year: Int
    var month: Int

    init(date: Date) {
        let components = Self.calendar.dateComponents(
            [.year, .month],
            from: date
        )
        year = components.year ?? 0
        month = components.month ?? 0
    }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    func advanced(by monthCount: Int) -> Self {
        let zeroBased = year * 12 + month - 1 + monthCount
        return Self(
            year: zeroBased / 12,
            month: zeroBased % 12 + 1
        )
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
}
