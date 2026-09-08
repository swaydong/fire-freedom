import Foundation

public struct MonthlyProgressSnapshot: Equatable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var positionsCNY: Decimal
    public var cashCNY: Decimal
    public var liabilitiesCNY: Decimal
    public var isComplete: Bool

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        positionsCNY: Decimal,
        cashCNY: Decimal,
        liabilitiesCNY: Decimal,
        isComplete: Bool
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.positionsCNY = positionsCNY
        self.cashCNY = cashCNY
        self.liabilitiesCNY = liabilitiesCNY
        self.isComplete = isComplete
    }
}

public struct MonthlyProgressPoint: Equatable, Sendable {
    public var snapshotID: UUID
    public var monthStart: Date
    public var capturedAt: Date
    public var investableNetWorth: Decimal
    public var changeAmount: Decimal?
    public var changeRate: Decimal?
    public var fireProgress: Decimal?
    public var fireProgressChange: Decimal?
    public var monthsSincePrevious: Int?

    public init(
        snapshotID: UUID,
        monthStart: Date,
        capturedAt: Date,
        investableNetWorth: Decimal,
        changeAmount: Decimal?,
        changeRate: Decimal?,
        fireProgress: Decimal?,
        fireProgressChange: Decimal?,
        monthsSincePrevious: Int?
    ) {
        self.snapshotID = snapshotID
        self.monthStart = monthStart
        self.capturedAt = capturedAt
        self.investableNetWorth = investableNetWorth
        self.changeAmount = changeAmount
        self.changeRate = changeRate
        self.fireProgress = fireProgress
        self.fireProgressChange = fireProgressChange
        self.monthsSincePrevious = monthsSincePrevious
    }
}

public enum MonthlyProgressCalculator {
    public static func calculate(
        snapshots: [MonthlyProgressSnapshot],
        targetAmount: Decimal?
    ) -> [MonthlyProgressPoint] {
        let calendar = shanghaiCalendar
        let snapshotsByMonth = snapshots
            .filter(\.isComplete)
            .reduce(into: [Date: MonthlyProgressSnapshot]()) { result, snapshot in
                let monthStart = calendar.dateInterval(
                    of: .month,
                    for: snapshot.capturedAt
                )!.start

                guard let current = result[monthStart] else {
                    result[monthStart] = snapshot
                    return
                }

                if snapshot.capturedAt > current.capturedAt
                    || (snapshot.capturedAt == current.capturedAt
                        && snapshot.id.uuidString > current.id.uuidString)
                {
                    result[monthStart] = snapshot
                }
            }
            .sorted { $0.key < $1.key }

        let validTarget = targetAmount.flatMap { $0 > 0 ? $0 : nil }
        var previousPoint: MonthlyProgressPoint?

        return snapshotsByMonth.map { monthStart, snapshot in
            let netWorth = (snapshot.positionsCNY
                + snapshot.cashCNY
                - snapshot.liabilitiesCNY).rounded(scale: 2)
            let progress = validTarget.map {
                min(Decimal(1), max(Decimal.zero, netWorth / $0))
            }
            let changeAmount = previousPoint.map {
                (netWorth - $0.investableNetWorth).rounded(scale: 2)
            }
            let changeRate = previousPoint.flatMap { previous -> Decimal? in
                guard previous.investableNetWorth > 0 else { return nil }
                return (netWorth - previous.investableNetWorth)
                    / previous.investableNetWorth
            }
            let progressChange = progress.flatMap { progress in
                previousPoint?.fireProgress.map { progress - $0 }
            }
            let monthsSincePrevious = previousPoint.flatMap {
                calendar.dateComponents(
                    [.month],
                    from: $0.monthStart,
                    to: monthStart
                ).month
            }

            let point = MonthlyProgressPoint(
                snapshotID: snapshot.id,
                monthStart: monthStart,
                capturedAt: snapshot.capturedAt,
                investableNetWorth: netWorth,
                changeAmount: changeAmount,
                changeRate: changeRate,
                fireProgress: progress,
                fireProgressChange: progressChange,
                monthsSincePrevious: monthsSincePrevious
            )
            previousPoint = point
            return point
        }
    }

    private static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
}
