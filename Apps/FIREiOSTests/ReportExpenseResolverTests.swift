import FIRECore
import Foundation
@testable import FIRE
import XCTest

final class ReportExpenseResolverTests: XCTestCase {
    func testLinkedExpensesUseLocalTransactionValuesAndRejectIneligibleRecords() {
        let valid = transaction(
            id: UUID(),
            date: date(2026, 6, 8),
            amount: 8_800,
            note: "示例酒店"
        )
        let transfer = transaction(
            id: UUID(),
            date: date(2026, 6, 9),
            amount: 20_000,
            note: "账户互转",
            internalTransfer: true
        )
        let outsideMonth = transaction(
            id: UUID(),
            date: date(2026, 5, 31),
            amount: 12_000,
            note: "上月消费"
        )
        let evidence = AnalysisEvidenceV1(
            id: "expense-1",
            label: "模型生成的描述",
            value: "错误商户 · 99999元",
            transactionFingerprints: [
                valid.id.uuidString.lowercased(),
                transfer.id.uuidString.lowercased(),
                outsideMonth.id.uuidString.lowercased(),
            ]
        )
        let report = report(
            livingExpense: 8_800,
            evidence: [evidence]
        )

        let result = ReportExpenseResolver.linkedExpenses(
            evidenceRefs: ["expense-1", "expense-1"],
            evidenceByID: ["expense-1": evidence],
            report: report,
            transactions: [valid, transfer, outsideMonth]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, valid.id.uuidString.lowercased())
        XCTAssertEqual(result[0].merchantDisplayName, "示例酒店")
        XCTAssertEqual(result[0].amount, 8_800)
    }

    func testNotableExpensesUsePersonalMonthlyThreshold() {
        let records = [
            transaction(
                id: UUID(),
                date: date(2026, 6, 3),
                amount: 12_000,
                note: "大额消费"
            ),
            transaction(
                id: UUID(),
                date: date(2026, 6, 4),
                amount: 9_000,
                note: "普通消费"
            ),
            transaction(
                id: UUID(),
                date: date(2026, 6, 5),
                amount: 30_000,
                note: "投资买入",
                investmentTrade: true
            ),
        ]

        let result = ReportExpenseResolver.notableExpenses(
            report: report(livingExpense: 100_000),
            transactions: records
        )

        XCTAssertEqual(result.map(\.merchantDisplayName), ["大额消费"])
    }

    func testNotableExpensesFallBackToHighestEligibleExpense() {
        let records = [
            transaction(
                id: UUID(),
                date: date(2026, 6, 3),
                amount: 600,
                note: "餐厅"
            ),
            transaction(
                id: UUID(),
                date: date(2026, 6, 4),
                amount: 900,
                note: "商场"
            ),
        ]

        let result = ReportExpenseResolver.notableExpenses(
            report: report(livingExpense: 5_000),
            transactions: records
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].merchantDisplayName, "商场")
        XCTAssertEqual(result[0].amount, 900)
    }

    func testMonthEndFractionalSecondIsIncludedButNextMonthIsExcluded() {
        let finalFractionalSecond = date(
            2026,
            6,
            30,
            23,
            59,
            59
        ).addingTimeInterval(0.5)
        let records = [
            transaction(
                id: UUID(),
                date: finalFractionalSecond,
                amount: 3_000,
                note: "月末消费"
            ),
            transaction(
                id: UUID(),
                date: date(2026, 7, 1, 0, 0, 0),
                amount: 5_000,
                note: "下月消费"
            ),
        ]

        let result = ReportExpenseResolver.notableExpenses(
            report: report(livingExpense: 3_000),
            transactions: records
        )

        XCTAssertEqual(result.map(\.merchantDisplayName), ["月末消费"])
    }

    func testLargestExpensesReturnTopTenAndExcludeNonLivingExpenses() {
        let ordinary = (1...12).map { index in
            transaction(
                id: UUID(),
                date: date(2026, 6, index),
                amount: Decimal(index * 100),
                note: "支出\(index)"
            )
        }
        let excluded = [
            transaction(
                id: UUID(),
                date: date(2026, 6, 20),
                amount: 90_000,
                note: "账户互转",
                internalTransfer: true
            ),
            transaction(
                id: UUID(),
                date: date(2026, 6, 21),
                amount: 80_000,
                note: "投资买入",
                investmentTrade: true
            ),
            transaction(
                id: UUID(),
                date: date(2026, 5, 31),
                amount: 70_000,
                note: "上月支出"
            ),
        ]

        let result = ReportExpenseResolver.largestExpenses(
            report: report(livingExpense: 7_800),
            transactions: ordinary + excluded
        )

        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(
            result.map(\.merchantDisplayName),
            (3...12).reversed().map { "支出\($0)" }
        )
        XCTAssertEqual(
            result.map(\.amount),
            (3...12).reversed().map { Decimal($0 * 100) }
        )
    }

    func testLargestExpensesRespectRequestedLimit() {
        let records = (1...5).map { index in
            transaction(
                id: UUID(),
                date: date(2026, 6, index),
                amount: Decimal(index * 100),
                note: "支出\(index)"
            )
        }

        let result = ReportExpenseResolver.largestExpenses(
            report: report(livingExpense: 1_500),
            transactions: records,
            limit: 3
        )

        XCTAssertEqual(result.map(\.amount), [500, 400, 300])
    }

    private func report(
        livingExpense: Decimal,
        evidence: [AnalysisEvidenceV1] = [
            AnalysisEvidenceV1(
                id: "summary",
                label: "月度汇总",
                value: "本月数据"
            ),
        ]
    ) -> AnalysisReportV1 {
        AnalysisReportV1(
            coreConclusion: "本月结余需要结合大额支出判断。",
            dataConfidence: AnalysisConfidenceV1(
                level: .medium,
                explanation: "已有多个完整月份。",
                evidenceRefs: [evidence[0].id]
            ),
            spendingFindings: [],
            assetStructureRisks: [],
            fireDrivers: [],
            actions: [
                AnalysisActionV1(
                    title: "核对消费",
                    rationale: "确认是否为一次性支出。",
                    evidenceRefs: [evidence[0].id]
                ),
            ],
            evidence: evidence,
            limitations: [],
            monthlySummary: MonthlyFinancialSummaryV1(
                periodStart: date(2026, 6, 1),
                periodEnd: date(2026, 6, 30, 23, 59, 59),
                isCompleteMonth: true,
                transactionCount: 1,
                income: 0,
                livingExpense: livingExpense,
                netCashFlow: -livingExpense,
                assetSnapshotDate: date(2026, 6, 30),
                fundValue: 0,
                stockValue: 0,
                cashValue: 0,
                totalAssets: 0,
                liabilities: 0,
                investableNetWorth: 0
            )
        )
    }

    private func transaction(
        id: UUID,
        date: Date,
        amount: Decimal,
        note: String,
        internalTransfer: Bool = false,
        investmentTrade: Bool = false
    ) -> TransactionRecord {
        TransactionRecord(
            id: id,
            occurredAt: date,
            direction: .expense,
            amount: amount,
            primaryCategory: "日常",
            merchantNote: note,
            includedInCashFlow: true,
            includedInBudget: true,
            isInternalTransfer: internalTransfer,
            isInvestmentTrade: investmentTrade,
            fingerprint: "source-\(id.uuidString)"
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0,
        _ second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        )!
    }
}
