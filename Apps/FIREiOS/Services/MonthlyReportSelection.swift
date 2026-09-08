import Foundation

enum MonthlyReportSelection {
    static func availableMonths(
        from transactions: [TransactionEntity]
    ) -> [Date] {
        let months = transactions.compactMap {
            calendar.dateInterval(of: .month, for: $0.transactionDate)?.start
        }
        return Array(Set(months)).sorted(by: >)
    }

    static func reportDate(
        from transactions: [TransactionEntity]
    ) -> Date? {
        availableMonths(from: transactions).first
    }

    static func assetSnapshot(
        for reportDate: Date,
        from snapshots: [AssetSnapshotEntity]
    ) -> AssetSnapshotEntity? {
        let completeSnapshots = snapshots.filter(\.isComplete)
        guard let month = monthInterval(containing: reportDate) else {
            return completeSnapshots.max {
                $0.capturedAt < $1.capturedAt
            }
        }

        let snapshotsThroughReportMonth = completeSnapshots
            .filter { $0.capturedAt < month.end }
        if let latestThroughReportMonth = snapshotsThroughReportMonth
            .max(by: { $0.capturedAt < $1.capturedAt })
        {
            return latestThroughReportMonth
        }

        let snapshotsAfterReportMonth = completeSnapshots
            .filter { $0.capturedAt >= month.end }
        return snapshotsAfterReportMonth
            .min(by: { $0.capturedAt < $1.capturedAt })
    }

    static func isSameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }

    static func monthLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy 年 M 月"
        return formatter.string(from: date)
    }

    private static func monthInterval(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .month, for: date)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
}
