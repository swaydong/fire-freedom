import SwiftUI
import UniformTypeIdentifiers

struct TransactionsView: View {
    @Environment(FIREAppState.self) private var appState
    let transactions: [TransactionEntity]
    @Binding var hidesNumbers: Bool
    @State private var showingImporter = false
    @State private var showingUndoConfirmation = false

    private var privacyFormatter: FinancialPrivacyFormatter {
        FinancialPrivacyFormatter(hidesNumbers: hidesNumbers)
    }

    private var expenseTotal: Double {
        transactions.filter {
            $0.directionRawValue.contains("支出") && $0.isIncluded
        }
            .reduce(0) { $0 + $1.amount }
    }

    private var incomeTotal: Double {
        transactions.filter {
            $0.directionRawValue.contains("收入") && $0.isIncluded
        }
            .reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                importCard
                if !transactions.isEmpty {
                    totalsCard
                    duplicateCard
                    duplicateReviewCard
                    recentTransactions
                }
            }
            .padding()
        }
        .background(FIREPalette.paper.ignoresSafeArea())
        .navigationTitle("收支账本")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FinancialPrivacyButton(hidesNumbers: $hidesNumbers)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "xlsx")!],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    appState.prepareKapiSync(at: url)
                }
            case .failure(let error):
                if !DocumentSelectionResolver.isCancellation(error) {
                    appState.errorMessage = error.localizedDescription
                }
            }
        }
        .sheet(
            item: Binding(
                get: { appState.pendingKapiSync },
                set: { value in
                    if value == nil {
                        appState.cancelKapiSyncPreview()
                    }
                }
            )
        ) { preview in
            KapiSyncPreviewSheet(
                preview: preview,
                hidesNumbers: hidesNumbers,
                isApplying: appState.isWorking,
                onCancel: {
                    appState.cancelKapiSyncPreview()
                },
                onConfirm: { confirmsCompleteExport in
                    appState.confirmKapiSync(
                        previewID: preview.id,
                        confirmsCompleteUnfilteredExport:
                            confirmsCompleteExport
                    )
                }
            )
        }
        .confirmationDialog(
            "撤回最近一次账单同步？",
            isPresented: $showingUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button("撤回同步", role: .destructive) {
                appState.undoLastKapiSync()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将恢复同步前该日期区间内的账单和人工确认状态。")
        }
    }

    private var importCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.title2)
                        .foregroundStyle(FIREPalette.moss)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("咔皮账单同步").font(.headline)
                        Text("按导出日期区间对账，确认前先展示差异")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    showingImporter = true
                } label: {
                    Label(
                        appState.isWorking ? "正在处理…" : "选择咔皮导出文件",
                        systemImage: "doc.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(appState.isWorking)

                if let receipt = appState.latestKapiSyncReceipt {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                receipt.isReverted
                                    ? "最近同步已撤回"
                                    : "最近同步 +\(receipt.addedCount) / −\(receipt.removedCount)"
                            )
                            .font(.subheadline.weight(.medium))
                            Text(
                                "\(receipt.coverage.start.formatted(date: .numeric, time: .omitted)) – \(receipt.coverage.end.formatted(date: .numeric, time: .omitted))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if receipt.canUndo {
                            Button("撤回") {
                                showingUndoConfirmation = true
                            }
                            .font(.subheadline.weight(.semibold))
                            .disabled(appState.isWorking)
                        }
                    }
                }

                if let summary = appState.importSummary {
                    Divider()
                    Text("本次新增 \(summary.importedCount) 笔 · 疑似重复 \(summary.duplicateCount) 笔")
                        .font(.subheadline.weight(.medium))
                    if let first = summary.firstDate, let last = summary.lastDate {
                        Text("\(first.formatted(date: .numeric, time: .omitted)) – \(last.formatted(date: .numeric, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let warning = summary.coverageWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(FIREPalette.amber)
                    }
                }
            }
        }
    }

    private var totalsCard: some View {
        FIRECard {
            HStack {
                MetricLabel(
                    title: "累计收入",
                    value: privacyFormatter.value(incomeTotal.cnyText),
                    detail: "\(transactions.filter { $0.directionRawValue.contains("收入") && $0.isIncluded }.count) 笔计入"
                )
                Spacer()
                MetricLabel(
                    title: "累计支出",
                    value: privacyFormatter.value(expenseTotal.cnyText),
                    detail: "\(transactions.filter { $0.directionRawValue.contains("支出") && $0.isIncluded }.count) 笔计入"
                )
            }
        }
    }

    private var duplicateCard: some View {
        let duplicates = transactions.filter(\.isSuspectedDuplicate)
        let excluded = transactions.filter { !$0.isIncluded || $0.isInternalTransfer
            || $0.isInvestmentTrade || $0.isLoanPrincipal }
        return FIRECard {
            HStack(spacing: 14) {
                Image(systemName: "checklist.checked")
                    .font(.title2)
                    .foregroundStyle(FIREPalette.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text("自动口径检查").font(.headline)
                    Text("疑似重复 \(duplicates.count) 笔 · 已排除 \(excluded.count) 笔")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("内部转账、投资买卖与贷款本金不会进入长期生活支出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var duplicateReviewCard: some View {
        let duplicates = transactions.filter(\.isSuspectedDuplicate)
        if !duplicates.isEmpty {
            FIRECard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("核对疑似重复").font(.headline)
                    Text("系统默认不把这些流水计入长期支出；如果是两笔真实消费，请点“确认保留”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(duplicates) { transaction in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    transaction.subcategory.isEmpty
                                        ? transaction.category
                                        : transaction.subcategory
                                )
                                .font(.subheadline.weight(.medium))
                                Text(
                                    transaction.transactionDate,
                                    format: .dateTime.year().month().day().hour().minute()
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(
                                privacyFormatter.value(
                                    transaction.amount.cnyText
                                )
                            )
                                .font(.subheadline.monospacedDigit())
                            Button("确认保留") {
                                appState.keepSuspectedDuplicate(transaction)
                            }
                            .font(.caption.weight(.semibold))
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var recentTransactions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近流水")
                .font(.headline)
                .padding(.horizontal, 3)
            ForEach(transactions.prefix(20)) { transaction in
                HStack(spacing: 12) {
                    Image(systemName: transaction.directionRawValue.contains("收入")
                          ? "arrow.down.left" : "arrow.up.right")
                        .foregroundStyle(transaction.directionRawValue.contains("收入")
                                         ? FIREPalette.accent : FIREPalette.textInk)
                        .frame(width: 30, height: 30)
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: Circle()
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(transaction.subcategory.isEmpty
                             ? transaction.category : transaction.subcategory)
                            .font(.subheadline.weight(.medium))
                        Text([transaction.merchant, transaction.note]
                            .filter { !$0.isEmpty }.first ?? "无备注")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(
                            privacyFormatter.value(
                                transaction.amount.cnyText
                            )
                        )
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                        Text(transaction.transactionDate, format: .dateTime.month().day())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if transaction.isSuspectedDuplicate {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(FIREPalette.amber)
                    }
                }
                .padding(14)
                .background(FIREPalette.card, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
