import Charts
import FIRECore
import SwiftUI

struct ProgressHistoryView: View {
    private static let shanghaiTimeZone =
        TimeZone(identifier: "Asia/Shanghai")
        ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!

    let points: [MonthlyProgressPoint]
    @Binding var hidesNumbers: Bool

    private var orderedPoints: [MonthlyProgressPoint] {
        points.sorted { $0.monthStart < $1.monthStart }
    }

    private var latestPoint: MonthlyProgressPoint? {
        orderedPoints.last
    }

    private var chartPoints: [MonthlyProgressPoint] {
        Array(
            orderedPoints
                .filter { $0.fireProgress != nil }
                .suffix(12)
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let latestPoint {
                    currentSummary(point: latestPoint)
                    trendCard
                    historyCard
                } else {
                    emptyStateCard
                }

                methodologyCard
            }
            .padding()
        }
        .background(FIREPalette.paper.ignoresSafeArea())
        .navigationTitle("进度历史")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FinancialPrivacyButton(hidesNumbers: $hidesNumbers)
            }
        }
    }

    private func currentSummary(point: MonthlyProgressPoint) -> some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前进度")
                        .font(.headline)
                    Text("截至 \(dateText(point.capturedAt)) 的完整资产快照")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        currentNetWorth(point)
                        currentFIREProgress(point)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        currentNetWorth(point)
                        currentFIREProgress(point)
                    }
                }
            }
        }
    }

    private func currentNetWorth(_ point: MonthlyProgressPoint) -> some View {
        privacyMetric(
            title: "可投资净资产",
            visibleValue: point.investableNetWorth.cnyText,
            accessibilityValue: point.investableNetWorth.cnyText
        )
    }

    private func currentFIREProgress(_ point: MonthlyProgressPoint) -> some View {
        privacyMetric(
            title: "FIRE 进度",
            visibleValue: point.fireProgress?.percentText
                ?? "待完成支出规划",
            accessibilityValue: point.fireProgress?.percentText
                ?? "待完成支出规划"
        )
    }

    private func privacyMetric(
        title: String,
        visibleValue: String,
        accessibilityValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(hidesNumbers ? FinancialPrivacyFormatter.hiddenValue : visibleValue)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            hidesNumbers ? "财务数字已隐藏" : accessibilityValue
        )
    }

    private var trendCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FIRE 进度趋势")
                        .font(.headline)
                    Text("最近 12 个有效月份")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if hidesNumbers {
                    hiddenChartPlaceholder
                } else if chartPoints.count >= 2 {
                    progressChart
                } else if chartPoints.isEmpty {
                    EmptyState(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "待完成支出规划",
                        message: "设定年度支出与提取率后，这里会显示 FIRE 进度趋势。"
                    )
                } else {
                    EmptyState(
                        icon: "calendar.badge.plus",
                        title: "还需要下一个月",
                        message: "下月继续保存完整资产快照，即可开始追踪变化。"
                    )
                }
            }
        }
    }

    private var hiddenChartPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 28))
                .foregroundStyle(FIREPalette.moss)
            Text("数字已隐藏")
                .font(.headline)
            Text("显示数字后查看趋势图")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("数字已隐藏，显示数字后查看趋势图")
    }

    private var progressChart: some View {
        Chart(chartPoints, id: \.snapshotID) { point in
            if let progress = point.fireProgress {
                LineMark(
                    x: .value("月份", point.monthStart),
                    y: .value("FIRE 进度", progress.doubleValue),
                    series: .value("连续月份区段", chartSegmentID(for: point))
                )
                .interpolationMethod(.linear)
                .foregroundStyle(FIREPalette.moss)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))

                PointMark(
                    x: .value("月份", point.monthStart),
                    y: .value("FIRE 进度", progress.doubleValue)
                )
                .foregroundStyle(FIREPalette.moss)
                .symbolSize(46)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(FIREPalette.separator.opacity(0.45))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(shortMonthText(date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                    .foregroundStyle(FIREPalette.separator.opacity(0.45))
                AxisValueLabel {
                    if let progress = value.as(Double.self) {
                        Text(progress.percentText)
                    }
                }
            }
        }
        .frame(minHeight: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("FIRE 进度趋势")
        .accessibilityValue(chartAccessibilityValue)
    }

    private var chartAccessibilityValue: String {
        chartPoints.map { point in
            let month = monthText(point.monthStart)
            let progress = point.fireProgress?.percentText ?? "未知"
            return "\(month) \(progress)"
        }
        .joined(separator: "，")
    }

    private var historyCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 0) {
                Text("逐月记录")
                    .font(.headline)
                    .padding(.bottom, 14)

                ForEach(Array(orderedPoints.reversed()), id: \.snapshotID) { point in
                    historyRow(point)

                    if point.snapshotID != orderedPoints.first?.snapshotID {
                        Divider()
                            .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    private func historyRow(_ point: MonthlyProgressPoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(monthText(point.monthStart))
                    .font(.headline)
                Spacer()
                Text(changeContext(point))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if hidesNumbers {
                HStack {
                    hiddenRowMetric(title: "可投资净资产")
                    Spacer()
                    hiddenRowMetric(title: "FIRE 进度")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("财务数字已隐藏")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        netWorthHistoryMetric(point)
                        Spacer(minLength: 8)
                        fireProgressHistoryMetric(point)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        netWorthHistoryMetric(point)
                        fireProgressHistoryMetric(point)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func hiddenRowMetric(title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(FinancialPrivacyFormatter.hiddenValue)
                .font(.system(.body, design: .rounded, weight: .semibold))
        }
    }

    private func netWorthHistoryMetric(_ point: MonthlyProgressPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("可投资净资产")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(point.investableNetWorth.cnyText)
                .font(.system(.body, design: .rounded, weight: .semibold))
            if let change = point.changeAmount {
                Text(netWorthChangeText(point))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(changeColor(change))
            } else {
                Text("起始记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fireProgressHistoryMetric(_ point: MonthlyProgressPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FIRE 进度")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(point.fireProgress?.percentText ?? "待完成支出规划")
                .font(.system(.body, design: .rounded, weight: .semibold))
            if point.fireProgress == nil {
                Text("当前目标无效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let change = point.fireProgressChange {
                Text(change.signedPercentagePointText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(changeColor(change))
            } else {
                Text("起始记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func netWorthChangeText(_ point: MonthlyProgressPoint) -> String {
        guard let amount = point.changeAmount else { return "起始记录" }
        if amount == 0 {
            guard let rate = point.changeRate else {
                return "持平 · \(amount.signedCNYText) · 比例不可计算"
            }
            return "持平 · \(amount.signedCNYText) · \(rate.signedPercentText)"
        }
        let amountText = amount.signedCNYText
        guard let rate = point.changeRate else {
            return "\(amountText) · 比例不可计算"
        }
        return "\(amountText) · \(rate.signedPercentText)"
    }

    private func changeContext(_ point: MonthlyProgressPoint) -> String {
        guard point.changeAmount != nil else { return "起始记录" }
        guard let monthGap = point.monthsSincePrevious, monthGap > 1 else {
            return "较上月"
        }
        return "较上次快照（间隔 \(monthGap) 个月）"
    }

    private func chartSegmentID(for point: MonthlyProgressPoint) -> Int {
        var segmentID = 0
        for chartPoint in chartPoints {
            if let monthGap = chartPoint.monthsSincePrevious, monthGap > 1 {
                segmentID += 1
            }
            if chartPoint.snapshotID == point.snapshotID {
                return segmentID
            }
        }
        return segmentID
    }

    private func dateText(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.year().month().day()
        style.timeZone = Self.shanghaiTimeZone
        return date.formatted(style)
    }

    private func monthText(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.year().month()
        style.timeZone = Self.shanghaiTimeZone
        return date.formatted(style)
    }

    private func shortMonthText(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime
            .year(.twoDigits)
            .month(.twoDigits)
        style.timeZone = Self.shanghaiTimeZone
        return date.formatted(style)
    }

    private func changeColor(_ change: Decimal) -> Color {
        if change > 0 { return FIREPalette.moss }
        if change < 0 { return FIREPalette.clay }
        return .secondary
    }

    private var emptyStateCard: some View {
        FIRECard {
            EmptyState(
                icon: "square.stack.3d.up.badge.a",
                title: "还没有完整资产快照",
                message: "请从下方“资产”页填写并保存快照，之后即可逐月追踪进度。"
            )
        }
    }

    private var methodologyCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 8) {
                Label("统计口径", systemImage: "info.circle")
                    .font(.headline)
                Text("历史进度按当前目标重算。")
                    .font(.subheadline.weight(.semibold))
                Text("“净资产变化”同时可能包含新增投入、取出、市场波动、汇率和负债变化，不等同于投资收益。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension Decimal {
    var cnyText: String {
        doubleValue.cnyText
    }

    var percentText: String {
        doubleValue.percentText
    }

    var signedCNYText: String {
        let sign = self > 0 ? "+" : self < 0 ? "−" : ""
        return sign + abs(doubleValue).cnyText
    }

    var signedPercentText: String {
        let sign = self > 0 ? "+" : self < 0 ? "−" : ""
        return sign + abs(doubleValue).percentText
    }

    var signedPercentagePointText: String {
        let sign = self > 0 ? "+" : self < 0 ? "−" : ""
        let value = abs(doubleValue * 100).formatted(
            .number.precision(.fractionLength(1))
        )
        if self == 0 {
            return "持平 · \(value) 个百分点"
        }
        return "\(sign)\(value) 个百分点"
    }
}
