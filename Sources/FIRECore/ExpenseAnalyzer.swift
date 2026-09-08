import Foundation

public enum TransactionRules {
    public static func isExcludedFromLivingExpenses(_ transaction: TransactionRecord) -> Bool {
        guard transaction.direction == .expense, transaction.includedInCashFlow else {
            return true
        }

        if transaction.suspectedDuplicate
            || transaction.isInternalTransfer
            || transaction.isInvestmentTrade
            || transaction.isLoanPrincipal
        {
            return true
        }

        let classification = normalizedClassification(transaction)
        if containsAny(
            classification,
            [
                "内部转账", "账户互转", "银行卡转账", "信用卡还款", "贷款还款",
                "贷款本金", "偿还本金", "证券买入", "证券卖出", "股票买入",
                "股票卖出", "基金买入", "基金卖出", "申购", "赎回", "盈米宝充值",
            ]
        ) {
            return true
        }

        if transaction.primaryCategory.contains("资金往来"),
           containsAny(classification, ["还款", "转账", "本金"])
        {
            return true
        }

        return false
    }

    public static func isRefund(_ transaction: TransactionRecord) -> Bool {
        transaction.isRefund
            || containsAny(normalizedClassification(transaction), ["退款", "退货", "返现"])
    }

    public static func isEligibleRefundIncome(_ transaction: TransactionRecord) -> Bool {
        guard transaction.direction == .income,
              transaction.includedInCashFlow,
              !transaction.suspectedDuplicate,
              !transaction.isInternalTransfer,
              !transaction.isInvestmentTrade,
              !transaction.isLoanPrincipal,
              isRefund(transaction)
        else {
            return false
        }

        return !containsAny(
            normalizedClassification(transaction),
            [
                "内部转账", "账户互转", "银行卡转账", "贷款", "本金",
                "证券", "股票", "基金", "投资", "理财", "卖出", "赎回",
            ]
        )
    }

    public static func isIrregularExpense(_ transaction: TransactionRecord) -> Bool {
        let classification = normalizedClassification(transaction)
        if containsAny(
            classification,
            ["旅行", "旅游", "度假", "医疗", "健康", "保险", "人情", "礼金", "随礼"]
        ) {
            return true
        }

        let isHousing = containsAny(classification, ["住房", "房租", "房贷", "租金"])
        return !isHousing && transaction.amount >= 2_000
    }

    public static func isStableIncome(_ transaction: TransactionRecord) -> Bool {
        guard transaction.direction == .income,
              transaction.includedInCashFlow,
              !transaction.suspectedDuplicate,
              !transaction.isInternalTransfer,
              !transaction.isInvestmentTrade,
              !isRefund(transaction)
        else {
            return false
        }

        return !containsAny(
            normalizedClassification(transaction),
            ["奖金", "红包", "礼金", "投资", "理财", "卖出", "赎回", "借款"]
        )
    }

    public static func isAnnualBonusIncome(
        _ transaction: TransactionRecord
    ) -> Bool {
        guard transaction.direction == .income,
              transaction.includedInCashFlow,
              !transaction.suspectedDuplicate,
              !transaction.isInternalTransfer,
              !transaction.isInvestmentTrade,
              !transaction.isLoanPrincipal,
              !isRefund(transaction)
        else {
            return false
        }

        return containsAny(
            normalizedClassification(transaction),
            ["奖金", "年终奖", "十三薪"]
        )
    }

    public static func isExcludedFromReportedIncome(
        _ transaction: TransactionRecord
    ) -> Bool {
        guard transaction.direction == .income,
              transaction.includedInCashFlow,
              !transaction.suspectedDuplicate,
              !transaction.isInternalTransfer,
              !transaction.isInvestmentTrade,
              !transaction.isLoanPrincipal,
              !isRefund(transaction)
        else {
            return true
        }

        return containsAny(
            normalizedClassification(transaction),
            [
                "内部转账", "账户互转", "银行卡转账", "贷款", "借款",
                "证券卖出", "股票卖出", "基金卖出", "赎回",
            ]
        )
    }

    private static func normalizedClassification(_ transaction: TransactionRecord) -> String {
        [
            transaction.primaryCategory,
            transaction.secondaryCategory,
            transaction.merchantNote,
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }
}

public enum ExpenseAnalyzer {
    public static func analyze(
        _ transactions: [TransactionRecord],
        coverage explicitCoverage: TransactionCoverage? = nil
    ) -> ExpenseAnalysis {
        guard let coverage = MonthCoverage(
            transactions: transactions,
            explicitCoverage: explicitCoverage
        ) else {
            return ExpenseAnalysis(
                annualSpending: 0,
                recurringAnnualized: 0,
                irregularObservedOrRolling12: 0,
                refundOffset: 0,
                completeMonthCount: 0,
                confidence: .insufficient,
                excludedTransactionCount: 0,
                duplicateTransactionCount: transactions.filter(\.suspectedDuplicate).count,
                periodStart: nil,
                periodEnd: nil
            )
        }

        let completeMonths = coverage.completeMonths
        let analysisMonths = Array(completeMonths.suffix(12))
        let monthSet = Set(analysisMonths)
        let recurringWindow = transactions.filter {
            monthSet.contains(MonthKey(date: $0.occurredAt))
        }
        let actualWindow = coverage.actualSpendingWindow(
            transactions: transactions,
            useRollingTwelveMonths: completeMonths.count >= 12
        )

        let recurringExpenses = recurringWindow.filter {
            $0.direction == .expense && !TransactionRules.isExcludedFromLivingExpenses($0)
                && !TransactionRules.isIrregularExpense($0)
        }
        let irregularExpenses = actualWindow.filter {
            $0.direction == .expense
                && !TransactionRules.isExcludedFromLivingExpenses($0)
                && TransactionRules.isIrregularExpense($0)
        }
        let refundsByOriginal = RefundMatcher.matchedAmountsByOriginal(
            in: transactions
        )

        let monthlyRecurring = analysisMonths.map { month in
            recurringExpenses
                .filter { MonthKey(date: $0.occurredAt) == month }
                .reduce(Decimal.zero) {
                    $0 + adjustedExpenseAmount(
                        $1,
                        refundsByOriginal: refundsByOriginal
                    )
                }
        }
        let recurringAnnualized = (median(monthlyRecurring) * 12).rounded()
        let irregularObserved = irregularExpenses
            .reduce(Decimal.zero) {
                $0 + adjustedExpenseAmount(
                    $1,
                    refundsByOriginal: refundsByOriginal
                )
            }
            .rounded()
        let countedExpenseIDs = Set(
            recurringExpenses.map(\.id) + irregularExpenses.map(\.id)
        )
        let refundOffset = refundsByOriginal
            .filter { countedExpenseIDs.contains($0.key) }
            .reduce(Decimal.zero) { $0 + $1.value }
            .rounded()
        let annualSpending = max(
            Decimal.zero,
            recurringAnnualized + irregularObserved
        ).rounded()

        let expenseRecordsInWindow = actualWindow.filter { $0.direction == .expense }
        let excludedCount = expenseRecordsInWindow.filter {
            TransactionRules.isExcludedFromLivingExpenses($0)
        }.count

        return ExpenseAnalysis(
            annualSpending: annualSpending,
            recurringAnnualized: recurringAnnualized,
            irregularObservedOrRolling12: irregularObserved,
            refundOffset: refundOffset,
            completeMonthCount: completeMonths.count,
            confidence: .from(completeMonthCount: completeMonths.count),
            excludedTransactionCount: excludedCount,
            duplicateTransactionCount: transactions.filter(\.suspectedDuplicate).count,
            periodStart: coverage.periodStart,
            periodEnd: coverage.periodEnd
        )
    }

    public static func suggestMonthlyContribution(
        from transactions: [TransactionRecord],
        coverage explicitCoverage: TransactionCoverage? = nil
    ) -> MonthlyContributionSuggestion {
        guard let coverage = MonthCoverage(
            transactions: transactions,
            explicitCoverage: explicitCoverage
        ) else {
            return MonthlyContributionSuggestion(
                amount: nil,
                monthsUsed: 0,
                confidence: .insufficient,
                rationale: "没有足够的完整月份可计算稳定净结余。"
            )
        }

        let months = Array(coverage.completeMonths.suffix(6))
        guard !months.isEmpty else {
            return MonthlyContributionSuggestion(
                amount: nil,
                monthsUsed: 0,
                confidence: .insufficient,
                rationale: "至少需要一个完整月份；达到 3 个月后才会给出低可信度建议。"
            )
        }

        let refundsByOriginal = RefundMatcher.matchedAmountsByOriginal(
            in: transactions
        )
        let cashFlowByMonth = monthlyStableSurpluses(
            transactions: transactions,
            months: months,
            refundsByOriginal: refundsByOriginal
        )

        let suggestion = max(Decimal.zero, median(cashFlowByMonth)).rounded()
        let confidence = DataConfidence.from(completeMonthCount: months.count)
        return MonthlyContributionSuggestion(
            amount: suggestion,
            monthsUsed: months.count,
            confidence: confidence,
            rationale: "取最近 \(months.count) 个完整月份稳定收入减生活支出的月度中位数；只冲减能匹配原消费的退款，且需由你确认后才进入预计年份。"
        )
    }

    public static func contributionHistoryReference(
        from transactions: [TransactionRecord],
        coverage explicitCoverage: TransactionCoverage? = nil
    ) -> ContributionHistoryReference {
        guard let coverage = MonthCoverage(
            transactions: transactions,
            explicitCoverage: explicitCoverage
        ) else {
            return .empty
        }

        let months = Array(coverage.completeMonths.suffix(6))
        let refundsByOriginal = RefundMatcher.matchedAmountsByOriginal(
            in: transactions
        )
        let monthlyValues = monthlyStableSurpluses(
            transactions: transactions,
            months: months,
            refundsByOriginal: refundsByOriginal
        )
        let monthlyStableIncomeValues = monthlyStableIncomes(
            transactions: transactions,
            months: months
        )
        let monthlyReference = MonthlySurplusReference(
            median: monthlyValues.isEmpty
                ? nil
                : median(monthlyValues).rounded(),
            latest: monthlyValues.last?.rounded(),
            minimum: monthlyValues.min()?.rounded(),
            maximum: monthlyValues.max()?.rounded(),
            monthsUsed: monthlyValues.count
        )
        let monthlyStableIncomeReference = MonthlySurplusReference(
            median: monthlyStableIncomeValues.isEmpty
                ? nil
                : median(monthlyStableIncomeValues).rounded(),
            latest: monthlyStableIncomeValues.last?.rounded(),
            minimum: monthlyStableIncomeValues.min()?.rounded(),
            maximum: monthlyStableIncomeValues.max()?.rounded(),
            monthsUsed: monthlyStableIncomeValues.count
        )

        let calendar = MonthKey.calendar
        let bonusRecords = transactions.filter(
            TransactionRules.isAnnualBonusIncome
        )
        let totalsByYear = Dictionary(grouping: bonusRecords) {
            calendar.component(.year, from: $0.occurredAt)
        }
        .mapValues { records in
            records
                .reduce(Decimal.zero) { $0 + $1.amount }
                .rounded()
        }
        let years = totalsByYear.keys.sorted()
        let annualValues = years.compactMap { totalsByYear[$0] }
        let latestYear = years.last
        let annualReference = AnnualBonusReference(
            latestYear: latestYear,
            latestYearTotal: latestYear.flatMap { totalsByYear[$0] },
            annualMedian: annualValues.isEmpty
                ? nil
                : median(annualValues).rounded(),
            yearsUsed: annualValues.count,
            transactionCount: bonusRecords.count
        )

        return ContributionHistoryReference(
            monthlySurplus: monthlyReference,
            monthlyStableIncome: monthlyStableIncomeReference,
            annualBonus: annualReference
        )
    }

    private static func monthlyStableIncomes(
        transactions: [TransactionRecord],
        months: [MonthKey]
    ) -> [Decimal] {
        months.map { month in
            transactions
                .filter {
                    MonthKey(date: $0.occurredAt) == month
                        && TransactionRules.isStableIncome($0)
                }
                .reduce(Decimal.zero) { $0 + $1.amount }
        }
    }

    private static func monthlyStableSurpluses(
        transactions: [TransactionRecord],
        months: [MonthKey],
        refundsByOriginal: [UUID: Decimal]
    ) -> [Decimal] {
        months.map { month in
            let records = transactions.filter {
                MonthKey(date: $0.occurredAt) == month
            }
            let stableIncome = records
                .filter(TransactionRules.isStableIncome)
                .reduce(Decimal.zero) { $0 + $1.amount }
            let expenses = records
                .filter {
                    $0.direction == .expense
                        && !TransactionRules.isExcludedFromLivingExpenses($0)
                }
                .reduce(Decimal.zero) {
                    $0 + adjustedExpenseAmount(
                        $1,
                        refundsByOriginal: refundsByOriginal
                    )
                }
            return stableIncome - expenses
        }
    }

    private static func adjustedExpenseAmount(
        _ expense: TransactionRecord,
        refundsByOriginal: [UUID: Decimal]
    ) -> Decimal {
        max(
            Decimal.zero,
            expense.amount - (refundsByOriginal[expense.id] ?? 0)
        )
    }

    private static func median(_ values: [Decimal]) -> Decimal {
        guard !values.isEmpty else { return 0 }
        let values = values.sorted()
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

public enum MonthlySummaryCalculator {
    public static func calculate(
        transactions: [TransactionRecord],
        reportDate: Date,
        assetSnapshot: AssetSnapshot,
        coverage explicitCoverage: TransactionCoverage? = nil
    ) -> MonthlyFinancialSummaryV1 {
        let calendar = MonthKey.calendar
        let interval = calendar.dateInterval(of: .month, for: reportDate)
            ?? DateInterval(start: reportDate, duration: 1)
        let periodEnd = calendar.date(
            byAdding: .second,
            value: -1,
            to: interval.end
        ) ?? interval.end
        let monthlyRecords = transactions.filter {
            $0.occurredAt >= interval.start && $0.occurredAt < interval.end
        }
        let income = monthlyRecords
            .filter { !TransactionRules.isExcludedFromReportedIncome($0) }
            .reduce(Decimal.zero) { $0 + $1.amount }
            .rounded()
        let refundIncome = monthlyRecords
            .filter(TransactionRules.isEligibleRefundIncome)
            .reduce(Decimal.zero) { $0 + $1.amount }
            .rounded()
        let livingExpense = monthlyRecords
            .filter {
                $0.direction == .expense
                    && !TransactionRules.isExcludedFromLivingExpenses($0)
            }
            .reduce(Decimal.zero) { $0 + $1.amount }
            .rounded()
        let completeMonths = MonthCoverage(
            transactions: transactions,
            explicitCoverage: explicitCoverage
        )?.completeMonths ?? []
        let fundValue = assetSnapshot.positions
            .filter { $0.instrument.kind == .fund }
            .reduce(Decimal.zero) { $0 + $1.marketValueInCNY }
            .rounded()
        let stockValue = assetSnapshot.positions
            .filter { $0.instrument.kind == .stock }
            .reduce(Decimal.zero) { $0 + $1.marketValueInCNY }
            .rounded()
        let optionValue = assetSnapshot.positions
            .filter { $0.instrument.kind == .option }
            .reduce(Decimal.zero) { $0 + $1.marketValueInCNY }
            .rounded()
        let cashValue = assetSnapshot.totalCashInCNY.rounded()
        let totalAssets = (
            fundValue + stockValue + optionValue + cashValue
        ).rounded()
        let liabilities = assetSnapshot.outstandingLiabilitiesInCNY.rounded()

        return MonthlyFinancialSummaryV1(
            periodStart: interval.start,
            periodEnd: periodEnd,
            isCompleteMonth: completeMonths.contains(
                MonthKey(date: reportDate)
            ),
            transactionCount: monthlyRecords.filter {
                !TransactionRules.isExcludedFromReportedIncome($0)
                    || (
                        $0.direction == .expense
                            && !TransactionRules.isExcludedFromLivingExpenses($0)
                    )
                    || TransactionRules.isEligibleRefundIncome($0)
            }.count,
            income: income,
            livingExpense: livingExpense,
            refundIncome: refundIncome,
            netCashFlow: (income + refundIncome - livingExpense).rounded(),
            assetSnapshotDate: assetSnapshot.capturedAt,
            fundValue: fundValue,
            stockValue: stockValue,
            optionValue: optionValue,
            cashValue: cashValue,
            totalAssets: totalAssets,
            liabilities: liabilities,
            investableNetWorth: assetSnapshot.investableNetWorthInCNY.rounded()
        )
    }
}

private enum RefundMatcher {
    static func matchedAmountsByOriginal(
        in transactions: [TransactionRecord]
    ) -> [UUID: Decimal] {
        let expenses = transactions.filter {
            $0.direction == .expense
                && !TransactionRules.isExcludedFromLivingExpenses($0)
        }
        var remainingByExpense = Dictionary(
            uniqueKeysWithValues: expenses.map { ($0.id, $0.amount) }
        )
        var matchedByExpense: [UUID: Decimal] = [:]

        let refunds = transactions
            .filter(TransactionRules.isEligibleRefundIncome)
            .sorted {
                if $0.occurredAt == $1.occurredAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.occurredAt < $1.occurredAt
            }

        for refund in refunds {
            let candidates = expenses.filter { expense in
                guard expense.currency == refund.currency,
                      expense.occurredAt <= refund.occurredAt,
                      let remaining = remainingByExpense[expense.id],
                      remaining > 0,
                      descriptorsMatch(expense: expense, refund: refund)
                else {
                    return false
                }

                let elapsed = refund.occurredAt.timeIntervalSince(
                    expense.occurredAt
                )
                return elapsed <= 366 * 24 * 60 * 60
            }

            let exactAmount = candidates.filter {
                remainingByExpense[$0.id] == refund.amount
            }
            let selected: TransactionRecord?
            if exactAmount.count == 1 {
                selected = exactAmount[0]
            } else if exactAmount.isEmpty, candidates.count == 1 {
                selected = candidates[0]
            } else {
                selected = nil
            }

            guard let selected,
                  let remaining = remainingByExpense[selected.id]
            else {
                continue
            }
            let applied = min(remaining, refund.amount)
            guard applied > 0 else { continue }
            remainingByExpense[selected.id] = remaining - applied
            matchedByExpense[selected.id, default: 0] += applied
        }

        return matchedByExpense
    }

    private static func descriptorsMatch(
        expense: TransactionRecord,
        refund: TransactionRecord
    ) -> Bool {
        let expenseDescriptor = normalizedMerchant(expense.merchantNote)
        let refundDescriptor = normalizedMerchant(refund.merchantNote)
        guard expenseDescriptor.count >= 2, refundDescriptor.count >= 2 else {
            return false
        }

        return expenseDescriptor == refundDescriptor
            || expenseDescriptor.contains(refundDescriptor)
            || refundDescriptor.contains(expenseDescriptor)
    }

    private static func normalizedMerchant(_ value: String) -> String {
        let removable = [
            "退款", "退货", "返现", "支付", "收款", "收入", "支出",
            "订单", "交易", "成功",
        ]
        var result = value.lowercased()
        for token in removable {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.filter { $0.isLetter || $0.isNumber }
    }
}

private struct MonthCoverage {
    let periodStart: Date
    let periodEnd: Date
    let completeMonths: [MonthKey]

    init?(
        transactions: [TransactionRecord],
        explicitCoverage: TransactionCoverage? = nil
    ) {
        let periodStart = explicitCoverage?.start
            ?? transactions.map(\.occurredAt).min()
        let periodEnd = explicitCoverage?.end
            ?? transactions.map(\.occurredAt).max()
        guard let periodStart, let periodEnd, periodStart <= periodEnd else {
            return nil
        }

        self.periodStart = periodStart
        self.periodEnd = periodEnd

        let calendar = MonthKey.calendar
        var first = MonthKey(date: periodStart)
        let startDay = calendar.component(.day, from: periodStart)
        if startDay != 1 {
            first = first.advanced(by: 1)
        }

        var last = MonthKey(date: periodEnd)
        let endDay = calendar.component(.day, from: periodEnd)
        let endMonthDays = calendar.range(of: .day, in: .month, for: periodEnd)?.count ?? 31
        if endDay != endMonthDays {
            last = last.advanced(by: -1)
        }

        guard first <= last else {
            completeMonths = []
            return
        }

        var months: [MonthKey] = []
        var cursor = first
        while cursor <= last {
            months.append(cursor)
            cursor = cursor.advanced(by: 1)
        }
        completeMonths = months
    }

    func actualSpendingWindow(
        transactions: [TransactionRecord],
        useRollingTwelveMonths: Bool
    ) -> [TransactionRecord] {
        let calendar = MonthKey.calendar
        let inclusiveStart = calendar.startOfDay(for: periodStart)
        let exclusiveEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: periodEnd)
        ) ?? periodEnd
        let rollingStart: Date
        if useRollingTwelveMonths {
            rollingStart = calendar.date(
                byAdding: .month,
                value: -12,
                to: exclusiveEnd
            ) ?? inclusiveStart
        } else {
            rollingStart = inclusiveStart
        }
        let lowerBound = max(inclusiveStart, rollingStart)

        return transactions.filter {
            $0.occurredAt >= lowerBound && $0.occurredAt < exclusiveEnd
        }
    }
}

private struct MonthKey: Hashable, Comparable {
    let year: Int
    let month: Int

    init(date: Date) {
        let components = Self.calendar.dateComponents([.year, .month], from: date)
        year = components.year ?? 0
        month = components.month ?? 0
    }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    func advanced(by months: Int) -> Self {
        let zeroBased = year * 12 + month - 1 + months
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
