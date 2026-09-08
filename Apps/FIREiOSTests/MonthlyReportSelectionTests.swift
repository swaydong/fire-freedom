import Foundation
@testable import FIRE
import XCTest

final class MonthlyReportSelectionTests: XCTestCase {
    func testAvailableMonthsUseShanghaiMonthStartsDeduplicatedNewestFirst() {
        let transactions = [
            transaction(date: date(2026, 5, 31, 23, 59)),
            transaction(date: date(2026, 7, 8)),
            transaction(date: date(2026, 6, 1)),
            transaction(date: date(2026, 7, 29)),
        ]

        let months = MonthlyReportSelection.availableMonths(
            from: transactions
        )

        XCTAssertEqual(
            months,
            [
                date(2026, 7, 1, 0, 0),
                date(2026, 6, 1, 0, 0),
                date(2026, 5, 1, 0, 0),
            ]
        )
        XCTAssertEqual(
            MonthlyReportSelection.reportDate(from: transactions),
            date(2026, 7, 1, 0, 0)
        )
    }

    func testAvailableMonthsUseShanghaiTimezoneAtUTCMonthBoundary() {
        let utcFormatter = ISO8601DateFormatter()
        let timestamp = utcFormatter.date(from: "2026-05-31T16:30:00Z")!

        let months = MonthlyReportSelection.availableMonths(
            from: [transaction(date: timestamp)]
        )

        XCTAssertEqual(months, [date(2026, 6, 1, 0, 0)])
    }

    func testUsesLatestCompleteSnapshotNoLaterThanReportMonth() {
        let may = snapshot(date: date(2026, 5, 31), isComplete: true)
        let juneDraft = snapshot(
            date: date(2026, 6, 30),
            isComplete: false
        )
        let july = snapshot(date: date(2026, 7, 31), isComplete: true)

        let selected = MonthlyReportSelection.assetSnapshot(
            for: date(2026, 6, 15),
            from: [july, juneDraft, may]
        )

        XCTAssertIdentical(selected, may)
    }

    func testUsesClosestFutureCompleteSnapshotWhenNoEarlierOneExists() {
        let july = snapshot(date: date(2026, 7, 31), isComplete: true)
        let august = snapshot(date: date(2026, 8, 31), isComplete: true)

        let selected = MonthlyReportSelection.assetSnapshot(
            for: date(2026, 6, 15),
            from: [august, july]
        )

        XCTAssertIdentical(selected, july)
    }

    func testRefusesIncompleteSnapshots() {
        let draft = snapshot(date: date(2026, 6, 30), isComplete: false)

        XCTAssertNil(
            MonthlyReportSelection.assetSnapshot(
                for: date(2026, 6, 15),
                from: [draft]
            )
        )
    }

    private func snapshot(
        date: Date,
        isComplete: Bool
    ) -> AssetSnapshotEntity {
        AssetSnapshotEntity(
            capturedAt: date,
            cashCNY: 0,
            cashValueInCNY: 0,
            liabilityPrincipalCNY: 0,
            positionsCNY: 0,
            isComplete: isComplete,
            exchangeRateState: .current,
            exchangeRateAsOf: date
        )
    }

    private func transaction(date: Date) -> TransactionEntity {
        TransactionEntity(
            fingerprint: UUID().uuidString,
            transactionDate: date,
            directionRawValue: "支出",
            amount: 10,
            category: "餐饮",
            subcategory: "",
            merchant: "测试",
            note: "",
            account: "现金"
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
