import FIRECore
import Foundation
import XCTest

final class MonthlyProgressCalculatorTests: XCTestCase {
    func testEmptyInputProducesNoPoints() {
        XCTAssertEqual(
            MonthlyProgressCalculator.calculate(
                snapshots: [],
                targetAmount: 500
            ),
            []
        )
    }

    func testSingleCompleteSnapshotProducesInitialPoint() {
        let input = snapshot(
            id: uuid(1),
            date: testDate(2026, 4, 30),
            positions: 80,
            cash: 30,
            liabilities: 10
        )

        let points = MonthlyProgressCalculator.calculate(
            snapshots: [input],
            targetAmount: 500
        )

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].snapshotID, input.id)
        XCTAssertEqual(points[0].monthStart, testDate(2026, 4, 1, 0))
        XCTAssertEqual(points[0].investableNetWorth, 100)
        XCTAssertEqual(points[0].fireProgress, Decimal(string: "0.2"))
        XCTAssertNil(points[0].changeAmount)
        XCTAssertNil(points[0].changeRate)
        XCTAssertNil(points[0].fireProgressChange)
        XCTAssertNil(points[0].monthsSincePrevious)
    }

    func testFiltersIncompleteAndSortsOutOfOrderSnapshots() {
        let january = snapshot(
            id: uuid(1),
            date: testDate(2026, 1, 31),
            positions: 100
        )
        let februaryIncomplete = snapshot(
            id: uuid(2),
            date: testDate(2026, 2, 28),
            positions: 200,
            isComplete: false
        )
        let march = snapshot(
            id: uuid(3),
            date: testDate(2026, 3, 31),
            positions: 130
        )

        let points = MonthlyProgressCalculator.calculate(
            snapshots: [march, februaryIncomplete, january],
            targetAmount: 500
        )

        XCTAssertEqual(points.map(\.snapshotID), [january.id, march.id])
        XCTAssertEqual(points[1].changeAmount, 30)
        XCTAssertEqual(points[1].monthsSincePrevious, 2)
    }

    func testSameMonthUsesLatestSnapshotAndUUIDBreaksTimestampTie() {
        let earlier = snapshot(
            id: uuid(1),
            date: testDate(2026, 4, 1),
            positions: 100
        )
        let lowerIDAtLatestTime = snapshot(
            id: uuid(2),
            date: testDate(2026, 4, 30),
            positions: 200
        )
        let higherIDAtLatestTime = snapshot(
            id: uuid(3),
            date: testDate(2026, 4, 30),
            positions: 300
        )

        let points = MonthlyProgressCalculator.calculate(
            snapshots: [higherIDAtLatestTime, earlier, lowerIDAtLatestTime],
            targetAmount: 500
        )

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].snapshotID, higherIDAtLatestTime.id)
        XCTAssertEqual(points[0].investableNetWorth, 300)
    }

    func testMonthGroupingUsesAsiaShanghaiBoundary() {
        let beforeBoundary = snapshot(
            id: uuid(1),
            date: utcDate(2026, 2, 28, 15, 59),
            positions: 100
        )
        let afterBoundary = snapshot(
            id: uuid(2),
            date: utcDate(2026, 2, 28, 16, 0),
            positions: 110
        )

        let points = MonthlyProgressCalculator.calculate(
            snapshots: [afterBoundary, beforeBoundary],
            targetAmount: 500
        )

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].monthStart, testDate(2026, 2, 1, 0))
        XCTAssertEqual(points[1].monthStart, testDate(2026, 3, 1, 0))
        XCTAssertEqual(points[1].monthsSincePrevious, 1)
    }

    func testCrossYearMissingMonthsRecordsGapWithoutInsertingPoints() {
        let november = snapshot(
            id: uuid(1),
            date: testDate(2025, 11, 30),
            positions: 100
        )
        let february = snapshot(
            id: uuid(2),
            date: testDate(2026, 2, 28),
            positions: 120
        )

        let points = MonthlyProgressCalculator.calculate(
            snapshots: [november, february],
            targetAmount: 500
        )

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[1].monthsSincePrevious, 3)
        XCTAssertEqual(points[1].changeAmount, 20)
    }

    func testCalculatesGrowthDeclineAndNoChange() {
        let points = MonthlyProgressCalculator.calculate(
            snapshots: [
                snapshot(
                    id: uuid(1),
                    date: testDate(2026, 1, 31),
                    positions: 100
                ),
                snapshot(
                    id: uuid(2),
                    date: testDate(2026, 2, 28),
                    positions: 110
                ),
                snapshot(
                    id: uuid(3),
                    date: testDate(2026, 3, 31),
                    positions: 100
                ),
                snapshot(
                    id: uuid(4),
                    date: testDate(2026, 4, 30),
                    positions: 100
                ),
            ],
            targetAmount: 500
        )

        XCTAssertEqual(points[1].changeAmount, 10)
        XCTAssertEqual(points[1].changeRate, Decimal(string: "0.1"))
        XCTAssertEqual(points[1].fireProgress, Decimal(string: "0.22"))
        XCTAssertEqual(
            points[1].fireProgressChange,
            Decimal(string: "0.02")
        )
        XCTAssertEqual(points[2].changeAmount, -10)
        XCTAssertEqual(
            points[2].changeRate,
            Decimal(string: "-0.09090909090909090909090909090909090909")
        )
        XCTAssertEqual(
            points[2].fireProgressChange,
            Decimal(string: "-0.02")
        )
        XCTAssertEqual(points[3].changeAmount, 0)
        XCTAssertEqual(points[3].changeRate, 0)
        XCTAssertEqual(points[3].fireProgressChange, 0)
    }

    func testChangeRateIsNilWhenPreviousNetWorthIsNotPositive() {
        let points = MonthlyProgressCalculator.calculate(
            snapshots: [
                snapshot(
                    id: uuid(1),
                    date: testDate(2026, 1, 31),
                    positions: 50,
                    liabilities: 100
                ),
                snapshot(
                    id: uuid(2),
                    date: testDate(2026, 2, 28),
                    positions: 100
                ),
            ],
            targetAmount: 500
        )

        XCTAssertEqual(points[0].investableNetWorth, -50)
        XCTAssertEqual(points[0].fireProgress, 0)
        XCTAssertEqual(points[1].changeAmount, 150)
        XCTAssertNil(points[1].changeRate)
        XCTAssertEqual(points[1].fireProgressChange, Decimal(string: "0.2"))
    }

    func testNilOrNonPositiveTargetOmitsProgress() {
        let inputs = [
            snapshot(
                id: uuid(1),
                date: testDate(2026, 1, 31),
                positions: 100
            ),
            snapshot(
                id: uuid(2),
                date: testDate(2026, 2, 28),
                positions: 110
            ),
        ]

        for target in [nil, Decimal.zero, Decimal(-1)] as [Decimal?] {
            let points = MonthlyProgressCalculator.calculate(
                snapshots: inputs,
                targetAmount: target
            )

            XCTAssertTrue(points.allSatisfy { $0.fireProgress == nil })
            XCTAssertTrue(points.allSatisfy { $0.fireProgressChange == nil })
            XCTAssertEqual(points[1].changeAmount, 10)
        }
    }

    func testProgressIsClampedToOne() {
        let points = MonthlyProgressCalculator.calculate(
            snapshots: [
                snapshot(
                    id: uuid(1),
                    date: testDate(2026, 1, 31),
                    positions: 400
                ),
                snapshot(
                    id: uuid(2),
                    date: testDate(2026, 2, 28),
                    positions: 600
                ),
            ],
            targetAmount: 500
        )

        XCTAssertEqual(points[0].fireProgress, Decimal(string: "0.8"))
        XCTAssertEqual(points[1].fireProgress, 1)
        XCTAssertEqual(points[1].fireProgressChange, Decimal(string: "0.2"))
    }

    func testMonetaryValuesAreRoundedBeforeCalculatingChanges() {
        let points = MonthlyProgressCalculator.calculate(
            snapshots: [
                snapshot(
                    id: uuid(1),
                    date: testDate(2026, 1, 31),
                    positions: Decimal(string: "100.004")!
                ),
                snapshot(
                    id: uuid(2),
                    date: testDate(2026, 2, 28),
                    positions: Decimal(string: "100.006")!
                ),
            ],
            targetAmount: 500
        )

        XCTAssertEqual(points[0].investableNetWorth, Decimal(string: "100.00"))
        XCTAssertEqual(points[1].investableNetWorth, Decimal(string: "100.01"))
        XCTAssertEqual(points[1].changeAmount, Decimal(string: "0.01"))
        XCTAssertEqual(points[1].changeRate, Decimal(string: "0.0001"))
    }

    private func snapshot(
        id: UUID,
        date: Date,
        positions: Decimal,
        cash: Decimal = 0,
        liabilities: Decimal = 0,
        isComplete: Bool = true
    ) -> MonthlyProgressSnapshot {
        MonthlyProgressSnapshot(
            id: id,
            capturedAt: date,
            positionsCNY: positions,
            cashCNY: cash,
            liabilitiesCNY: liabilities,
            isComplete: isComplete
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                suffix
            )
        )!
    }

    private func utcDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
