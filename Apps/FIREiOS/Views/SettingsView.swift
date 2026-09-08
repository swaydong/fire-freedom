import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum AssumptionField: Hashable {
        case withdrawalRate
        case expectedReturn
        case inflation
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(FIREAppState.self) private var appState
    @Environment(SessionLockController.self) private var lockController
    @Query private var settings: [FIRESettingsEntity]

    @State private var withdrawalRate = 0.035
    @State private var expectedReturn = 0.05
    @State private var inflation = 0.02
    @State private var backupDocument: FIREBackupDocument?
    @State private var exportingBackup = false
    @State private var importingBackup = false
    @State private var pendingRestore: BackupRestorePlan?
    @State private var confirmingRestore = false
    @State private var isRestoring = false
    @State private var inflationService = InflationSuggestionService()
    @State private var inflationSuggestion: InflationSuggestion?
    @State private var isRefreshingInflation = false
    @State private var inflationRefreshFailed = false
    @State private var riskFreeRateService =
        RiskFreeRateSuggestionService()
    @State private var riskFreeRateSuggestion: RiskFreeRateSuggestion?
    @State private var isRefreshingRiskFreeRate = false
    @State private var riskFreeRateRefreshFailed = false
    @FocusState private var focusedAssumptionField: AssumptionField?

    var body: some View {
        Form {
            BridgeConnectionSection()

            Section("FIRE 规划参数") {
                HStack {
                    Text("每年从资产提取")
                    Spacer()
                    TextField(
                        "3.5",
                        value: Binding(
                            get: { withdrawalRate * 100 },
                            set: { withdrawalRate = $0 / 100 }
                        ),
                        format: .number.precision(.fractionLength(1))
                    )
                    .keyboardType(.decimalPad)
                    .focused(
                        $focusedAssumptionField,
                        equals: .withdrawalRate
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    Text("%").foregroundStyle(.secondary)
                }
                withdrawalRateSuggestionRows
                HStack {
                    Text("预期年化收益")
                    Spacer()
                    TextField(
                        "5",
                        value: Binding(
                            get: { expectedReturn * 100 },
                            set: { expectedReturn = $0 / 100 }
                        ),
                        format: .number.precision(.fractionLength(1))
                    )
                    .keyboardType(.decimalPad)
                    .focused(
                        $focusedAssumptionField,
                        equals: .expectedReturn
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    Text("%").foregroundStyle(.secondary)
                }
                riskFreeRateSuggestionRows
                HStack {
                    Text("年通胀")
                    Spacer()
                    TextField(
                        "2",
                        value: Binding(
                            get: { inflation * 100 },
                            set: { inflation = $0 / 100 }
                        ),
                        format: .number.precision(.fractionLength(1))
                    )
                    .keyboardType(.decimalPad)
                    .focused(
                        $focusedAssumptionField,
                        equals: .inflation
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    Text("%").foregroundStyle(.secondary)
                }
                inflationSuggestionRows
                Button {
                    focusedAssumptionField = nil
                    appState.updateAssumptions(
                        withdrawalRate: withdrawalRate,
                        expectedReturn: expectedReturn,
                        inflation: inflation
                    )
                } label: {
                    Text("保存全部参数")
                        .font(.headline)
                        .foregroundStyle(FIREPalette.onButton)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            FIREPalette.buttonFill,
                            in: RoundedRectangle(
                                cornerRadius: 12,
                                style: .continuous
                            )
                        )
                        .contentShape(
                            RoundedRectangle(
                                cornerRadius: 12,
                                style: .continuous
                            )
                        )
                }
                .buttonStyle(.plain)
                Text("FIRE 目标使用账本自动估算的年度支出和这里保存的规划假设；建议值仅供参考，请手动填写后统一保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("隐私与备份") {
                Button {
                    do {
                        backupDocument = try EncryptedBackupService(
                            context: modelContext
                        ).createDocument()
                        exportingBackup = true
                    } catch {
                        appState.errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("导出本机加密备份", systemImage: "externaldrive.badge.lock")
                }
                Button {
                    importingBackup = true
                } label: {
                    Label("从加密备份恢复", systemImage: "externaldrive.badge.checkmark")
                }
                .disabled(isRestoring)
                Button {
                    lockController.lockImmediately()
                } label: {
                    Label("立即锁定", systemImage: "lock.fill")
                }
                LabeledContent("自动锁定", value: "离开 App 超过 1 分钟")
                Text("备份使用保存在本机 Keychain 的设备密钥加密，不设密码；只能在仍保留该密钥的同一台 iPhone 上解密和恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("同步") {
                LabeledContent("本地账本", value: "已启用")
                LabeledContent("iCloud 私有同步", value: "暂未启用")
                Text("当前数据保留稳定标识，便于后续迁移；具备付费 Apple Developer 权限后再接入并验证可选的 CloudKit 私有同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("数据边界") {
                Label("账本、资产和 FIRE 计算始终本地可用", systemImage: "iphone")
                Label("截图只做设备端 OCR，原图不保存", systemImage: "eye.slash")
                Label("发送 AI 前移除账号、卡号、手机号、邮箱及证件号", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(FIREPalette.paper)
        .navigationTitle("设置")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    focusedAssumptionField = nil
                }
            }
        }
        .onAppear {
            withdrawalRate = settings.first?.withdrawalRate ?? 0.035
            expectedReturn = settings.first?.expectedReturn ?? 0.05
            inflation = settings.first?.inflation ?? 0.02
        }
        .task {
            await refreshInflationSuggestion(forceRefresh: false)
        }
        .task {
            await refreshRiskFreeRateSuggestion(forceRefresh: false)
        }
        .fileExporter(
            isPresented: $exportingBackup,
            document: backupDocument,
            contentType: UTType(exportedAs: "com.local.fire.backup"),
            defaultFilename: backupFilename
        ) { result in
            switch result {
            case .success:
                appState.statusMessage = "本机加密备份已导出。"
            case .failure(let error):
                appState.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $importingBackup,
            allowedContentTypes: FIREBackupDocument.readableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let canAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if canAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                pendingRestore = try EncryptedBackupService(
                    context: modelContext
                ).prepareRestore(
                    document: FIREBackupDocument(encryptedData: data)
                )
                confirmingRestore = true
            } catch {
                pendingRestore = nil
                appState.errorMessage = error.localizedDescription
            }
        }
        .alert("替换本机数据？", isPresented: $confirmingRestore) {
            Button("取消", role: .cancel) {
                pendingRestore = nil
            }
            Button("替换并恢复", role: .destructive) {
                restorePendingBackup()
            }
        } message: {
            Text(restoreConfirmationMessage)
        }
    }

    private var backupFilename: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "FIRE-\(formatter.string(from: .now)).firebackup"
    }

    @ViewBuilder
    private var withdrawalRateSuggestionRows: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(
                "长期 FIRE 建议 3.5%",
                systemImage: "lifepreserver.fill"
            )
            .font(.subheadline.weight(.semibold))
            Text("FIRE 目标 = 账本年度支出 ÷ 提取率。3% 更保守；4% 所需资产较少，但更依赖投资表现和退休年限。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Link(
            "查看提取率研究依据",
            destination: URL(
                string: "https://www.morningstar.com/en-us/business/insights/blog/retirement-income-planning-advisor-playbook"
            )!
        )
        .font(.caption)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var riskFreeRateSuggestionRows: some View {
        if let suggestion = riskFreeRateSuggestion {
            VStack(alignment: .leading, spacing: 9) {
                Label(
                    "保守建议 \(suggestion.rate.percentText)",
                    systemImage: "building.columns.fill"
                )
                .font(.subheadline.weight(.semibold))
                Text("该数值取自财政部—中国国债收益率曲线的 10 年期值，仅作为人民币无风险参考，不是股票或基金的收益预测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(riskFreeRateStatusText(suggestion))
                    Spacer()
                    Button {
                        Task {
                            await refreshRiskFreeRateSuggestion(
                                forceRefresh: true
                            )
                        }
                    } label: {
                        Label(
                            isRefreshingRiskFreeRate ? "更新中" : "刷新",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshingRiskFreeRate)
                }
                .font(.caption)
            }
            Link(
                suggestion.source,
                destination: URL(
                    string: "https://yield.chinabond.com.cn/cbweb-czb-web/czb/showHistory?locale=zh_CN"
                )!
            )
            .font(.caption)
            .buttonStyle(.plain)
        } else {
            Button {
                Task {
                    await refreshRiskFreeRateSuggestion(forceRefresh: true)
                }
            } label: {
                Label(
                    isRefreshingRiskFreeRate
                        ? "正在查询无风险利率…"
                        : "查询无风险利率参考",
                    systemImage: "building.columns"
                )
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshingRiskFreeRate)
        }
    }

    @ViewBuilder
    private var inflationSuggestionRows: some View {
        if let suggestion = inflationSuggestion {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "规划建议 \(suggestion.rate.percentText)",
                    systemImage: "network"
                )
                .font(.subheadline.weight(.semibold))
                Text(
                    "\(suggestion.sampleStartYear)–\(suggestion.sampleEndYear) 年中国 CPI 年度值中位数；最新 \(suggestion.latestYear) 年为 \(suggestion.latestAnnualRate.percentText)。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Text(
                        inflationRefreshFailed
                            ? "刷新失败，继续使用 \(suggestion.fetchedAt.formatted(date: .abbreviated, time: .omitted)) 的缓存"
                            : (
                                suggestion.isStale
                                    ? "当前为过期缓存"
                                    : "打开设置时，每 30 天检查更新"
                            )
                    )
                    Spacer()
                    Button {
                        Task {
                            await refreshInflationSuggestion(
                                forceRefresh: true
                            )
                        }
                    } label: {
                        Label(
                            isRefreshingInflation ? "更新中" : "刷新",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshingInflation)
                }
                .font(.caption)
            }
            Link(
                suggestion.source,
                destination: URL(
                    string: "https://data.worldbank.org/indicator/FP.CPI.TOTL.ZG?locations=CN"
                )!
            )
            .font(.caption)
            .buttonStyle(.plain)
        } else {
            Button {
                Task {
                    await refreshInflationSuggestion(forceRefresh: true)
                }
            } label: {
                Label(
                    isRefreshingInflation
                        ? "正在查询通胀建议…"
                        : "查询通胀建议",
                    systemImage: "network"
                )
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshingInflation)
        }
    }

    private func riskFreeRateStatusText(
        _ suggestion: RiskFreeRateSuggestion
    ) -> String {
        if riskFreeRateRefreshFailed {
            return "刷新失败，继续使用 \(suggestion.fetchedAt.formatted(date: .abbreviated, time: .omitted)) 的缓存"
        }
        if suggestion.isStale {
            return "当前为过期缓存 · 数据截至 \(suggestion.asOf.formatted(date: .abbreviated, time: .omitted))"
        }
        return "数据截至 \(suggestion.asOf.formatted(date: .abbreviated, time: .omitted)) · 每 7 天检查更新"
    }

    private func refreshInflationSuggestion(forceRefresh: Bool) async {
        guard !isRefreshingInflation else { return }
        isRefreshingInflation = true
        defer { isRefreshingInflation = false }
        do {
            let suggestion = try await inflationService.suggestion(
                forceRefresh: forceRefresh
            )
            inflationSuggestion = suggestion
            inflationRefreshFailed = forceRefresh
                && suggestion.isFromCache
        } catch {
            inflationRefreshFailed = false
            appState.errorMessage = error.localizedDescription
        }
    }

    private func refreshRiskFreeRateSuggestion(
        forceRefresh: Bool
    ) async {
        guard !isRefreshingRiskFreeRate else { return }
        isRefreshingRiskFreeRate = true
        defer { isRefreshingRiskFreeRate = false }
        do {
            let suggestion = try await riskFreeRateService.suggestion(
                forceRefresh: forceRefresh
            )
            riskFreeRateSuggestion = suggestion
            riskFreeRateRefreshFailed = forceRefresh
                && suggestion.isFromCache
        } catch {
            riskFreeRateRefreshFailed = false
            appState.errorMessage = error.localizedDescription
        }
    }

    private var restoreConfirmationMessage: String {
        guard let pendingRestore else {
            return "恢复会替换当前 iPhone 上的全部 F.I.R.E 数据。"
        }
        return """
        已解密并校验 \(pendingRestore.createdAt.formatted(date: .abbreviated, time: .shortened)) 的备份（\(pendingRestore.transactionCount) 笔流水、\(pendingRestore.importBatchCount) 次账单同步、\(pendingRestore.assetSnapshotCount) 个资产快照、\(pendingRestore.reportCount) 份报告）。

        继续会替换当前 iPhone 上的全部 F.I.R.E 数据，此操作不可撤销。
        """
    }

    private func restorePendingBackup() {
        guard let pendingRestore else { return }
        isRestoring = true
        defer {
            isRestoring = false
            self.pendingRestore = nil
        }
        do {
            try EncryptedBackupService(context: modelContext).restore(pendingRestore)
            let restoredSettings = try modelContext.fetch(
                FetchDescriptor<FIRESettingsEntity>()
            ).first
            withdrawalRate = restoredSettings?.withdrawalRate ?? 0.035
            expectedReturn = restoredSettings?.expectedReturn ?? 0.05
            inflation = restoredSettings?.inflation ?? 0.02
            appState.reloadKapiSyncReceipt()
            appState.notifyDataChanged()
            appState.statusMessage = "本机数据已从加密备份完整恢复。"
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}

private struct BridgeConnectionSection: View {
    @Environment(FIREAppState.self) private var appState

    var body: some View {
        @Bindable var bridge = appState.bridge

        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(
                    systemName: bridge.indicatorState == .connected
                        ? "desktopcomputer.and.macbook"
                        : "desktopcomputer.trianglebadge.exclamationmark"
                )
                .font(.title2)
                .foregroundStyle(bridge.indicatorState.color)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac 桥接")
                        .font(.headline)
                    Text(bridge.connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                BridgeStatusPill(state: bridge.indicatorState)
            }

            if bridge.connectedPeerName != nil {
                Button(role: .destructive) {
                    bridge.disconnect()
                } label: {
                    Label("断开 Mac 桥接", systemImage: "xmark.circle")
                }
            } else if bridge.isAwaitingPairingConfirmation,
                      let sas = bridge.pairingSAS {
                pairingConfirmation(sas: sas, bridge: bridge)
            } else if bridge.discoveredPeers.isEmpty {
                Button {
                    bridge.refreshBrowsing()
                } label: {
                    Label("重新寻找 Mac", systemImage: "arrow.clockwise")
                }
            } else {
                ForEach(bridge.discoveredPeers) { peer in
                    Button {
                        do {
                            try bridge.connect(to: peer.id)
                        } catch {
                            appState.errorMessage = error.localizedDescription
                        }
                    } label: {
                        HStack {
                            Label(peer.name, systemImage: "laptopcomputer")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("首次连接会在两边显示同一个短码；确认一致后才会传输财务数据。")
                Text("桥接只在 F.I.R.E 保持前台时活跃；返回 App 后会自动重连。")
                Text("AI 报告要求 Mac 上的 Codex 使用 ChatGPT 账号登录，绝不回退到 Platform API。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("连接与 Codex")
        }
    }

    private func pairingConfirmation(
        sas: String,
        bridge: BridgeConnectionController
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("确认 Mac 也显示这个短码")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(sas)
                .font(.system(
                    size: 30,
                    weight: .semibold,
                    design: .monospaced
                ))
                .textSelection(.enabled)
            HStack {
                Button("两边一致，继续") {
                    do {
                        try bridge.confirmPairingSAS()
                    } catch {
                        appState.errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("不一致，取消", role: .destructive) {
                    bridge.rejectPairing()
                }
            }
        }
        .padding(.vertical, 4)
    }
}
