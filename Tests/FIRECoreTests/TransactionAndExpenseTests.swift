import FIRECore
import Foundation
import XCTest

final class TransactionAndExpenseTests: XCTestCase {
    func testMonthlySummaryUsesLocalRulesAndAssetBreakdown() {
        let expense = transaction(
            date: testDate(2026, 6, 5),
            amount: 3_000,
            note: "家居商店"
        )
        let records = [
            transaction(
                date: testDate(2026, 6, 1),
                direction: .income,
                amount: 10_000,
                primary: "工资"
            ),
            expense,
            transaction(
                date: testDate(2026, 6, 20),
                direction: .income,
                amount: 500,
                primary: "退款",
                note: "家居商店退款",
                refund: true
            ),
            transaction(
                date: testDate(2026, 6, 22),
                direction: .income,
                amount: 2_000,
                primary: "基金卖出",
                investmentTrade: true
            ),
            transaction(
                date: testDate(2026, 6, 23),
                amount: 1_000,
                duplicate: true
            ),
            transaction(
                date: testDate(2026, 6, 24),
                amount: 1_000,
                loanPrincipal: true
            ),
        ]
        let fund = Instrument(
            name: "基金",
            kind: .fund,
            currency: .cny
        )
        let stock = Instrument(
            name: "股票",
            kind: .stock,
            currency: .cny
        )
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 6, 30),
            positions: [
                PositionSnapshot(
                    instrument: fund,
                    originalMarketValue: 10_000,
                    marketValueInCNY: 10_000,
                    capturedAt: testDate(2026, 6, 30)
                ),
                PositionSnapshot(
                    instrument: stock,
                    originalMarketValue: 5_000,
                    marketValueInCNY: 5_000,
                    capturedAt: testDate(2026, 6, 30)
                ),
            ],
            cashValueInCNY: 2_000,
            liabilities: [
                Liability(
                    name: "贷款",
                    currency: .cny,
                    remainingPrincipal: 1_000,
                    remainingPrincipalInCNY: 1_000,
                    updatedAt: testDate(2026, 6, 30)
                ),
            ],
            status: .confirmedComplete
        )

        let summary = MonthlySummaryCalculator.calculate(
            transactions: records,
            reportDate: testDate(2026, 6, 15),
            assetSnapshot: snapshot,
            coverage: TransactionCoverage(
                start: testDate(2026, 6, 1, 0),
                end: testDate(2026, 6, 30, 23)
            )
        )

        XCTAssertTrue(summary.isCompleteMonth)
        XCTAssertEqual(summary.transactionCount, 3)
        XCTAssertEqual(summary.income, 10_000)
        XCTAssertEqual(summary.livingExpense, 3_000)
        XCTAssertEqual(summary.refundIncome, 500)
        XCTAssertEqual(summary.netCashFlow, 7_500)
        XCTAssertEqual(summary.fundValue, 10_000)
        XCTAssertEqual(summary.stockValue, 5_000)
        XCTAssertEqual(summary.cashValue, 2_000)
        XCTAssertEqual(summary.totalAssets, 17_000)
        XCTAssertEqual(summary.liabilities, 1_000)
        XCTAssertEqual(summary.investableNetWorth, 16_000)
    }

    func testMonthlySummaryCountsCrossMonthRefundInCashFlowMonth() {
        let records = [
            transaction(
                date: testDate(2026, 6, 28),
                amount: 500,
                note: "商店"
            ),
            transaction(
                date: testDate(2026, 7, 2),
                direction: .income,
                amount: 500,
                primary: "退款",
                note: "商店退款",
                refund: true
            ),
        ]
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 7, 31),
            positions: [],
            status: .confirmedComplete
        )

        let summary = MonthlySummaryCalculator.calculate(
            transactions: records,
            reportDate: testDate(2026, 7, 15),
            assetSnapshot: snapshot
        )

        XCTAssertEqual(summary.transactionCount, 1)
        XCTAssertEqual(summary.income, 0)
        XCTAssertEqual(summary.livingExpense, 0)
        XCTAssertEqual(summary.refundIncome, 500)
        XCTAssertEqual(summary.netCashFlow, 500)
    }

    func testDuplicateDetectorMarksOnlyLaterCopies() {
        let original = transaction(
            date: testDate(2025, 1, 15, 12, 30),
            amount: Decimal(string: "24.50")!,
            primary: "旅行度假",
            secondary: "旅行其他",
            note: "示例软件服务有限公司支付"
        )

        let result = DuplicateDetector.markSuspectedDuplicates([original, original, original])

        XCTAssertFalse(result[0].suspectedDuplicate)
        XCTAssertTrue(result[1].suspectedDuplicate)
        XCTAssertTrue(result[2].suspectedDuplicate)
        XCTAssertEqual(result[1].duplicateOfFingerprint, result[0].fingerprint)
        XCTAssertEqual(result[2].duplicateOfFingerprint, result[0].fingerprint)
    }

    func testIncrementalImportUsesFingerprintMultiplicity() {
        let original = transaction(
            date: testDate(2025, 1, 15, 12, 30),
            amount: Decimal(string: "24.50")!,
            note: "相同消费"
        )
        let incoming = DuplicateDetector.markSuspectedDuplicates([
            original,
            original,
        ])

        let additions = TransactionImportReconciler.transactionsToInsert(
            existingFingerprints: [original.fingerprint],
            incoming: incoming
        )

        XCTAssertEqual(additions.count, 1)
        XCTAssertTrue(additions[0].suspectedDuplicate)
    }

    func testAnnualSpendingUsesMonthlyMedianAndObservedIrregularSpending() {
        var records: [TransactionRecord] = [
            transaction(date: testDate(2026, 1, 1), amount: 1_000),
            transaction(date: testDate(2026, 1, 2), amount: 3_000, primary: "住房", secondary: "房租"),
            transaction(date: testDate(2026, 2, 1), amount: 1_100),
            transaction(date: testDate(2026, 2, 2), amount: 3_000, primary: "住房", secondary: "房租"),
            transaction(date: testDate(2026, 3, 1), amount: 900),
            transaction(date: testDate(2026, 3, 2), amount: 3_000, primary: "住房", secondary: "房租"),
            transaction(date: testDate(2026, 4, 1), amount: 1_000),
            transaction(date: testDate(2026, 4, 2), amount: 3_000, primary: "住房", secondary: "房租"),
            transaction(date: testDate(2026, 1, 10), amount: 500, primary: "旅行度假"),
            transaction(date: testDate(2026, 2, 10), amount: 300, primary: "医疗健康"),
            transaction(date: testDate(2026, 3, 10), amount: 2_500, primary: "人情"),
            transaction(
                date: testDate(2026, 4, 10),
                amount: 2_000,
                primary: "购物",
                note: "有品商店"
            ),
            transaction(
                date: testDate(2026, 4, 15),
                amount: 1_000,
                primary: "资金往来",
                secondary: "还款"
            ),
            transaction(
                date: testDate(2026, 4, 20),
                amount: 5_000,
                primary: "保险理财",
                note: "盈米宝充值"
            ),
            transaction(
                date: testDate(2026, 4, 25),
                direction: .income,
                amount: 100,
                primary: "退款",
                note: "有品商店订单退款",
                refund: true
            ),
            transaction(
                date: testDate(2026, 4, 30),
                amount: 0,
                primary: "内部转账",
                internalTransfer: true
            ),
        ]
        records = DuplicateDetector.markSuspectedDuplicates(records)

        let result = ExpenseAnalyzer.analyze(
            records,
            coverage: TransactionCoverage(
                start: testDate(2026, 1, 1, 0),
                end: testDate(2026, 4, 30, 23)
            )
        )

        XCTAssertEqual(result.completeMonthCount, 4)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.recurringAnnualized, 48_000)
        XCTAssertEqual(result.irregularObservedOrRolling12, 5_200)
        XCTAssertEqual(result.refundOffset, 100)
        XCTAssertEqual(result.annualSpending, 53_200)
    }

    func testUnmatchedOrInvestmentRefundDoesNotReduceLivingExpenses() {
        let records = [
            transaction(
                date: testDate(2026, 1, 5),
                amount: 3_000,
                primary: "购物",
                note: "家居商店"
            ),
            transaction(
                date: testDate(2026, 1, 20),
                direction: .income,
                amount: 500,
                primary: "退款",
                note: "另一家商店退款",
                refund: true
            ),
            transaction(
                date: testDate(2026, 1, 21),
                direction: .income,
                amount: 500,
                primary: "基金退款",
                note: "家居商店退款",
                investmentTrade: true,
                refund: true
            ),
            transaction(
                date: testDate(2026, 1, 31),
                amount: 0,
                internalTransfer: true
            ),
        ]

        let result = ExpenseAnalyzer.analyze(records)

        XCTAssertEqual(result.irregularObservedOrRolling12, 3_000)
        XCTAssertEqual(result.refundOffset, 0)
        XCTAssertEqual(result.annualSpending, 3_000)
    }

    func testMatchedRefundAdjustsOriginalRecurringMonthBeforeMedian() {
        let records = [
            transaction(
                date: testDate(2026, 1, 5),
                amount: 1_000,
                note: "固定商户一"
            ),
            transaction(
                date: testDate(2026, 2, 5),
                amount: 1_100,
                note: "固定商户二"
            ),
            transaction(
                date: testDate(2026, 3, 5),
                amount: 1_200,
                note: "固定商户三"
            ),
            transaction(
                date: testDate(2026, 4, 5),
                amount: 1_300,
                note: "固定商户四"
            ),
            transaction(
                date: testDate(2026, 4, 20),
                direction: .income,
                amount: 400,
                primary: "退款",
                note: "固定商户四退款",
                refund: true
            ),
            transaction(
                date: testDate(2026, 4, 30),
                amount: 0,
                internalTransfer: true
            ),
        ]

        let result = ExpenseAnalyzer.analyze(
            records,
            coverage: TransactionCoverage(
                start: testDate(2026, 1, 1, 0),
                end: testDate(2026, 4, 30, 23)
            )
        )

        XCTAssertEqual(result.recurringAnnualized, 12_600)
        XCTAssertEqual(result.refundOffset, 400)
        XCTAssertEqual(result.annualSpending, 12_600)
    }

    func testYingmibaoTopUpIsExcludedButOrdinaryTopUpsAreNot() {
        let investmentTopUp = transaction(
            date: testDate(2026, 1, 1),
            amount: 1_000,
            primary: "保险理财",
            note: "盈米宝充值"
        )
        let phoneTopUp = transaction(
            date: testDate(2026, 1, 1),
            amount: 100,
            primary: "通讯",
            note: "手机话费充值"
        )
        let transitTopUp = transaction(
            date: testDate(2026, 1, 1),
            amount: 50,
            primary: "交通",
            note: "交通卡充值"
        )

        XCTAssertTrue(TransactionRules.isExcludedFromLivingExpenses(investmentTopUp))
        XCTAssertFalse(TransactionRules.isExcludedFromLivingExpenses(phoneTopUp))
        XCTAssertFalse(TransactionRules.isExcludedFromLivingExpenses(transitTopUp))
    }

    func testTwelveMonthHistoryUsesRollingTwelveForIrregularSpending() {
        var records: [TransactionRecord] = []
        for offset in 0..<13 {
            let year = 2025 + offset / 12
            let month = offset % 12 + 1
            records.append(
                transaction(date: testDate(year, month, 1), amount: 100)
            )
        }
        records.append(
            transaction(
                date: testDate(2025, 1, 10),
                amount: 1_000,
                primary: "旅行度假"
            )
        )
        records.append(
            transaction(
                date: testDate(2026, 1, 10),
                amount: 200,
                primary: "医疗健康"
            )
        )
        records.append(
            transaction(
                date: testDate(2026, 1, 31),
                amount: 0,
                internalTransfer: true
            )
        )

        let result = ExpenseAnalyzer.analyze(records)

        XCTAssertEqual(result.completeMonthCount, 13)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.recurringAnnualized, 1_200)
        XCTAssertEqual(result.irregularObservedOrRolling12, 200)
        XCTAssertEqual(result.annualSpending, 1_400)
    }

    func testConfidenceBandsMatchCompleteMonthThresholds() {
        XCTAssertEqual(DataConfidence.from(completeMonthCount: 2), .insufficient)
        XCTAssertEqual(DataConfidence.from(completeMonthCount: 3), .low)
        XCTAssertEqual(DataConfidence.from(completeMonthCount: 6), .medium)
        XCTAssertEqual(DataConfidence.from(completeMonthCount: 12), .high)
    }

    func testExplicitExportCoverageCountsMonthWithoutBoundaryTransactions() {
        let records = [
            transaction(date: testDate(2026, 3, 8), amount: 100),
            transaction(date: testDate(2026, 3, 22), amount: 200),
        ]
        let coverage = TransactionCoverage(
            start: testDate(2026, 3, 1, 0),
            end: testDate(2026, 3, 31, 0)
        )

        let inferred = ExpenseAnalyzer.analyze(records)
        let explicit = ExpenseAnalyzer.analyze(
            records,
            coverage: coverage
        )

        XCTAssertEqual(inferred.completeMonthCount, 0)
        XCTAssertEqual(explicit.completeMonthCount, 1)
        XCTAssertEqual(explicit.recurringAnnualized, 3_600)
    }

    func testPartialBoundaryMonthIrregularSpendingIsStillObserved() {
        let records = [
            transaction(
                date: testDate(2026, 3, 20),
                amount: 3_000,
                primary: "旅行度假"
            ),
            transaction(
                date: testDate(2026, 4, 10),
                amount: 1_000,
                primary: "日用"
            ),
            transaction(
                date: testDate(2026, 4, 30),
                amount: 0,
                internalTransfer: true
            ),
        ]
        let coverage = TransactionCoverage(
            start: testDate(2026, 3, 15, 0),
            end: testDate(2026, 4, 30, 0)
        )

        let result = ExpenseAnalyzer.analyze(records, coverage: coverage)

        XCTAssertEqual(result.completeMonthCount, 1)
        XCTAssertEqual(result.recurringAnnualized, 12_000)
        XCTAssertEqual(result.irregularObservedOrRolling12, 3_000)
        XCTAssertEqual(result.annualSpending, 15_000)
    }

    func testCoverageMergerDoesNotInventCompleteMonthsAcrossGap() {
        let march = TransactionCoverage(
            start: testDate(2026, 3, 1, 0),
            end: testDate(2026, 3, 31, 0)
        )
        let june = TransactionCoverage(
            start: testDate(2026, 6, 1, 0),
            end: testDate(2026, 6, 30, 0)
        )

        let result = TransactionCoverageMerger.merge(
            existing: march,
            incoming: june
        )

        XCTAssertTrue(result.hadGap)
        XCTAssertEqual(result.coverage, june)
    }

    func testCoverageMergerUnionsAdjacentRanges() {
        let march = TransactionCoverage(
            start: testDate(2026, 3, 1, 0),
            end: testDate(2026, 3, 31, 0)
        )
        let april = TransactionCoverage(
            start: testDate(2026, 4, 1, 0),
            end: testDate(2026, 4, 30, 0)
        )

        let result = TransactionCoverageMerger.merge(
            existing: march,
            incoming: april
        )

        XCTAssertFalse(result.hadGap)
        XCTAssertEqual(result.coverage.start, march.start)
        XCTAssertEqual(result.coverage.end, april.end)
    }

    func testContributionSuggestionUsesMedianStableNetSurplus() {
        var records: [TransactionRecord] = []
        let expenses: [Decimal] = [4_000, 5_000, 6_000]
        for month in 1...3 {
            records.append(
                transaction(
                    date: testDate(2026, month, 1),
                    direction: .income,
                    amount: 10_000,
                    primary: "职业收入",
                    secondary: "工资"
                )
            )
            records.append(
                transaction(
                    date: testDate(2026, month, 2),
                    direction: .income,
                    amount: 20_000,
                    primary: "职业收入",
                    secondary: "奖金"
                )
            )
            records.append(
                transaction(
                    date: testDate(2026, month, 3),
                    amount: expenses[month - 1]
                )
            )
        }
        records.append(
            transaction(
                date: testDate(2026, 3, 31),
                amount: 0,
                internalTransfer: true
            )
        )

        let result = ExpenseAnalyzer.suggestMonthlyContribution(from: records)

        XCTAssertEqual(result.amount, 5_000)
        XCTAssertEqual(result.monthsUsed, 3)
        XCTAssertEqual(result.confidence, .low)
    }

    func testContributionHistoryUsesLatestSixMonthsAndExcludesBonus() {
        var records: [TransactionRecord] = []
        let monthlyStableIncomes: [Decimal] = [
            9_000,
            10_000,
            11_000,
            12_000,
            13_000,
            14_000,
            15_000,
        ]
        let monthlySurpluses: [Decimal] = [
            100,
            1_000,
            2_000,
            3_000,
            4_000,
            5_000,
            6_000,
        ]
        for (offset, surplus) in monthlySurpluses.enumerated() {
            let month = offset + 1
            records.append(
                transaction(
                    date: testDate(2026, month, 1),
                    direction: .income,
                    amount: monthlyStableIncomes[offset],
                    primary: "职业收入",
                    secondary: "工资"
                )
            )
            records.append(
                transaction(
                    date: testDate(2026, month, 2),
                    amount: monthlyStableIncomes[offset] - surplus
                )
            )
        }
        records.append(
            transaction(
                date: testDate(2026, 7, 3),
                direction: .income,
                amount: 100_000,
                primary: "职业收入",
                secondary: "绩效奖金"
            )
        )

        let reference = ExpenseAnalyzer.contributionHistoryReference(
            from: records,
            coverage: TransactionCoverage(
                start: testDate(2026, 1, 1, 0),
                end: testDate(2026, 7, 31, 23)
            )
        )

        XCTAssertEqual(reference.monthlySurplus.monthsUsed, 6)
        XCTAssertEqual(reference.monthlySurplus.median, 3_500)
        XCTAssertEqual(reference.monthlySurplus.latest, 6_000)
        XCTAssertEqual(reference.monthlySurplus.minimum, 1_000)
        XCTAssertEqual(reference.monthlySurplus.maximum, 6_000)
        XCTAssertEqual(reference.monthlyStableIncome.monthsUsed, 6)
        XCTAssertEqual(reference.monthlyStableIncome.median, 12_500)
        XCTAssertEqual(reference.monthlyStableIncome.latest, 15_000)
        XCTAssertEqual(reference.monthlyStableIncome.minimum, 10_000)
        XCTAssertEqual(reference.monthlyStableIncome.maximum, 15_000)
    }

    func testAnnualBonusReferenceGroupsByYearAndFiltersInvalidRecords() {
        let validRecords = [
            transaction(
                date: testDate(2024, 12, 20),
                direction: .income,
                amount: 40_000,
                primary: "职业收入",
                secondary: "绩效奖金"
            ),
            transaction(
                date: testDate(2025, 1, 20),
                direction: .income,
                amount: 20_000,
                primary: "职业收入",
                secondary: "年终奖"
            ),
            transaction(
                date: testDate(2025, 12, 20),
                direction: .income,
                amount: 40_000,
                primary: "职业收入",
                secondary: "绩效奖金"
            ),
            transaction(
                date: testDate(2026, 1, 20),
                direction: .income,
                amount: 100_000,
                primary: "职业收入",
                secondary: "十三薪"
            ),
        ]
        let invalidRecords = [
            transaction(
                date: testDate(2026, 2, 1),
                direction: .income,
                amount: 1_000_000,
                primary: "职业收入",
                secondary: "绩效奖金",
                included: false
            ),
            transaction(
                date: testDate(2026, 2, 2),
                direction: .income,
                amount: 1_000_000,
                primary: "职业收入",
                secondary: "绩效奖金",
                duplicate: true
            ),
            transaction(
                date: testDate(2026, 2, 3),
                direction: .income,
                amount: 1_000_000,
                primary: "职业收入",
                secondary: "绩效奖金",
                internalTransfer: true
            ),
            transaction(
                date: testDate(2026, 2, 4),
                direction: .income,
                amount: 1_000_000,
                primary: "职业收入",
                secondary: "绩效奖金",
                investmentTrade: true
            ),
            transaction(
                date: testDate(2026, 2, 5),
                direction: .income,
                amount: 1_000_000,
                primary: "职业收入",
                secondary: "绩效奖金",
                loanPrincipal: true
            ),
            transaction(
                date: testDate(2026, 2, 6),
                direction: .income,
                amount: 1_000_000,
                primary: "职业收入",
                secondary: "绩效奖金",
                refund: true
            ),
            transaction(
                date: testDate(2026, 2, 7),
                amount: 1_000_000,
                primary: "职业收入",
                secondary: "绩效奖金"
            ),
            transaction(
                date: testDate(2026, 2, 8),
                direction: .income,
                amount: 1_000_000,
                primary: "职业收入",
                secondary: "绩效工资"
            ),
        ]

        let reference = ExpenseAnalyzer.contributionHistoryReference(
            from: validRecords + invalidRecords,
            coverage: TransactionCoverage(
                start: testDate(2024, 1, 1, 0),
                end: testDate(2026, 12, 31, 23)
            )
        )

        XCTAssertTrue(
            TransactionRules.isAnnualBonusIncome(validRecords[0])
        )
        XCTAssertEqual(reference.annualBonus.latestYear, 2026)
        XCTAssertEqual(reference.annualBonus.latestYearTotal, 100_000)
        XCTAssertEqual(reference.annualBonus.annualMedian, 60_000)
        XCTAssertEqual(reference.annualBonus.yearsUsed, 3)
        XCTAssertEqual(reference.annualBonus.transactionCount, 4)
    }
}
