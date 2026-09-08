import FIRECore
import SwiftData
import SwiftUI

struct ReportsView: View {
    @Environment(FIREAppState.self) private var appState
    @Query(sort: \AnalysisReportEntity.createdAt, order: .reverse)
    private var reports: [AnalysisReportEntity]
    @Query(sort: \AnalysisAnswerEntity.createdAt)
    private var answers: [AnalysisAnswerEntity]

    let transactions: [TransactionEntity]
    let assetSnapshots: [AssetSnapshotEntity]
    let positions: [PositionSnapshotEntity]
    let instruments: [InstrumentEntity]
    let liabilities: [LiabilityEntity]
    let settings: [FIRESettingsEntity]
    let onOpenBridge: () -> Void
    @State private var selectedReportDate: Date? = nil

    private var availableReportMonths: [Date] {
        MonthlyReportSelection.availableMonths(from: transactions)
    }

    private var reportDate: Date? {
        if let selectedReportDate,
           availableReportMonths.contains(where: {
               MonthlyReportSelection.isSameMonth($0, selectedReportDate)
           })
        {
            return selectedReportDate
        }
        return availableReportMonths.first
    }

    private var reportAssetSnapshot: AssetSnapshotEntity? {
        guard let reportDate else { return nil }
        return MonthlyReportSelection.assetSnapshot(
            for: reportDate,
            from: assetSnapshots
        )
    }

    private var reportMonthLabel: String {
        reportDate.map(MonthlyReportSelection.monthLabel) ?? "月度"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                generateCard
                reportsList
            }
            .padding()
        }
        .background(FIREPalette.paper.ignoresSafeArea())
        .navigationTitle("Codex 分析")
        .onAppear(perform: normalizeSelectedReportDate)
        .onChange(of: availableReportMonths) { _, _ in
            normalizeSelectedReportDate()
        }
    }

    private var generateCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                Text("每月财务总结").font(.headline)
                Text("本机先汇总 \(reportMonthLabel)的收入、生活支出、退款和净结余，再结合完整资产快照，把脱敏数据交给 Mac 上的 Codex 分析。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !availableReportMonths.isEmpty {
                    Picker(
                        "分析月份",
                        selection: Binding(
                            get: { reportDate },
                            set: { selectedReportDate = $0 }
                        )
                    ) {
                        ForEach(availableReportMonths, id: \.self) { month in
                            Text(MonthlyReportSelection.monthLabel(for: month))
                                .tag(Optional(month))
                        }
                    }
                    .pickerStyle(.menu)
                }
                reportSnapshotNote
                Button {
                    Task {
                        await appState.generateReport(
                            reportDate: reportDate,
                            transactions: transactions,
                            assetSnapshots: assetSnapshots,
                            positions: positions,
                            instruments: instruments,
                            liabilities: liabilities,
                            settings: settings
                        )
                    }
                } label: {
                    Label(
                        appState.isWorking
                            ? "正在生成…"
                            : "生成 \(reportMonthLabel)总结",
                        systemImage: "sparkles.rectangle.stack"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(
                    appState.isWorking
                        || appState.bridge.connectedPeerName == nil
                        || transactions.isEmpty
                        || reportAssetSnapshot == nil
                )
                if appState.bridge.connectedPeerName == nil {
                    Button(action: onOpenBridge) {
                        Label(
                            "去设置连接 Mac",
                            systemImage: "gearshape.badge.exclamationmark"
                        )
                    }
                    .buttonStyle(.bordered)
                }
                Text("报告不会提供具体买入、卖出指令。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("分析使用隐性临时会话，不会出现在 Codex 任务列表；报告只保存在 F.I.R.E。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var reportSnapshotNote: some View {
        if let reportDate, let snapshot = reportAssetSnapshot {
            if MonthlyReportSelection.isSameMonth(
                reportDate,
                snapshot.capturedAt
            ) {
                Text(
                    "资产使用 \(snapshot.capturedAt.formatted(.dateTime.year().month().day())) 的完整快照。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(
                    "账单月份与资产快照月份不同：资产使用 \(snapshot.capturedAt.formatted(.dateTime.year().month().day())) 的完整快照。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(FIREPalette.amber)
            }
        } else if reportDate != nil {
            Label(
                "需先保存一次完整资产快照。",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(FIREPalette.amber)
        }
    }

    private var reportsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已保存报告")
                .font(.headline)
                .padding(.horizontal, 3)
            if reports.isEmpty {
                FIRECard {
                    EmptyState(
                        icon: "doc.text.magnifyingglass",
                        title: "还没有报告",
                        message: "连接 Mac 后点击一次，即可生成固定结构的月度分析。"
                    )
                }
            } else {
                ForEach(reports) { report in
                    NavigationLink {
                        ReportDetailView(
                            report: report,
                            answers: answers.filter { $0.reportID == report.id },
                            transactions: transactions
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(savedReportTitle(report))
                                    .font(.headline)
                                Text(report.createdAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(FIREPalette.card, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func normalizeSelectedReportDate() {
        guard let latest = availableReportMonths.first else {
            selectedReportDate = nil
            return
        }
        guard let selectedReportDate,
              availableReportMonths.contains(where: {
                  MonthlyReportSelection.isSameMonth($0, selectedReportDate)
              })
        else {
            self.selectedReportDate = latest
            return
        }
    }

    private func savedReportTitle(_ report: AnalysisReportEntity) -> String {
        guard let decoded = try? JSONDecoder().decode(
            AnalysisReportV1.self,
            from: report.reportJSON
        ), let summary = decoded.monthlySummary else {
            return report.title
        }
        return "\(MonthlyReportSelection.monthLabel(for: summary.periodStart))财务总结"
    }
}

private struct ReportDetailView: View {
    @Environment(FIREAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let report: AnalysisReportEntity
    let answers: [AnalysisAnswerEntity]
    let transactions: [TransactionEntity]
    @State private var question = ""
    @State private var confirmsDelete = false
    @State private var showsDetailedAnalysis = false
    @State private var showsEvidenceAndLimitations = false

    private var decodedReport: AnalysisReportV1? {
        try? JSONDecoder().decode(AnalysisReportV1.self, from: report.reportJSON)
    }

    private var evidenceByID: [String: AnalysisEvidenceV1] {
        Dictionary(
            uniqueKeysWithValues: (decodedReport?.evidence ?? []).map {
                ($0.id, $0)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let value = decodedReport {
                    reportBody(value)
                } else {
                    FIRECard {
                        Text("报告内容无法解析，但本地原始数据仍然保留。")
                            .foregroundStyle(FIREPalette.clay)
                    }
                }
                answersBody
                questionComposer
            }
            .padding()
        }
        .background(FIREPalette.paper.ignoresSafeArea())
        .navigationTitle(report.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            "删除本机报告和问答记录？",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("彻底删除", role: .destructive) {
                Task {
                    await appState.deleteReport(report, answers: answers)
                    if appState.errorMessage == nil { dismiss() }
                }
            }
        } message: {
            Text("此操作不可撤销。账单和资产数据不会被删除。")
        }
    }

    @ViewBuilder
    private func reportBody(_ value: AnalysisReportV1) -> some View {
        let localTransactions = transactions.map(\.coreValue)
        let actionItems = value.actions.map {
            ReportSectionItem(
                text: "\($0.title)：\($0.rationale)",
                evidenceRefs: $0.evidenceRefs
            )
        }
        let largestExpenses = value.spendingAnalysis.map {
            ReportExpenseResolver.largestExpenses(analysis: $0)
        } ?? ReportExpenseResolver.largestExpenses(
                report: value,
                transactions: localTransactions
            )
        let actionExpenseReferences = Set(
            value.actions
                .flatMap(\.evidenceRefs)
                .compactMap { evidenceByID[$0] }
                .flatMap(\.transactionFingerprints)
                .map { $0.lowercased() }
        )

        if let summary = value.monthlySummary {
            MonthlySummaryView(summary: summary)
        }
        FIRECard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("核心结论", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Text(value.dataConfidence.level.reportDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FIREPalette.moss)
                }
                Text(value.coreConclusion)
                    .font(.body)
            }
        }
        CategoryChangesCard(analysis: value.spendingAnalysis)
        UnusualExpensesCard(analysis: value.spendingAnalysis)
        FIRECard {
            VStack(alignment: .leading, spacing: 10) {
                Label("本月大额支出 Top 10", systemImage: "banknote")
                    .font(.headline)
                if largestExpenses.isEmpty {
                    Text("本月没有可纳入生活支出的流水。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ReportExpenseRows(
                        items: largestExpenses,
                        highlightedReferenceKeys: actionExpenseReferences
                    )
                }
                Text("按单笔金额从高到低排列；转账、投资买卖、贷款本金和重复流水不在其中。「建议涉及」只表示 Codex 的行动建议引用了该笔消费。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ReportSection(
            title: "Codex 支出判断",
            icon: "cart",
            items: value.spendingFindings.map {
                ReportSectionItem(
                    text: "\($0.title)：\($0.detail)",
                    evidenceRefs: $0.evidenceRefs
                )
            },
            evidenceByID: evidenceByID
        )
        ReportSection(
            title: "下一步",
            icon: "checklist",
            items: actionItems,
            evidenceByID: evidenceByID,
            showsEvidence: false
        )
        let findingCount = value.assetStructureRisks.count
            + value.fireDrivers.count
        if findingCount > 0 {
            FIRECard {
                DisclosureGroup(isExpanded: $showsDetailedAnalysis) {
                    VStack(alignment: .leading, spacing: 18) {
                        Divider()
                        ReportSectionContent(
                            title: "资产结构风险",
                            icon: "chart.pie",
                            items: value.assetStructureRisks.map {
                                ReportSectionItem(
                                    text: "\($0.title)：\($0.detail)",
                                    evidenceRefs: $0.evidenceRefs
                                )
                            },
                            evidenceByID: evidenceByID
                        )
                        ReportSectionContent(
                            title: "FIRE 驱动因素",
                            icon: "wind",
                            items: value.fireDrivers.map {
                                ReportSectionItem(
                                    text: "\($0.title)：\($0.detail)",
                                    evidenceRefs: $0.evidenceRefs
                                )
                            },
                            evidenceByID: evidenceByID
                        )
                    }
                    .padding(.top, 6)
                } label: {
                    disclosureLabel(
                        title: "资产与 FIRE 分析",
                        detail: "\(findingCount) 条",
                        icon: "list.bullet.rectangle"
                    )
                }
            }
        }
        if !value.evidence.isEmpty || !value.limitations.isEmpty {
            FIRECard {
                DisclosureGroup(isExpanded: $showsEvidenceAndLimitations) {
                    ReportEvidenceDetails(
                        confidenceExplanation:
                            value.dataConfidence.explanation,
                        evidence: value.evidence,
                        limitations: value.limitations
                    )
                    .padding(.top, 12)
                } label: {
                    disclosureLabel(
                        title: "数据依据与局限",
                        detail: "\(value.evidence.count) 条依据",
                        icon: "info.circle"
                    )
                }
            }
        }
    }

    private func disclosureLabel(
        title: String,
        detail: String,
        icon: String
    ) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.headline)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var answersBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !answers.isEmpty {
                Text("追问")
                    .font(.headline)
                ForEach(answers) { entity in
                    if let answer = try? JSONDecoder().decode(
                        AnalysisAnswerV1.self,
                        from: entity.answerJSON
                    ) {
                        FIRECard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entity.question)
                                    .font(.subheadline.weight(.semibold))
                                Text(answer.answer)
                                    .font(.subheadline)
                                EvidenceReferencesView(
                                    references: answer.evidenceRefs,
                                    evidenceByID: evidenceByID
                                )
                                if !answer.limitations.isEmpty {
                                    Text(answer.limitations.joined(separator: "；"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var questionComposer: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 10) {
                Text("继续追问").font(.headline)
                TextField("例如：哪些支出最影响预计年份？", text: $question, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                Button {
                    let current = question
                    question = ""
                    Task { await appState.followUp(report: report, question: current) }
                } label: {
                    Label("发送追问", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(
                    appState.isWorking
                        || appState.bridge.connectedPeerName == nil
                        || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || question.count > 4_000
                )
                Text("仅引用本报告会话中的数据，不提供具体交易指令。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MonthlySummaryView: View {
    let summary: MonthlyFinancialSummaryV1

    var body: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        "\(MonthlyReportSelection.monthLabel(for: summary.periodStart))收支",
                        systemImage: "calendar"
                    )
                        .font(.headline)
                    Spacer()
                    Text(summary.isCompleteMonth ? "完整月" : "账单月份不完整")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            summary.isCompleteMonth
                                ? FIREPalette.moss
                                : FIREPalette.amber
                        )
                }
                HStack {
                    MetricLabel(
                        title: "收入",
                        value: summary.income.doubleValue.cnyText
                    )
                    Spacer()
                    MetricLabel(
                        title: "生活支出",
                        value: summary.livingExpense.doubleValue.cnyText
                    )
                }
                if let refundIncome = summary.refundIncome,
                   refundIncome != 0
                {
                    MetricLabel(
                        title: "支出退款",
                        value: refundIncome.doubleValue.cnyText
                    )
                }
                Divider()
                MetricLabel(
                    title: "净结余",
                    value: summary.netCashFlow.doubleValue.cnyText,
                    detail: "收入 + 支出退款 − 生活支出 · \(summary.transactionCount) 笔有效流水"
                )
            }
        }

        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("资产概览", systemImage: "chart.pie.fill")
                        .font(.headline)
                    Spacer()
                    Text(
                        summary.assetSnapshotDate,
                        format: .dateTime.year().month().day()
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !MonthlyReportSelection.isSameMonth(
                    summary.periodStart,
                    summary.assetSnapshotDate
                ) {
                    Label(
                        "资产快照与账单月份不同，金额按上方快照日期展示。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(FIREPalette.amber)
                }
                HStack {
                    MetricLabel(
                        title: "基金",
                        value: summary.fundValue.doubleValue.cnyText
                    )
                    Spacer()
                    MetricLabel(
                        title: "股票",
                        value: summary.stockValue.doubleValue.cnyText
                    )
                }
                if let optionValue = summary.optionValue,
                   optionValue != 0
                {
                    MetricLabel(
                        title: "期权",
                        value: optionValue.doubleValue.cnyText
                    )
                }
                HStack {
                    MetricLabel(
                        title: "现金",
                        value: summary.cashValue.doubleValue.cnyText
                    )
                    Spacer()
                    MetricLabel(
                        title: "总资产",
                        value: summary.totalAssets.doubleValue.cnyText
                    )
                }
                Divider()
                HStack {
                    MetricLabel(
                        title: "负债",
                        value: summary.liabilities.doubleValue.cnyText
                    )
                    Spacer()
                    MetricLabel(
                        title: "可投资净资产",
                        value: summary.investableNetWorth.doubleValue.cnyText
                    )
                }
            }
        }
    }
}

private struct CategoryChangesCard: View {
    let analysis: MonthlySpendingAnalysisV1?

    var body: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                Label("大类异动", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Text("本月金额与此前最多 3 个完整月的月度中位数比较。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let analysis {
                    if analysis.categoryChanges.isEmpty {
                        categoryEmptyState(analysis)
                    } else {
                        ForEach(
                            Array(analysis.categoryChanges.enumerated()),
                            id: \.offset
                        ) { index, change in
                            if index > 0 { Divider() }
                            categoryRow(
                                change,
                                comparisonMonthCount:
                                    analysis.comparisonMonthCount
                            )
                        }
                    }
                } else {
                    Text("这是旧版报告，未保存当时的大类异动快照。重新生成该月报告后即可查看。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryEmptyState(
        _ analysis: MonthlySpendingAnalysisV1
    ) -> some View {
        if analysis.comparisonMonthCount == 0 {
            Text("历史不足：还没有可比较的完整月。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Text("与前 \(analysis.comparisonMonthCount) 个完整月相比，没有发现明显的大类异动。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func categoryRow(
        _ change: MonthlyCategoryChangeV1,
        comparisonMonthCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(change.primaryCategory)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(change.currentAmount.moneyText(currency: change.currency))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Text("前 \(comparisonMonthCount) 月中位数 \(change.baselineMedianAmount.moneyText(currency: change.currency))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(change.changeAmount.signedMoneyText(currency: change.currency))
                if let rate = change.changeRate {
                    Text(rate.signedPercentText)
                } else if change.baselineMedianAmount == 0,
                          change.currentAmount > 0
                {
                    Text("本月新增")
                }
                Text("占本月支出 \(change.currentMonthShare.percentText)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                change.changeAmount > 0
                    ? FIREPalette.clay
                    : FIREPalette.moss
            )
        }
    }
}

private struct UnusualExpensesCard: View {
    let analysis: MonthlySpendingAnalysisV1?

    var body: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 10) {
                Label("异常支出", systemImage: "exclamationmark.magnifyingglass")
                    .font(.headline)
                Text("口径：单笔至少 2,000 元、达到历史同类单笔中位数的 3 倍，且历史同类至少有 5 笔。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let analysis {
                    if analysis.unusualExpenses.isEmpty {
                        if analysis.comparisonMonthCount < 2 {
                            Text("历史不足：至少需要 2 个可比较的完整月，才能判断单笔支出是否异常。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("本月未发现明显偏离历史水平的大额支出。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ReportExpenseRows(
                            items: analysis.unusualExpenses.map(
                                ReportExpenseItem.init(signal:)
                            )
                        )
                    }
                } else {
                    Text("这是旧版报告，未保存当时的异常支出快照。重新生成该月报告后即可查看。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ReportSectionItem {
    let text: String
    let evidenceRefs: [String]
}

private struct ReportSection: View {
    let title: String
    let icon: String
    let items: [ReportSectionItem]
    let evidenceByID: [String: AnalysisEvidenceV1]
    var showsEvidence = true

    var body: some View {
        FIRECard {
            ReportSectionContent(
                title: title,
                icon: icon,
                items: items,
                evidenceByID: evidenceByID,
                showsEvidence: showsEvidence
            )
        }
    }
}

private struct ReportSectionContent: View {
    let title: String
    let icon: String
    let items: [ReportSectionItem]
    let evidenceByID: [String: AnalysisEvidenceV1]
    var showsEvidence = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            if items.isEmpty {
                Text("暂无发现")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(FIREPalette.onButton)
                            .frame(width: 22, height: 22)
                            .background(FIREPalette.buttonFill, in: Circle())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.text)
                                .font(.subheadline)
                            if showsEvidence {
                                EvidenceReferencesView(
                                    references: item.evidenceRefs,
                                    evidenceByID: evidenceByID
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ReportExpenseRows: View {
    let items: [ReportExpenseItem]
    var highlightedReferenceKeys: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(
                                "\(item.occurredAt.formatted(.dateTime.month().day())) · \(item.merchantDisplayName)"
                            )
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            if !item.referenceKeys.isDisjoint(
                                with: highlightedReferenceKeys
                            ) {
                                Text("建议涉及")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(FIREPalette.moss)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        FIREPalette.moss.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                        }
                        if !item.categoryDisplayName.isEmpty {
                            Text(item.categoryDisplayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let share = item.monthlyExpenseShare,
                           share > 0
                        {
                            Text("占本月生活支出 \(share.percentText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let reason = item.reason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FIREPalette.clay)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(item.amountText)
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
        }
    }
}

private extension Decimal {
    var reportDoubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }

    func moneyText(currency: CurrencyCode) -> String {
        "\(currency.rawValue) \(reportDoubleValue.formatted(.number.precision(.fractionLength(0...2))))"
    }

    func signedMoneyText(currency: CurrencyCode) -> String {
        let sign = self > 0 ? "+" : ""
        return "\(sign)\(moneyText(currency: currency))"
    }

    var percentText: String {
        reportDoubleValue.formatted(
            .percent.precision(.fractionLength(0...1))
        )
    }

    var signedPercentText: String {
        let sign = self > 0 ? "+" : ""
        return "\(sign)\(percentText)"
    }
}

private struct EvidenceReferencesView: View {
    let references: [String]
    let evidenceByID: [String: AnalysisEvidenceV1]
    @State private var isExpanded = false

    var body: some View {
        if !references.isEmpty {
            DisclosureGroup(
                "查看依据（\(references.count)）",
                isExpanded: $isExpanded
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(references, id: \.self) { reference in
                        if let evidence = evidenceByID[reference] {
                            Text("\(evidence.label)：\(evidence.value)")
                                .font(.caption)
                                .foregroundStyle(FIREPalette.moss)
                        } else {
                            Text("该条依据暂不可用")
                                .font(.caption)
                                .foregroundStyle(FIREPalette.clay)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .tint(FIREPalette.moss)
        }
    }
}

private struct ReportEvidenceDetails: View {
    let confidenceExplanation: String
    let evidence: [AnalysisEvidenceV1]
    let limitations: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("可信度说明")
                .font(.subheadline.weight(.semibold))
            Text(confidenceExplanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !limitations.isEmpty || !evidence.isEmpty {
                Divider()
            }
            if !limitations.isEmpty {
                Text("分析局限")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(limitations.enumerated()), id: \.offset) {
                    _, limitation in
                    Text("• \(limitation)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !limitations.isEmpty, !evidence.isEmpty {
                Divider()
            }
            if !evidence.isEmpty {
                Text("数据依据")
                    .font(.subheadline.weight(.semibold))
                ForEach(evidence) { item in
                    Text("• \(item.label)：\(item.value)")
                        .font(.subheadline)
                }
            }
        }
    }
}

private extension DataConfidence {
    var reportDisplayName: String {
        switch self {
        case .insufficient: "数据不足"
        case .low: "低可信度"
        case .medium: "中可信度"
        case .high: "高可信度"
        }
    }
}
