import FIRECore
import SwiftUI

struct DashboardView: View {
    private static let shanghaiTimeZone =
        TimeZone(identifier: "Asia/Shanghai")
        ?? TimeZone(secondsFromGMT: 8 * 60 * 60)!

    private enum PlanningField: Hashable {
        case monthlyIncome
        case annualIncome
        case monthlyExpense
        case annualIrregularExpense
    }

    @Environment(FIREAppState.self) private var appState
    @Binding var hidesNumbers: Bool
    let onOpenAssets: () -> Void
    @State private var monthlyIncomeDraft = "0"
    @State private var annualIncomeDraft = "0"
    @State private var monthlyExpenseDraft = "0"
    @State private var annualIrregularExpenseDraft = "0"
    @State private var incomeDraftChanged = false
    @State private var expenseDraftChanged = false
    @FocusState private var focusedPlanningField: PlanningField?

    private var state: DashboardSnapshot { appState.dashboard }
    private var rate: Double { state.assumptions.withdrawalRate }
    private var progress: Double { state.progress(withdrawalRate: rate) }
    private var privacyFormatter: FinancialPrivacyFormatter {
        FinancialPrivacyFormatter(hidesNumbers: hidesNumbers)
    }

    init(
        hidesNumbers: Binding<Bool>,
        onOpenAssets: @escaping () -> Void = {}
    ) {
        self._hidesNumbers = hidesNumbers
        self.onOpenAssets = onOpenAssets
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                monthlyProgressCard
                distanceCard
                expensePlanCard
                incomePlanCard
                confidenceCard
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FIREPalette.paper.ignoresSafeArea())
        .navigationTitle("自由进度")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                FinancialPrivacyButton(hidesNumbers: $hidesNumbers)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    focusedPlanningField = nil
                }
            }
        }
        .onAppear {
            syncAmountDrafts()
        }
        .onChange(of: state.monthlyIncome) { _, _ in
            syncIncomeDraftsIfNeeded()
        }
        .onChange(of: state.annualIncome) { _, _ in
            syncIncomeDraftsIfNeeded()
        }
        .onChange(of: state.monthlyExpense) { _, _ in
            syncExpenseDraftsIfNeeded()
        }
        .onChange(of: state.annualIrregularExpense) { _, _ in
            syncExpenseDraftsIfNeeded()
        }
        .onChange(of: hidesNumbers) { _, isHidden in
            if isHidden {
                focusedPlanningField = nil
            }
        }
    }

    private var hero: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("距离财务自由")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(privacyFormatter.value(progress.percentText))
                            .font(.system(size: 52, weight: .bold, design: .serif))
                            .minimumScaleFactor(0.7)
                    }
                    Spacer()
                    ZStack {
                        Circle()
                            .stroke(FIREPalette.ink.opacity(0.10), lineWidth: 10)
                        Circle()
                            .trim(from: 0, to: privacyFormatter.progress(progress))
                            .stroke(
                                FIREPalette.moss,
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Image(
                            systemName: hidesNumbers
                                ? "eye.slash.fill"
                                : (progress >= 1 ? "flag.fill" : "figure.walk")
                        )
                            .foregroundStyle(FIREPalette.ink)
                    }
                    .frame(width: 82, height: 82)
                    .animation(.snappy, value: privacyFormatter.progress(progress))
                }

                HStack(spacing: 0) {
                    MetricLabel(
                        title: "可投资净资产",
                        value: privacyFormatter.value(state.investableNetWorth.cnyText),
                        detail: "基金 + 股票 + 期权 + 现金 − 负债"
                    )
                    Spacer()
                    MetricLabel(
                        title: "FIRE 目标",
                        value: privacyFormatter.value(
                            state.target(withdrawalRate: rate).cnyText
                        ),
                        detail: "根据规划年度支出与设置中的提取率"
                    )
                }
            }
        }
    }

    private var distanceCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 14) {
                Text("还有多远")
                    .font(.headline)
                HStack {
                    MetricLabel(
                        title: "还差",
                        value: privacyFormatter.value(
                            state.remaining(withdrawalRate: rate).cnyText
                        )
                    )
                    Spacer()
                    MetricLabel(
                        title: "预计达到",
                        value: privacyFormatter.value(estimatedDateText),
                        detail: contributionPlanDetail
                    )
                }
                Divider()
                Text(
                    privacyFormatter.value(
                        "规划年支出 \(state.annualExpense.cnyText) · "
                            + "预期收益 \(state.assumptions.expectedReturn.percentText) · "
                            + "通胀 \(state.assumptions.inflation.percentText)"
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var monthlyProgressCard: some View {
        if monthlyProgressPoints.isEmpty {
            FIRECard {
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        "月度进展",
                        systemImage: "chart.line.uptrend.xyaxis"
                    )
                    .font(.headline)

                    Text("还没有进度记录")
                        .font(.title3.weight(.semibold))
                    Text("保存一次完整资产快照后，这里会开始记录每月变化。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button(action: onOpenAssets) {
                        Text("去资产页填写")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        } else {
            NavigationLink {
                ProgressHistoryView(
                    points: monthlyProgressPoints,
                    hidesNumbers: $hidesNumbers
                )
            } label: {
                FIRECard {
                    monthlyProgressCardContent
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(monthlyProgressAccessibilityLabel)
            .accessibilityHint("查看进度历史")
        }
    }

    @ViewBuilder
    private var monthlyProgressCardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(
                    "月度进展",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
                .font(.headline)
                Spacer(minLength: 6)
                Text("查看历史")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FIREPalette.moss)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            if let latest = monthlyProgressPoints.last {
                Text(monthText(latest.monthStart))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if monthlyProgressPoints.count == 1 {
                    MetricLabel(
                        title: "当前净资产",
                        value: privacyFormatter.value(
                            latest.investableNetWorth.doubleValue.cnyText
                        )
                    )
                    Text("再完成下个月快照，就能看到月变化。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    latestMonthlyChange(latest)
                }
            }
        }
    }

    private func latestMonthlyChange(
        _ latest: MonthlyProgressPoint
    ) -> some View {
        let amountText = privacyFormatter.value(
            latest.changeAmount.map(signedCNY) ?? "暂无对比"
        )
        let rateText = privacyFormatter.value(
            latest.changeRate.map(signedPercent) ?? "无法计算比例"
        )

        return VStack(alignment: .leading, spacing: 12) {
            Text("净资产变化")
                .font(.caption)
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    monthlyChangeAmountLabel(
                        amountText,
                        change: latest.changeAmount
                    )
                    .fixedSize(horizontal: true, vertical: false)

                    monthlyChangeRateLabel(
                        rateText,
                        change: latest.changeRate
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: 4) {
                    monthlyChangeAmountLabel(
                        amountText,
                        change: latest.changeAmount
                    )
                    monthlyChangeRateLabel(
                        rateText,
                        change: latest.changeRate
                    )
                }
            }

            if let gap = latest.monthsSincePrevious {
                Text(
                    gap > 1
                        ? "较上次快照（间隔 \(gap) 个月）"
                        : "较上月完整快照"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("FIRE 进度变化")
                        .font(.subheadline)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 10)
                    fireProgressChangeLabel(latest)
                        .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("FIRE 进度变化")
                        .font(.subheadline)
                    fireProgressChangeLabel(latest)
                }
            }
        }
    }

    private func monthlyChangeAmountLabel(
        _ text: String,
        change: Decimal?
    ) -> some View {
        Text(text)
            .font(.system(.title2, design: .rounded, weight: .bold))
            .foregroundStyle(visibleChangeColor(change))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func monthlyChangeRateLabel(
        _ text: String,
        change: Decimal?
    ) -> some View {
        Text(text)
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(visibleChangeColor(change))
    }

    @ViewBuilder
    private func fireProgressChangeLabel(
        _ latest: MonthlyProgressPoint
    ) -> some View {
        if let change = latest.fireProgressChange {
            Text(privacyFormatter.value(signedPercentagePoints(change)))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(visibleChangeColor(change))
        } else {
            Text("待完成支出规划")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var monthlyProgressPoints: [MonthlyProgressPoint] {
        state.monthlyProgress.sorted { lhs, rhs in
            if lhs.monthStart == rhs.monthStart {
                return lhs.capturedAt < rhs.capturedAt
            }
            return lhs.monthStart < rhs.monthStart
        }
    }

    private func monthText(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime
            .year()
            .month()
            .locale(Locale(identifier: "zh_CN"))
        style.timeZone = Self.shanghaiTimeZone
        return date.formatted(style)
    }

    private func signedCNY(_ value: Decimal) -> String {
        signedText(value) { absoluteValue in
            absoluteValue.cnyText
        }
    }

    private func signedPercent(_ value: Decimal) -> String {
        signedText(value) { absoluteValue in
            absoluteValue.percentText
        }
    }

    private func signedPercentagePoints(_ value: Decimal) -> String {
        signedText(value) { absoluteValue in
            let points = absoluteValue * 100
            return points.formatted(
                .number.precision(.fractionLength(1))
            ) + " 个百分点"
        }
    }

    private func signedText(
        _ value: Decimal,
        formatter: (Double) -> String
    ) -> String {
        let doubleValue = value.doubleValue
        if doubleValue > 0 {
            return "+" + formatter(doubleValue)
        }
        if doubleValue < 0 {
            return "−" + formatter(abs(doubleValue))
        }
        return formatter(0) + "（持平）"
    }

    private func changeColor(_ value: Decimal?) -> Color {
        guard let value else { return .secondary }
        if value > 0 { return FIREPalette.moss }
        if value < 0 { return FIREPalette.clay }
        return .secondary
    }

    private func visibleChangeColor(_ value: Decimal?) -> Color {
        hidesNumbers ? .secondary : changeColor(value)
    }

    private var monthlyProgressAccessibilityLabel: String {
        guard !hidesNumbers else {
            return "月度进展，财务数字已隐藏"
        }
        guard let latest = monthlyProgressPoints.last else {
            return "月度进展，还没有进展记录"
        }
        if monthlyProgressPoints.count == 1 {
            return "月度进展，\(monthText(latest.monthStart))，当前净资产"
                + latest.investableNetWorth.doubleValue.cnyText
                + "，再完成下个月快照后可查看变化"
        }

        let amount = latest.changeAmount.map(signedCNY) ?? "暂无对比"
        let rate = latest.changeRate.map(signedPercent) ?? "暂无比例"
        let progressChange = latest.fireProgressChange
            .map(signedPercentagePoints) ?? "待完成支出规划"
        return "月度进展，\(monthText(latest.monthStart))，净资产变化"
            + amount + "，" + rate + "，FIRE 进度变化" + progressChange
    }

    private var incomePlanCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 14) {
                planningHeader(
                    title: "规划收入",
                    systemImage: "banknote.fill",
                    status: incomePlanStatus,
                    isManual: state.confirmedContribution
                        || state.annualBonusContributionConfirmed
                )
                Text("填写税后、可用于生活和投资的收入。账本数据只提供参考，保存后才进入预计日期。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                planningAmountInput(
                    title: "月度收入（税后）",
                    detail: "工资及其他每月稳定收入",
                    text: $monthlyIncomeDraft,
                    field: .monthlyIncome
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text("账本月度收入参考")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if state.monthlyIncomeReference.monthsUsed > 0,
                       let median = state.monthlyIncomeReference.median {
                        referenceRow(
                            title: "稳定收入月度中位数",
                            value: privacyFormatter.value(median.cnyText)
                        )
                        if let latest = state.monthlyIncomeReference.latest {
                            referenceRow(
                                title: "最近完整月",
                                value: privacyFormatter.value(latest.cnyText)
                            )
                        }
                        if let minimum = state.monthlyIncomeReference.minimum,
                           let maximum = state.monthlyIncomeReference.maximum {
                            Text(
                                privacyFormatter.value(
                                    "近 \(state.monthlyIncomeReference.monthsUsed) "
                                        + "个月区间：\(minimum.cnyText) ～ "
                                        + maximum.cnyText
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("完整账单月份不足，暂时没有稳定月收入参考。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                planningAmountInput(
                    title: "年度奖金收入（税后）",
                    detail: "年终奖、绩效奖金等，每年计入一次",
                    text: $annualIncomeDraft,
                    field: .annualIncome
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text("账本年度收入参考")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let latestYear = state.annualBonusReference.latestYear,
                       let latestTotal =
                           state.annualBonusReference.latestYearTotal {
                        referenceRow(
                            title: privacyFormatter.value(
                                "\(latestYear) 年已记录奖金"
                            ),
                            value: privacyFormatter.value(latestTotal.cnyText)
                        )
                    }
                    if let annualMedian =
                        state.annualBonusReference.annualMedian {
                        referenceRow(
                            title: "有记录年度中位数",
                            value: privacyFormatter.value(
                                annualMedian.cnyText
                            )
                        )
                    }
                    if state.annualBonusReference.transactionCount == 0 {
                        Text("账本暂未识别到年终奖或绩效奖金。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(
                            privacyFormatter.value(
                                "共 \(state.annualBonusReference.transactionCount) "
                                    + "笔，覆盖 "
                                    + "\(state.annualBonusReference.yearsUsed) "
                                    + "个有记录年度。"
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                planningSummary(
                    title: "按当前填写每年可投入",
                    value: draftAnnualContribution.map {
                        privacyFormatter.value($0.cnyText)
                    } ?? "请检查填写金额",
                    detail: "（月度收入 − 月度支出）× 12 + 年度奖金收入 − 年度不规则支出"
                        + (expenseDraftChanged ? "；含未保存的支出修改" : "")
                )

                Button {
                    saveIncomePlan()
                } label: {
                    Text("保存收入规划")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(incomeSaveDisabled || hidesNumbers)
                .opacity(incomeSaveDisabled || hidesNumbers ? 0.45 : 1)

                if state.confirmedContribution
                    || state.annualBonusContributionConfirmed {
                    Button("清除手动收入规划") {
                        clearIncomePlan()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FIREPalette.moss)
                    .disabled(hidesNumbers)
                    .opacity(hidesNumbers ? 0.45 : 1)
                }

                Text("投资卖出、转账、退款和借款不计为收入。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var expensePlanCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 14) {
                planningHeader(
                    title: "规划支出",
                    systemImage: "cart.fill",
                    status: state.hasManualExpensePlan
                        ? "已规划"
                        : "随账本更新",
                    isManual: state.hasManualExpensePlan
                )
                Text("月度日常支出年化后，再加旅行等年度不规则支出，共同决定 FIRE 目标。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                planningAmountInput(
                    title: "月度日常支出",
                    detail: "餐饮、住房、交通等稳定生活支出",
                    text: $monthlyExpenseDraft,
                    field: .monthlyExpense
                )
                VStack(alignment: .leading, spacing: 7) {
                    Text("账本月度支出参考")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if state.observedMonths > 0 {
                        referenceRow(
                            title: "日常支出月度中位数",
                            value: privacyFormatter.value(
                                (state.recurringAnnualizedExpense / 12)
                                    .cnyText
                            )
                        )
                    } else {
                        Text("完整账单月份不足，暂时没有月度日常支出参考。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                planningAmountInput(
                    title: "年度不规则支出",
                    detail: "旅行、医疗、保险、人情及大额非住房支出",
                    text: $annualIrregularExpenseDraft,
                    field: .annualIrregularExpense
                )
                VStack(alignment: .leading, spacing: 7) {
                    Text("账本年度支出参考")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    referenceRow(
                        title: state.observedMonths >= 12
                            ? "近 12 个月不规则支出"
                            : "目前已观察不规则支出",
                        value: privacyFormatter.value(
                            state.irregularAnnualExpense.cnyText
                        )
                    )
                    Text(
                        state.observedMonths >= 12
                            ? "已具备至少 12 个完整月，采用滚动 12 个月实际值。"
                            : "不足 12 个完整月，当前金额可能尚未覆盖完整年度。"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                planningSummary(
                    title: "按当前填写年度总支出",
                    value: draftAnnualExpense.map {
                        privacyFormatter.value($0.cnyText)
                    } ?? "请检查填写金额",
                    detail: "月度日常支出 × 12 + 年度不规则支出"
                )

                Button {
                    saveExpensePlan()
                } label: {
                    Text("保存支出规划")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(expenseSaveDisabled || hidesNumbers)
                .opacity(expenseSaveDisabled || hidesNumbers ? 0.45 : 1)

                if state.hasManualExpensePlan {
                    Button("恢复按账本更新") {
                        clearExpensePlan()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FIREPalette.moss)
                    .disabled(hidesNumbers)
                    .opacity(hidesNumbers ? 0.45 : 1)
                }

                Text("退款已冲减；投资交易、转账、重复流水和贷款本金已排除。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var confidenceCard: some View {
        FIRECard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.title2)
                    .foregroundStyle(FIREPalette.amber)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("数据可信度").font(.headline)
                        Spacer()
                        Text(
                            privacyFormatter.value(
                                "\(state.observedMonths) 个完整月"
                            )
                        )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(privacyFormatter.value(state.confidence.explanation))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func planningHeader(
        title: String,
        systemImage: String,
        status: String,
        isManual: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isManual ? FIREPalette.moss : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    isManual
                        ? FIREPalette.moss.opacity(0.14)
                        : Color(uiColor: .tertiarySystemFill),
                    in: Capsule()
                )
                .fixedSize()
        }
    }

    private func planningAmountInput(
        title: String,
        detail: String,
        text: Binding<String>,
        field: PlanningField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if hidesNumbers {
                HStack {
                    Text(FinancialPrivacyFormatter.hiddenValue)
                        .font(.title2.bold())
                    Spacer()
                    Text("显示数字后可修改")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            } else {
                HStack(spacing: 10) {
                    Text("¥")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("0", text: text)
                        .keyboardType(.decimalPad)
                        .focused($focusedPlanningField, equals: field)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .onChange(of: text.wrappedValue) { _, _ in
                            guard focusedPlanningField == field else {
                                return
                            }
                            markDraftChanged(for: field)
                        }
                        .accessibilityLabel(title)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            FIREPalette.separator.opacity(0.7),
                            lineWidth: 1
                        )
                }
            }
        }
    }

    private func referenceRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func planningSummary(
        title: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            referenceRow(title: title, value: value)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            FIREPalette.moss.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    private var incomeSaveDisabled: Bool {
        guard draftAnnualIncome != nil else {
            return true
        }
        return !incomeDraftChanged
            && state.confirmedContribution
            && state.annualBonusContributionConfirmed
    }

    private var incomePlanStatus: String {
        switch (
            state.confirmedContribution,
            state.annualBonusContributionConfirmed
        ) {
        case (true, true):
            return "已规划"
        case (true, false), (false, true):
            return "部分已规划"
        case (false, false):
            return "待填写"
        }
    }

    private var expenseSaveDisabled: Bool {
        guard let draftAnnualExpense,
              draftAnnualExpense > 0 else {
            return true
        }
        return !expenseDraftChanged && state.hasManualExpensePlan
    }

    private var draftAnnualIncome: Double? {
        annualizedTotal(
            monthlyText: monthlyIncomeDraft,
            annualText: annualIncomeDraft
        )
    }

    private var draftAnnualExpense: Double? {
        annualizedTotal(
            monthlyText: monthlyExpenseDraft,
            annualText: annualIrregularExpenseDraft
        )
    }

    private var draftAnnualContribution: Double? {
        guard let draftAnnualIncome,
              let draftAnnualExpense else {
            return nil
        }
        let contribution = draftAnnualIncome - draftAnnualExpense
        return contribution.isFinite ? contribution : nil
    }

    private var contributionPlanDetail: String {
        switch (
            state.confirmedContribution,
            state.annualBonusContributionConfirmed
        ) {
        case (true, true):
            return "按月度与年度收入减支出"
        case (true, false):
            return "月度规划已保存；年度待补全"
        case (false, true):
            return "年度规划已保存；月度待补全"
        case (false, false):
            return "待保存收入规划"
        }
    }

    private func syncAmountDrafts() {
        syncIncomeDraftsIfNeeded()
        syncExpenseDraftsIfNeeded()
    }

    private func syncIncomeDraftsIfNeeded() {
        guard !incomeDraftChanged,
              focusedPlanningField != .monthlyIncome,
              focusedPlanningField != .annualIncome else {
            return
        }
        monthlyIncomeDraft = editableAmountText(state.monthlyIncome)
        annualIncomeDraft = editableAmountText(state.annualIncome)
    }

    private func syncExpenseDraftsIfNeeded() {
        guard !expenseDraftChanged,
              focusedPlanningField != .monthlyExpense,
              focusedPlanningField != .annualIrregularExpense else {
            return
        }
        monthlyExpenseDraft = editableAmountText(state.monthlyExpense)
        annualIrregularExpenseDraft = editableAmountText(
            state.annualIrregularExpense
        )
    }

    private func markDraftChanged(for field: PlanningField) {
        switch field {
        case .monthlyIncome, .annualIncome:
            incomeDraftChanged = true
        case .monthlyExpense, .annualIrregularExpense:
            expenseDraftChanged = true
        }
    }

    private func saveIncomePlan() {
        guard let monthlyIncome = parsedAmount(monthlyIncomeDraft),
              let annualIncome = parsedAmount(annualIncomeDraft),
              appState.saveIncomePlan(
                  monthlyIncome: monthlyIncome,
                  annualIncome: annualIncome
              ) else {
            return
        }
        incomeDraftChanged = false
        focusedPlanningField = nil
    }

    private func clearIncomePlan() {
        guard appState.clearIncomePlan() else {
            return
        }
        monthlyIncomeDraft = editableAmountText(
            state.monthlyIncomeReference.median ?? 0
        )
        annualIncomeDraft = editableAmountText(
            state.annualBonusReference.annualMedian
                ?? state.annualBonusReference.latestYearTotal
                ?? 0
        )
        incomeDraftChanged = false
        focusedPlanningField = nil
    }

    private func saveExpensePlan() {
        guard let monthlyExpense = parsedAmount(monthlyExpenseDraft),
              let annualExpense =
                  parsedAmount(annualIrregularExpenseDraft),
              appState.saveExpensePlan(
                  monthlyExpense: monthlyExpense,
                  annualIrregularExpense: annualExpense
              ) else {
            return
        }
        expenseDraftChanged = false
        focusedPlanningField = nil
    }

    private func clearExpensePlan() {
        guard appState.clearExpensePlan() else {
            return
        }
        monthlyExpenseDraft = editableAmountText(
            state.recurringAnnualizedExpense / 12
        )
        annualIrregularExpenseDraft = editableAmountText(
            state.irregularAnnualExpense
        )
        expenseDraftChanged = false
        focusedPlanningField = nil
    }

    private func parsedAmount(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        guard let amount = Double(normalized),
              PlanAmountValue.decimal(from: amount) != nil else {
            return nil
        }
        return amount
    }

    private func annualizedTotal(
        monthlyText: String,
        annualText: String
    ) -> Double? {
        guard let monthly = parsedAmount(monthlyText),
              let annual = parsedAmount(annualText),
              let monthlyDecimal = PlanAmountValue.decimal(from: monthly),
              let annualDecimal = PlanAmountValue.decimal(from: annual),
              let total = PlanAmountValue.annualExpenseTotal(
                  monthlyExpense: monthlyDecimal,
                  annualIrregularExpense: annualDecimal
              ) else {
            return nil
        }
        let value = NSDecimalNumber(decimal: total).doubleValue
        return value.isFinite ? value : nil
    }

    private func editableAmountText(_ value: Double) -> String {
        value.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...2))
        )
    }

    private var estimatedDateText: String {
        guard let date = state.estimatedDate(withdrawalRate: rate) else {
            return state.confirmedContribution
                    || state.annualBonusContributionConfirmed
                ? "暂不可达"
                : "待填写"
        }
        return date.formatted(.dateTime.year().month())
    }
}
