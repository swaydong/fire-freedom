import FIRECore
import Foundation
import SwiftUI

enum DocumentSelectionResolver {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && error.code == NSUserCancelledError
    }
}

struct KapiSyncPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preview: KapiSyncPreview
    let hidesNumbers: Bool
    let isApplying: Bool
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void

    @State private var confirmsCompleteExport = false
    @State private var showsAdded = false
    @State private var showsRemoved = false

    private var privacyFormatter: FinancialPrivacyFormatter {
        FinancialPrivacyFormatter(hidesNumbers: hidesNumbers)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    coverageCard
                    countCard
                    totalChangeCard
                    duplicateChangesCard
                    possibleModificationsCard
                    transactionDetailsCard
                    confirmationCard
                }
                .padding()
            }
            .background(FIREPalette.paper.ignoresSafeArea())
            .navigationTitle("确认账单同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        onCancel()
                        dismiss()
                    }
                    .disabled(isApplying)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirm(confirmsCompleteExport)
                } label: {
                    HStack {
                        if isApplying {
                            ProgressView()
                                .tint(FIREPalette.onButton)
                        }
                        Text(isApplying ? "正在同步…" : "确认同步")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!confirmsCompleteExport || isApplying)
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .interactiveDismissDisabled(isApplying)
    }

    private var coverageCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 8) {
                Label("权威覆盖区间", systemImage: "calendar")
                    .font(.headline)
                Text(
                    "\(preview.coverage.start.formatted(date: .long, time: .omitted)) – \(preview.coverage.end.formatted(date: .long, time: .omitted))"
                )
                .font(.title3.weight(.semibold))
                Text(preview.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if preview.legacyUpgradeCount > 0 {
                    Label(
                        "其中 \(preview.legacyUpgradeCount) 笔旧数据会补齐账本、标签等来源字段。",
                        systemImage: "arrow.up.doc"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var countCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                Text("本次差异").font(.headline)
                HStack(spacing: 10) {
                    countMetric(
                        title: "未变化",
                        value: preview.reconciliation.unchanged.count,
                        color: FIREPalette.moss
                    )
                    countMetric(
                        title: "新增",
                        value: preview.reconciliation.added.count,
                        color: FIREPalette.accent
                    )
                    countMetric(
                        title: "消失",
                        value: preview.reconciliation.removed.count,
                        color: FIREPalette.clay
                    )
                }
                if preview.incomingItems.isEmpty {
                    Label(
                        "文件声明的区间内没有流水；确认后会移除该区间现有的咔皮账单。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(FIREPalette.amber)
                }
            }
        }
    }

    private var totalChangeCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                Text("收支变化").font(.headline)
                totalChangeRow(
                    title: "收入",
                    previous: preview.previousIncomeTotal,
                    incoming: preview.incomingIncomeTotal
                )
                Divider()
                totalChangeRow(
                    title: "支出",
                    previous: preview.previousExpenseTotal,
                    incoming: preview.incomingExpenseTotal
                )
            }
        }
    }

    @ViewBuilder
    private var duplicateChangesCard: some View {
        let changes = preview.duplicateMultiplicityChanges
        if !changes.isEmpty {
            FIRECard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("同内容流水数量变化").font(.headline)
                    Text("这里按完全相同内容的出现次数比较，不会把两笔真实消费合并。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(changes.enumerated()), id: \.offset) {
                        index,
                        change in
                        if let item = preview.representative(for: change) {
                            transactionRow(item)
                            Text(
                                "上次 \(change.previousCount) 笔 → 本次 \(change.incomingCount) 笔"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                change.incomingCount < change.previousCount
                                    ? FIREPalette.clay
                                    : FIREPalette.moss
                            )
                        }
                        if index < changes.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var possibleModificationsCard: some View {
        let changes = preview.reconciliation.possibleModifications
        if !changes.isEmpty {
            FIRECard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("可能是修改").font(.headline)
                    Text("仅帮助核对；系统仍按新增和消失同步，不会自动认定为同一笔。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(changes.prefix(10).enumerated()), id: \.offset) {
                        index,
                        change in
                        VStack(alignment: .leading, spacing: 8) {
                            comparisonRow(
                                label: "上次",
                                item: change.previous,
                                color: FIREPalette.clay
                            )
                            comparisonRow(
                                label: "本次",
                                item: change.incoming,
                                color: FIREPalette.moss
                            )
                            Text(
                                "差异：\(KapiSyncDisplay.changedFieldNames(previous: change.previous, incoming: change.incoming).joined(separator: "、"))"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        if index < min(changes.count, 10) - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var transactionDetailsCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                Text("流水明细").font(.headline)
                DisclosureGroup(
                    "新增 \(preview.reconciliation.added.count) 笔",
                    isExpanded: $showsAdded
                ) {
                    transactionList(preview.reconciliation.added)
                }
                Divider()
                DisclosureGroup(
                    "消失 \(preview.reconciliation.removed.count) 笔",
                    isExpanded: $showsRemoved
                ) {
                    transactionList(preview.reconciliation.removed)
                }
            }
        }
    }

    private var confirmationCard: some View {
        FIRECard {
            Toggle(isOn: $confirmsCompleteExport) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("确认这是完整导出")
                        .font(.headline)
                    Text("我在咔皮选择了全部账本，且没有按账户、分类或标签筛选。区间内未出现在文件中的咔皮流水会从当前账本移除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private func countMetric(
        title: String,
        value: Int,
        color: Color
    ) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title2.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func totalChangeRow(
        title: String,
        previous: Double,
        incoming: Double
    ) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(
                "\(privacyFormatter.value(previous.cnyText)) → \(privacyFormatter.value(incoming.cnyText))"
            )
            .font(.subheadline.monospacedDigit())
        }
    }

    private func transactionList(
        _ items: [KapiSnapshotItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.prefix(30).enumerated()), id: \.offset) {
                index,
                item in
                transactionRow(item)
                if index < min(items.count, 30) - 1 {
                    Divider()
                }
            }
            if items.count > 30 {
                Text("另有 \(items.count - 30) 笔未展开显示")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10)
    }

    private func transactionRow(
        _ item: KapiSnapshotItem
    ) -> some View {
        let value = item.transaction
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(KapiSyncDisplay.title(for: item))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(
                    value.occurredAt,
                    format: .dateTime.year().month().day().hour().minute()
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(
                privacyFormatter.value(value.amount.doubleValue.cnyText)
            )
            .font(.subheadline.monospacedDigit())
        }
    }

    private func comparisonRow(
        label: String,
        item: KapiSnapshotItem,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 34, alignment: .leading)
            Text(KapiSyncDisplay.title(for: item))
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text(
                privacyFormatter.value(
                    item.transaction.amount.doubleValue.cnyText
                )
            )
            .font(.caption.monospacedDigit())
        }
    }
}

private enum KapiSyncDisplay {
    static func title(for item: KapiSnapshotItem) -> String {
        let value = item.transaction
        return [
            value.merchantNote,
            value.secondaryCategory,
            value.primaryCategory,
        ].first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? "未分类流水"
    }

    static func changedFieldNames(
        previous: KapiSnapshotItem,
        incoming: KapiSnapshotItem
    ) -> [String] {
        let lhs = previous.transaction
        let rhs = incoming.transaction
        var result: [String] = []
        if lhs.occurredAt != rhs.occurredAt { result.append("日期或时间") }
        if lhs.direction != rhs.direction { result.append("收支类型") }
        if lhs.amount != rhs.amount { result.append("金额") }
        if lhs.primaryCategory != rhs.primaryCategory {
            result.append("一级分类")
        }
        if lhs.secondaryCategory != rhs.secondaryCategory {
            result.append("二级分类")
        }
        if lhs.merchantNote != rhs.merchantNote { result.append("备注") }
        if lhs.tags != rhs.tags { result.append("标签") }
        if lhs.accountName != rhs.accountName { result.append("账户") }
        if lhs.ledgerName != rhs.ledgerName { result.append("所属账本") }
        if lhs.includedInCashFlow != rhs.includedInCashFlow {
            result.append("计入收支")
        }
        if lhs.includedInBudget != rhs.includedInBudget {
            result.append("计入预算")
        }
        if previous.splitDetails != incoming.splitDetails {
            result.append("分摊明细")
        }
        return result.isEmpty ? ["其他来源字段"] : result
    }
}
