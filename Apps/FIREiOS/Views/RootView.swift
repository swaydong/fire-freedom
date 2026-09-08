import SwiftData
import SwiftUI
import UIKit

enum PendingBridgeWork: Equatable {
    case asset(UUID)
    case report(UUID)
    case followUp(UUID)
}

enum PendingBridgeWorkSelector {
    static func next(
        assetOperationID: UUID?,
        assetIsAwaiting: Bool,
        lastAttemptedAssetID: UUID?,
        reportOperationID: UUID?,
        lastAttemptedReportID: UUID?,
        followUpOperationID: UUID? = nil,
        lastAttemptedFollowUpID: UUID? = nil,
        recoveringOperationIDs: Set<UUID> = [],
        isWorking: Bool,
        isSceneActive: Bool = true
    ) -> PendingBridgeWork? {
        guard isSceneActive, !isWorking else { return nil }
        if let assetOperationID,
           assetIsAwaiting,
           !recoveringOperationIDs.contains(assetOperationID),
           assetOperationID != lastAttemptedAssetID {
            return .asset(assetOperationID)
        }
        if let reportOperationID,
           !recoveringOperationIDs.contains(reportOperationID),
           reportOperationID != lastAttemptedReportID {
            return .report(reportOperationID)
        }
        if let followUpOperationID,
           !recoveringOperationIDs.contains(followUpOperationID),
           followUpOperationID != lastAttemptedFollowUpID {
            return .followUp(followUpOperationID)
        }
        return nil
    }
}

struct PendingBridgeRetryGate {
    private(set) var lastAttemptedAssetID: UUID?
    private(set) var lastAttemptedReportID: UUID?
    private(set) var lastAttemptedFollowUpID: UUID?

    mutating func beginConnectionCycle() {
        lastAttemptedAssetID = nil
        lastAttemptedReportID = nil
        lastAttemptedFollowUpID = nil
    }

    mutating func markAttempted(_ work: PendingBridgeWork) {
        switch work {
        case let .asset(operationID):
            lastAttemptedAssetID = operationID
        case let .report(operationID):
            lastAttemptedReportID = operationID
        case let .followUp(operationID):
            lastAttemptedFollowUpID = operationID
        }
    }
}

struct RootView: View {
    private enum Tab: Hashable {
        case freedom
        case transactions
        case assets
        case reports
        case settings
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(FIREAppState.self) private var appState
    @Environment(SessionLockController.self) private var lockController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FinancialPrivacy.storageKey) private var hidesNumbers = false
    @State private var selectedTab = Tab.freedom
    @State private var pendingExternalDocument: URL?
    @State private var bridgeRetryGate = PendingBridgeRetryGate()
    @State private var lastHandledResumableWorkRevision = 0

    @Query(sort: \TransactionEntity.transactionDate, order: .reverse)
    private var transactions: [TransactionEntity]
    @Query(sort: \AssetSnapshotEntity.capturedAt, order: .reverse)
    private var assetSnapshots: [AssetSnapshotEntity]
    @Query private var positions: [PositionSnapshotEntity]
    @Query(sort: \InstrumentEntity.name)
    private var instruments: [InstrumentEntity]
    @Query(sort: \LiabilityEntity.updatedAt, order: .reverse)
    private var liabilities: [LiabilityEntity]
    @Query private var settings: [FIRESettingsEntity]

    var body: some View {
        statusContent
    }

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView(
                    hidesNumbers: $hidesNumbers,
                    onOpenAssets: {
                        selectedTab = .assets
                    }
                )
            }
            .tabItem { Label("自由", systemImage: "sparkles") }
            .tag(Tab.freedom)

            NavigationStack {
                TransactionsView(
                    transactions: transactions,
                    hidesNumbers: $hidesNumbers
                )
            }
            .tabItem { Label("收支", systemImage: "list.bullet.rectangle") }
            .tag(Tab.transactions)

            NavigationStack {
                AssetsView(
                    assetSnapshots: assetSnapshots,
                    positions: positions,
                    instruments: instruments,
                    liabilities: liabilities,
                    hidesNumbers: $hidesNumbers,
                    onOpenBridge: {
                        selectedTab = .settings
                    }
                )
            }
            .tabItem { Label("资产", systemImage: "square.stack.3d.up.fill") }
            .tag(Tab.assets)

            NavigationStack {
                ReportsView(
                    transactions: transactions,
                    assetSnapshots: assetSnapshots,
                    positions: positions,
                    instruments: instruments,
                    liabilities: liabilities,
                    settings: settings,
                    onOpenBridge: {
                        selectedTab = .settings
                    }
                )
            }
            .tabItem { Label("分析", systemImage: "text.page.badge.magnifyingglass") }
            .tag(Tab.reports)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .tint(FIREPalette.accent)
        .overlay(alignment: .topLeading) {
            SettingsTabBadgeConfigurator(
                state: appState.bridge.indicatorState
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var dataRefreshContent: some View {
        tabContent
        .task {
            appState.configure(context: modelContext)
            appState.installBackgroundOperationRecoveryHandler()
            refresh()
            resumePendingBridgeWork()
        }
        .onChange(of: transactions.count) { _, _ in refresh() }
        .onChange(of: assetSnapshots.count) { _, _ in refresh() }
        .onChange(of: positions.count) { _, _ in refresh() }
        .onChange(of: liabilities.count) { _, _ in refresh() }
        .onChange(of: settings.first?.updatedAt) { _, _ in refresh() }
        .onChange(of: appState.dataRevision) { _, _ in refresh() }
    }

    private var recoveryContent: some View {
        dataRefreshContent
        .onChange(of: appState.bridge.connectedPeerName) { oldPeer, peerName in
            guard peerName != nil else { return }
            if oldPeer != peerName {
                bridgeRetryGate.beginConnectionCycle()
            }
            resumePendingBridgeWork()
        }
        .onChange(of: appState.resumableWorkRevision) { oldValue, newValue in
            guard newValue != oldValue,
                  scenePhase == .active,
                  appState.bridge.connectedPeerName != nil else {
                return
            }
            lastHandledResumableWorkRevision = newValue
            bridgeRetryGate.beginConnectionCycle()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            appState.bridge.startBrowsing()
            if lastHandledResumableWorkRevision
                != appState.resumableWorkRevision {
                lastHandledResumableWorkRevision =
                    appState.resumableWorkRevision
                bridgeRetryGate.beginConnectionCycle()
            }
            resumePendingBridgeWork()
        }
        .onChange(of: lockController.isLocked) { _, isLocked in
            guard !isLocked, let url = pendingExternalDocument else {
                return
            }
            pendingExternalDocument = nil
            handleExternalDocument(url)
        }
    }

    private var statusContent: some View {
        recoveryContent
        .onOpenURL { url in
            if lockController.isLocked {
                pendingExternalDocument = url
            } else {
                handleExternalDocument(url)
            }
        }
        .alert(
            "需要处理",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )
        ) {
            Button("知道了") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .overlay(alignment: .top) {
            if let message = appState.statusMessage {
                StatusToast(message: message) {
                    appState.statusMessage = nil
                }
                .padding(.top, 8)
            }
        }
    }

    private func refresh() {
        appState.refresh(
            transactions: transactions,
            assetSnapshots: assetSnapshots,
            positions: positions,
            instruments: instruments,
            liabilities: liabilities,
            settings: settings
        )
    }

    private func resumePendingBridgeWork() {
        guard scenePhase == .active,
              appState.bridge.connectedPeerName != nil else {
            return
        }

        let operationIDs = [
            appState.pendingAssetRecognitionOperationID,
            appState.pendingReportOperationID,
            appState.pendingFollowUpOperationID,
        ].compactMap { $0 }
        let recoveringOperationIDs = Set(operationIDs.filter {
            BackgroundOperationController.shared.isRecovering(
                operationID: $0
            )
        })
        let nextWork = PendingBridgeWorkSelector.next(
            assetOperationID: appState.pendingAssetRecognitionOperationID,
            assetIsAwaiting:
                appState.assetRecognitionState == .awaitingBridgeDecision,
            lastAttemptedAssetID: bridgeRetryGate.lastAttemptedAssetID,
            reportOperationID: appState.pendingReportOperationID,
            lastAttemptedReportID: bridgeRetryGate.lastAttemptedReportID,
            followUpOperationID: appState.pendingFollowUpOperationID,
            lastAttemptedFollowUpID:
                bridgeRetryGate.lastAttemptedFollowUpID,
            recoveringOperationIDs: recoveringOperationIDs,
            isWorking: appState.isWorking,
            isSceneActive: scenePhase == .active
        )
        guard let nextWork else { return }
        bridgeRetryGate.markAttempted(nextWork)
        switch nextWork {
        case .asset:
            appState.retryAssetRecognitionWithBridge()
        case .report:
            Task {
                await appState.generateReport(
                    startsBackgroundActivity: false,
                    transactions: transactions,
                    assetSnapshots: assetSnapshots,
                    positions: positions,
                    instruments: instruments,
                    liabilities: liabilities,
                    settings: settings
                )
            }
        case .followUp:
            Task {
                await appState.resumePersistedFollowUp()
            }
        }
    }

    private func handleExternalDocument(_ url: URL) {
        guard url.isFileURL else {
            appState.errorMessage = "只能导入本机文件。"
            return
        }

        switch url.pathExtension.lowercased() {
        case "xlsx":
            appState.configure(context: modelContext)
            selectedTab = .transactions
            appState.prepareKapiSync(at: url)
        case "firebackup":
            selectedTab = .settings
            appState.statusMessage = "请在“设置”中选择“从加密备份恢复”。"
        default:
            appState.errorMessage = "F.I.R.E 暂不支持这种文件格式。"
        }
    }
}

private struct SettingsTabBadgeConfigurator: UIViewRepresentable {
    let state: BridgeConnectionIndicatorState

    func makeUIView(context: Context) -> SettingsTabBadgeView {
        let view = SettingsTabBadgeView()
        view.state = state
        return view
    }

    func updateUIView(
        _ uiView: SettingsTabBadgeView,
        context: Context
    ) {
        uiView.state = state
    }
}

private final class SettingsTabBadgeView: UIView {
    var state = BridgeConnectionIndicatorState.disconnected {
        didSet { applyBadge() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyBadge()
    }

    private func applyBadge() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window,
                  let tabBar = Self.findTabBar(in: window),
                  let settingsItem = tabBar.items?.last else {
                return
            }
            settingsItem.badgeValue = self.state.tabBadgeValue
            settingsItem.badgeColor = self.state.tabBadgeColor
            settingsItem.setBadgeTextAttributes(
                [.foregroundColor: UIColor.white],
                for: .normal
            )
            settingsItem.accessibilityValue = "Mac 桥接\(self.state.title)"
        }
    }

    private static func findTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar {
            return tabBar
        }
        for subview in view.subviews {
            if let tabBar = findTabBar(in: subview) {
                return tabBar
            }
        }
        return nil
    }
}

struct LockScreenView: View {
    @Environment(SessionLockController.self) private var lockController

    var body: some View {
        ZStack {
            FIREPalette.paper.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(FIREPalette.textInk)
                VStack(spacing: 7) {
                    Text("F.I.R.E")
                        .font(.system(.title, design: .serif, weight: .bold))
                    Text("你的财务数据已锁定")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await lockController.unlock() }
                } label: {
                    Label(
                        lockController.isAuthenticating ? "正在验证…" : "使用 Face ID 解锁",
                        systemImage: "faceid"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(lockController.isAuthenticating)
                .frame(maxWidth: 300)

                if let error = lockController.authenticationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
            }
            .padding(32)
        }
    }
}
