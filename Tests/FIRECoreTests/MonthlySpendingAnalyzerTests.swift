import FIRECore
import Foundation
import XCTest

final class MonthlySpendingAnalyzerTests: XCTestCase {
    func testUsesOnlyEligibleSelectedMonthLivingExpenses() {
        let valid = transaction(
            date: testDate(2026, 6, 3),
            amount: 1_000,
            note: "本月有效"
        )
        let transactions = [
            valid,
            transaction(
                date: testDate(2026, 6, 4),
                amount: 2_000,
                included: false
            ),
            transaction(
                date: testDate(2026, 6, 5),
                amount: 3_000,
                duplicate: true
            ),
            transaction(
                date: testDate(2026, 6, 6),
                amount: 4_000,
                internalTransfer: true
            ),
            transaction(
                date: testDate(2026, 6, 7),
                amount: 5_000,
                investmentTrade: true
            ),
            transaction(
                date: testDate(2026, 6, 8),
                amount: 6_000,
                loanPrincipal: true
            ),
            transaction(
                date: testDate(2026, 6, 9),
                direction: .income,
                amount: 7_000
            ),
            transaction(
                date: testDate(2026, 7, 1),
                amount: 8_000,
                note: "未来月"
            ),
        ]

        let result = MonthlySpendingAnalyzer.analyze(
            transactions: transactions,
            reportDate: testDate(2026, 6, 15)
        )

        XCTAssertEqual(result.livingExpense, 1_000)
        XCTAssertEqual(result.largestExpenses.map(\.fingerprint), [valid.fingerprint])
        XCTAssertFalse(result.largestExpenses.contains { $0.merchantNote == "未来月" })
    }

    func testWithoutCoverageUsesThreeLatestEarlierMonthsWithEligibleSpending() {
        let transactions = [
            transaction(date: testDate(2026, 1, 5), amount: 500),
            transaction(date: testDate(2026, 2, 5), amount: 600),
            transaction(date: testDate(2026, 3, 5), amount: 700),
            transaction(date: testDate(2026, 5, 5), amount: 1_000),
            transaction(date: testDate(2026, 6, 5), amount: 1_800),
            transaction(date: testDate(2026, 7, 5), amount: 50_000),
        ]

        let result = MonthlySpendingAnalyzer.analyze(
            transactions: transactions,
            reportDate: testDate(2026, 6, 15)
        )

        XCTAssertEqual(result.comparisonMonthCount, 3)
        XCTAssertEqual(result.categoryChanges.first?.baselineMedianAmount, 700)
        XCTAssertEqual(result.categoryChanges.first?.currentAmount, 1_800)
    }

    func testExplicitCoverageUsesOnlyCompleteEarlierMonthsIncludingZeroSpend() {
        let transactions = [
            transaction(date: testDate(2026, 2, 5), amount: 9_000),
            transaction(date: testDate(2026, 3, 5), amount: 1_000),
            transaction(date: testDate(2026, 5, 5), amount: 1_000),
            transaction(date: testDate(2026, 6, 5), amount: 1_800),
        ]
        let coverage = TransactionCoverage(
            start: testDate(2026, 1, 15),
            end: testDate(2026, 6, 30)
        )

        let result = MonthlySpendingAnalyzer.analyze(
            transactions: transactions,
            reportDate: testDate(2026, 6, 15),
            coverage: coverage
        )

        XCTAssertEqual(result.comparisonMonthCount, 3)
        XCTAssertEqual(result.categoryChanges.first?.baselineMedianAmount, 1_000)
        XCTAssertEqual(result.categoryChanges.first?.changeAmount, 800)
    }

    func testFindsNewIncreasingAndDecreasingCategories() {
        var records: [TransactionRecord] = []
        for month in 3...5 {
            records += [
                transaction(
                    date: testDate(2026, month, 2),
                    amount: 1_000,
                    primary: "餐饮"
                ),
                transaction(
                    date: testDate(2026, month, 3),
                    amount: 3_000,
                    primary: "购物"
                ),
                transaction(
                    date: testDate(2026, month, 4),
                    amount: 1_000,
                    primary: "杂项"
                ),
            ]
        }
        records += [
            transaction(
                date: testDate(2026, 6, 2),
                amount: 1_800,
                primary: "餐饮"
            ),
            transaction(
                date: testDate(2026, 6, 3),
                amount: 1_200,
                primary: "旅行"
            ),
            transaction(
                date: testDate(2026, 6, 4),
                amount: 100,
                primary: "杂项"
            ),
        ]

        let result = MonthlySpendingAnalyzer.analyze(
            transactions: records,
            reportDate: testDate(2026, 6, 15)
        )
        let changes = Dictionary(
            uniqueKeysWithValues: result.categoryChanges.map {
                ($0.primaryCategory, $0)
            }
        )

        XCTAssertEqual(result.categoryChanges.map(\.primaryCategory), ["购物", "旅行", "餐饮"])
        XCTAssertEqual(changes["购物"]?.changeAmount, -3_000)
        XCTAssertEqual(changes["旅行"]?.baselineMedianAmount, 0)
        XCTAssertNil(changes["旅行"]?.changeRate)
        XCTAssertEqual(changes["餐饮"]?.changeRate, Decimal(string: "0.8"))
        XCTAssertNil(changes["杂项"])
    }

    func testLargestExpensesAreFixedTopTenByAmountDescending() {
        let records = (1...12).map { index in
            transaction(
                date: testDate(2026, 6, index),
                amount: Decimal(index * 1_000),
                note: "expense-\(index)"
            )
        }

        let result = MonthlySpendingAnalyzer.analyze(
            transactions: records,
            reportDate: testDate(2026, 6, 15)
        )

        XCTAssertEqual(result.largestExpenses.count, 10)
        XCTAssertEqual(
            result.largestExpenses.map(\.amount),
            (3...12).reversed().map { Decimal($0 * 1_000) }
        )
        XCTAssertEqual(
            result.largestExpenses.first?.monthlyExpenseShare,
            Decimal(string: "0.1538")
        )
    }

    func testFlagsThreeTimesHistoricalMedianButSuppressesFixedRent() {
        let foodHistory = [700, 800, 900, 1_000, 1_100].enumerated().map {
            transaction(
                date: testDate(2026, $0.offset < 3 ? 1 : 2, $0.offset + 1),
                amount: Decimal($0.element),
                primary: "餐饮",
                secondary: "外卖"
            )
        }
        let rentHistory = [10_000, 10_000, 1_000, 1_000, 1_000].enumerated().map {
            transaction(
                date: testDate(2026, $0.offset.isMultiple(of: 2) ? 1 : 2, $0.offset + 10),
                amount: Decimal($0.element),
                primary: "住房",
                secondary: "房租"
            )
        }
        let foodSpike = transaction(
            date: testDate(2026, 3, 5),
            amount: 3_000,
            primary: "餐饮",
            secondary: "外卖",
            note: "宴请"
        )
        let fixedRent = transaction(
            date: testDate(2026, 3, 6),
            amount: 10_000,
            primary: "住房",
            secondary: "房租",
            note: "每月房租"
        )

        let result = MonthlySpendingAnalyzer.analyze(
            transactions: foodHistory + rentHistory + [foodSpike, fixedRent],
            reportDate: testDate(2026, 3, 15)
        )

        XCTAssertEqual(result.comparisonMonthCount, 2)
        XCTAssertEqual(result.unusualExpenses.map(\.fingerprint), [foodSpike.fingerprint])
        XCTAssertTrue(result.unusualExpenses[0].reason?.contains("3.3") == true)
    }

    func testOldPacketAndReportJSONDecodeWithoutSpendingAnalysis() throws {
        let packet = makePacket(transactions: [])
        let report = makeReport()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let oldPacketData = try removingSpendingAnalysis(
            from: encoder.encode(packet)
        )
        let oldReportData = try removingSpendingAnalysis(
            from: encoder.encode(report)
        )

        XCTAssertNil(
            try decoder.decode(AnalysisPacketV1.self, from: oldPacketData)
                .spendingAnalysis
        )
        XCTAssertNil(
            try decoder.decode(AnalysisReportV1.self, from: oldReportData)
                .spendingAnalysis
        )
    }

    func testPacketRedactionCoversEverySpendingAnalysisTextAndFingerprint() {
        let record = transaction(
            date: testDate(2026, 6, 5),
            amount: 3_000,
            primary: "付款给李雷",
            secondary: "收款人：赵敏",
            note: "商户 13812345678"
        )
        let signal = MonthlyExpenseSignalV1(
            fingerprint: record.fingerprint,
            occurredAt: record.occurredAt,
            amount: record.amount,
            currency: record.currency,
            merchantNote: record.merchantNote,
            primaryCategory: record.primaryCategory,
            secondaryCategory: record.secondaryCategory,
            monthlyExpenseShare: 1,
            reason: "联系 13812345678"
        )
        let analysis = MonthlySpendingAnalysisV1(
            periodStart: testDate(2026, 6, 1),
            periodEnd: testDate(2026, 6, 30),
            comparisonMonthCount: 2,
            livingExpense: 3_000,
            categoryChanges: [
                MonthlyCategoryChangeV1(
                    primaryCategory: "付款给张三",
                    currency: .cny,
                    currentAmount: 3_000,
                    baselineMedianAmount: 1_000,
                    changeAmount: 2_000,
                    changeRate: 2,
                    currentMonthShare: 1
                ),
            ],
            largestExpenses: [signal],
            unusualExpenses: [signal]
        )
        var packet = makePacket(transactions: [record])
        packet.spendingAnalysis = analysis

        let redacted = PIIRedactor.redact(packet: packet)
        let spending = redacted.spendingAnalysis!

        XCTAssertEqual(
            spending.largestExpenses[0].fingerprint,
            record.id.uuidString.lowercased()
        )
        XCTAssertFalse(spending.largestExpenses[0].merchantNote.contains("13812345678"))
        XCTAssertFalse(spending.largestExpenses[0].primaryCategory.contains("李雷"))
        XCTAssertFalse(spending.largestExpenses[0].secondaryCategory.contains("赵敏"))
        XCTAssertFalse(spending.largestExpenses[0].reason?.contains("13812345678") == true)
        XCTAssertFalse(spending.categoryChanges[0].primaryCategory.contains("张三"))
        XCTAssertEqual(
            spending.unusualExpenses[0].fingerprint,
            record.id.uuidString.lowercased()
        )
    }

    private func removingSpendingAnalysis(from data: Data) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "spendingAnalysis")
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func makePacket(
        transactions: [TransactionRecord]
    ) -> AnalysisPacketV1 {
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 6, 30),
            positions: [],
            status: .confirmedComplete
        )
        let expense = ExpenseAnalyzer.analyze(transactions)
        let state = FIREState(
            calculatedAt: testDate(2026, 6, 30),
            investableNetWorth: 0,
            annualSpending: expense.annualSpending,
            targetAmount: 0,
            progress: 0,
            remainingAmount: 0,
            confirmedMonthlyContribution: nil,
            suggestedMonthlyContribution: MonthlyContributionSuggestion(
                amount: nil,
                monthsUsed: 0,
                confidence: .insufficient,
                rationale: ""
            ),
            estimatedFreedomDate: nil,
            estimatedMonthsRemaining: nil,
            confidence: .insufficient,
            assumptions: .balanced,
            expenseAnalysis: expense
        )
        return AnalysisPacketV1(
            periodStart: testDate(2026, 6, 1),
            periodEnd: testDate(2026, 6, 30),
            transactions: transactions,
            assetSnapshot: snapshot,
            fireState: state
        )
    }

    private func makeReport() -> AnalysisReportV1 {
        let evidence = AnalysisEvidenceV1(
            id: "e1",
            label: "支出",
            value: "0"
        )
        return AnalysisReportV1(
            coreConclusion: "结论",
            dataConfidence: AnalysisConfidenceV1(
                level: .insufficient,
                explanation: "样本不足",
                evidenceRefs: ["e1"]
            ),
            spendingFindings: [],
            assetStructureRisks: [],
            fireDrivers: [],
            actions: [
                AnalysisActionV1(
                    title: "行动",
                    rationale: "理由",
                    evidenceRefs: ["e1"]
                ),
            ],
            evidence: [evidence],
            limitations: []
        )
    }
}
