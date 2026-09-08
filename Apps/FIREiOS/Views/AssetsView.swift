import FIREBridgeKit
import PhotosUI
import SwiftUI

enum PhotoSelectionAccumulator {
    static func appendingUnique<Item: Equatable>(
        _ additions: [Item],
        to existing: [Item],
        identifier: (Item) -> String?
    ) -> [Item] {
        var merged = existing
        var knownIdentifiers = Set(existing.compactMap(identifier))

        for item in additions {
            if let identifier = identifier(item) {
                guard knownIdentifiers.insert(identifier).inserted else {
                    continue
                }
            } else {
                guard !merged.contains(item) else { continue }
            }
            merged.append(item)
        }

        return merged
    }
}

struct AssetsView: View {
    private enum CashField: Hashable {
        case cny
        case usd
        case hkd
    }

    @Environment(FIREAppState.self) private var appState
    let assetSnapshots: [AssetSnapshotEntity]
    let positions: [PositionSnapshotEntity]
    let instruments: [InstrumentEntity]
    let liabilities: [LiabilityEntity]
    @Binding var hidesNumbers: Bool
    let onOpenBridge: () -> Void

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photosToAdd: [PhotosPickerItem] = []
    @State private var snapshotDate = Date()
    @State private var cashCNY = 0.0
    @State private var cashUSD = 0.0
    @State private var cashHKD = 0.0
    @State private var confirmsCompleteSelection = false
    @State private var editingPosition: AggregatedPosition?
    @State private var editingLiability: LiabilityEntity?
    @State private var showingLiabilitySheet = false
    @State private var showingRateSheet = false
    @State private var showingAssetRecognitionRecoveryAlert = false
    @State private var showingCashAndLiabilitiesOnlyConfirmation = false
    @State private var showingManualPositionSheet = false
    @State private var editingSavedPosition: PositionSnapshotEntity?
    @State private var positionPendingDeletion: PositionSnapshotEntity?
    @State private var isSavingAssetSnapshot = false
    @State private var isSnapshotEntryExpanded = false
    @FocusState private var focusedCashField: CashField?

    private var privacyFormatter: FinancialPrivacyFormatter {
        FinancialPrivacyFormatter(hidesNumbers: hidesNumbers)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                currentNetWorthCard
                if isSnapshotEntryExpanded {
                    VStack(spacing: 16) {
                        cashAndLiabilitiesCard
                        screenshotImportCard
                        if !appState.aggregatedPositions.isEmpty {
                            recognizedProductsCard
                        }
                        snapshotConfirmationCard
                    }
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
                }
                instrumentsCard
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FIREPalette.paper.ignoresSafeArea())
        .navigationTitle("资产快照")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSnapshotEntryExpanded {
                    Button {
                        showingRateSheet = true
                    } label: {
                        Image(
                            systemName:
                                "arrow.left.arrow.right.circle.fill"
                        )
                    }
                    .accessibilityLabel("自动获取失败时填写手动汇率")
                }
                Button {
                    focusedCashField = nil
                    withAnimation(.snappy) {
                        isSnapshotEntryExpanded.toggle()
                    }
                } label: {
                    Text(
                        isSnapshotEntryExpanded
                            ? "收起"
                            : (hasPendingSnapshotEntry ? "继续填写" : "填写")
                    )
                }
                .accessibilityLabel(
                    isSnapshotEntryExpanded
                        ? "收起资产填写"
                        : "展开资产填写"
                )
                .accessibilityIdentifier("assets.snapshotEntry.toggle")
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                FinancialPrivacyButton(hidesNumbers: $hidesNumbers)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    focusedCashField = nil
                }
            }
        }
        .onChange(of: photosToAdd) { _, additions in
            guard !additions.isEmpty else { return }
            let existingCount = selectedPhotos.count
            let merged = PhotoSelectionAccumulator.appendingUnique(
                additions,
                to: selectedPhotos,
                identifier: \.itemIdentifier
            )
            photosToAdd = []
            guard merged != selectedPhotos else {
                appState.statusMessage = "这些截图已经添加过了。"
                return
            }

            let newlyAdded = Array(merged.dropFirst(existingCount))
            if existingCount > 0,
               !appState.appendAssetScreenshots(newlyAdded) {
                return
            }
            if existingCount == 0 {
                appState.recognizeAssetScreenshots(merged)
            }

            selectedPhotos = merged
            confirmsCompleteSelection = false
            editingPosition = nil
        }
        .onChange(of: appState.assetRecognitionBridgeIssue) { _, issue in
            if issue != nil {
                showingAssetRecognitionRecoveryAlert = true
            }
        }
        .onChange(of: latestSnapshot?.capturedAt) { _, _ in
            normalizeSnapshotDate()
        }
        .onAppear {
            normalizeSnapshotDate()
            if hasPendingSnapshotEntry {
                isSnapshotEntryExpanded = true
            }
        }
        .onChange(of: hasPendingSnapshotEntry) { _, hasPending in
            guard hasPending else { return }
            withAnimation(.snappy) {
                isSnapshotEntryExpanded = true
            }
        }
        .sheet(item: $editingPosition) { position in
            AggregatedPositionEditor(
                position: position,
                onSave: { name, code, kind, currency, marketValue in
                    appState.updateAggregatedPosition(
                        id: position.id,
                        name: name,
                        code: code,
                        kind: kind,
                        currency: currency,
                        originalMarketValue: marketValue
                    )
                }
            )
        }
        .sheet(isPresented: $showingManualPositionSheet) {
            if let latestSnapshot {
                SavedPositionEditor(
                    snapshot: latestSnapshot,
                    existingPosition: nil,
                    instrument: nil
                )
            }
        }
        .sheet(item: $editingSavedPosition) { position in
            if let latestSnapshot,
               let instrument = instrument(for: position) {
                SavedPositionEditor(
                    snapshot: latestSnapshot,
                    existingPosition: position,
                    instrument: instrument
                )
            }
        }
        .sheet(isPresented: $showingLiabilitySheet) {
            LiabilityEditor(existing: nil, liabilities: liabilities)
        }
        .sheet(item: $editingLiability) { liability in
            LiabilityEditor(existing: liability, liabilities: liabilities)
        }
        .sheet(isPresented: $showingRateSheet) {
            ManualRateEditor(snapshotDate: snapshotDate)
        }
        .alert(
            appState.assetRecognitionRequiresBridgeConnection
                ? "需要恢复 Mac 连接"
                : "截图识别未完成",
            isPresented: $showingAssetRecognitionRecoveryAlert
        ) {
            if appState.assetRecognitionRequiresBridgeConnection {
                Button("先去桥接") {
                    onOpenBridge()
                }
            } else {
                Button("重试 Codex") {
                    appState.retryAssetRecognitionWithBridge()
                }
            }
            if appState.canUseLocalAssetRecognitionFallback {
                Button("仍用本机识别") {
                    appState.useLocalAssetRecognitionFallback()
                }
            }
            Button("清空本次识别", role: .destructive) {
                clearImportedRecognition()
            }
            Button("稍后处理", role: .cancel) {}
        } message: {
            Text(
                (
                    appState.assetRecognitionRequiresBridgeConnection
                        ? "\(appState.assetRecognitionBridgeIssue ?? "Mac 连接暂不可用。") 完成桥接后会自动继续这批识别，无需重新选择截图。"
                        : "Mac 当前已连接。此次识别失败：\(appState.assetRecognitionBridgeIssue ?? "Codex 暂未返回可用结果。") 你可以直接重试。"
                )
                    + " "
                    + (
                        appState.canUseLocalAssetRecognitionFallback
                            ? "也可以确认采用本机基础识别。"
                            : "本机这次没有生成可用结果。"
                )
            )
        }
        .confirmationDialog(
            "确认只保存现金和负债？",
            isPresented: $showingCashAndLiabilitiesOnlyConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认并保存", role: .destructive) {
                saveAssetSnapshot(confirmsNoInvestmentPositions: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本次没有投资截图。继续后，现有基金、股票和期权会被标记为已清仓。")
        }
        .confirmationDialog(
            "删除本期持仓？",
            isPresented: Binding(
                get: { positionPendingDeletion != nil },
                set: { if !$0 { positionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let positionPendingDeletion,
                   let latestSnapshot {
                    _ = appState.deletePositionFromLatestSnapshot(
                        positionPendingDeletion,
                        snapshot: latestSnapshot
                    )
                }
                positionPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                positionPendingDeletion = nil
            }
        } message: {
            Text("只会删除最新资产快照中的这项持仓，历史快照不会改动。")
        }
    }

    private var latestSnapshot: AssetSnapshotEntity? {
        assetSnapshots.max(by: { lhs, rhs in
            if lhs.capturedAt == rhs.capturedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.capturedAt < rhs.capturedAt
        })
    }

    private var latestPositions: [PositionSnapshotEntity] {
        guard let latestSnapshot else { return [] }
        return positions.filter { $0.assetSnapshotID == latestSnapshot.id }
    }

    private func instrument(
        for position: PositionSnapshotEntity
    ) -> InstrumentEntity? {
        instruments.first { $0.id == position.instrumentID }
    }

    private func currentPosition(
        for instrument: InstrumentEntity
    ) -> PositionSnapshotEntity? {
        latestPositions.first { $0.instrumentID == instrument.id }
    }

    private var earliestAllowedSnapshotDate: Date {
        let calendar = Calendar.current
        guard let latestSnapshot else {
            return calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))
                ?? Date(timeIntervalSince1970: 0)
        }
        return calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: latestSnapshot.capturedAt)
        ) ?? .now
    }

    private var canCreateSnapshotToday: Bool {
        earliestAllowedSnapshotDate <= Date()
    }

    private var hasSavableAssetInput: Bool {
        (
            appState.isAssetRecognitionBatchValid
                && confirmsCompleteSelection
        )
            || canSaveCashAndLiabilitiesOnly
    }

    private var hasPendingSnapshotEntry: Bool {
        !selectedPhotos.isEmpty
            || !photosToAdd.isEmpty
            || cashCNY != 0
            || cashUSD != 0
            || cashHKD != 0
            || confirmsCompleteSelection
            || appState.assetRecognitionImageCount > 0
            || !appState.ocrCandidates.isEmpty
            || !appState.aggregatedPositions.isEmpty
            || appState.assetRecognitionState != .idle
            || appState.assetRecognitionBridgeIssue != nil
    }

    private var canSaveCashAndLiabilitiesOnly: Bool {
        selectedPhotos.isEmpty
            && appState.assetRecognitionState == .idle
            && appState.assetRecognitionImageCount == 0
            && appState.ocrCandidates.isEmpty
            && appState.aggregatedPositions.isEmpty
            && (
                cashCNY > 0
                    || cashUSD > 0
                    || cashHKD > 0
                    || liabilities.contains { $0.remainingPrincipal > 0 }
            )
    }

    private var hasActiveInvestmentProducts: Bool {
        instruments.contains {
            $0.isActive && $0.kind != .cash
        }
    }

    private func matchingInstruments(
        for position: AggregatedPosition
    ) -> [InstrumentEntity] {
        instruments
            .filter {
                $0.kind == position.kind
                    && $0.currency.uppercased() == position.currency.uppercased()
            }
            .sorted {
                if $0.isActive != $1.isActive {
                    return $0.isActive
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private func resolutionLabel(for position: AggregatedPosition) -> String {
        switch appState.uncodedPositionResolutions[position.id] {
        case let .existingInstrument(instrumentID)?:
            let name = instruments.first(where: { $0.id == instrumentID })?.name
                ?? "已失效产品"
            return "归属：\(name)"
        case .createNewInstrument?:
            return "归属：明确新建产品"
        case let .batchCanonical(targetID)?:
            let target = appState.aggregatedPositions.first {
                $0.id == targetID
            }
            return target.map {
                "归属：合并到本批“\($0.name)”"
            } ?? "归属：同批主项已失效"
        case nil:
            return "选择产品归属"
        }
    }

    private func normalizeSnapshotDate() {
        guard canCreateSnapshotToday else {
            snapshotDate = .now
            return
        }
        if snapshotDate < earliestAllowedSnapshotDate {
            snapshotDate = earliestAllowedSnapshotDate
        } else if snapshotDate > Date() {
            snapshotDate = .now
        }
    }

    private func clearImportedRecognition() {
        photosToAdd = []
        selectedPhotos = []
        confirmsCompleteSelection = false
        editingPosition = nil
        appState.clearAssetRecognition()
    }

    private var currentNetWorthCard: some View {
        FIRECard {
            if let latestSnapshot {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("可投资净资产")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                privacyFormatter.value(
                                    latestSnapshot.investableNetWorth.cnyText
                                )
                            )
                                .font(.system(.largeTitle, design: .serif, weight: .bold))
                        }
                        Spacer()
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title)
                            .foregroundStyle(FIREPalette.moss)
                    }
                    HStack {
                        MetricLabel(
                            title: "产品",
                            value: privacyFormatter.value(
                                latestSnapshot.positionsCNY.cnyText
                            )
                        )
                        Spacer()
                        MetricLabel(
                            title: "现金",
                            value: privacyFormatter.value(
                                latestSnapshot.cashValueInCNY.cnyText
                            )
                        )
                        Spacer()
                        MetricLabel(
                            title: "负债",
                            value: privacyFormatter.value(
                                latestSnapshot.liabilityPrincipalCNY.cnyText
                            )
                        )
                    }
                    Text("快照日期 \(latestSnapshot.capturedAt.formatted(date: .abbreviated, time: .omitted)) · \(ExchangeRateState(rawValue: latestSnapshot.exchangeRateStateRawValue)?.displayName ?? "汇率未知")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if abs(
                        liabilities.reduce(0) {
                            $0 + $1.cnyRemainingPrincipal
                        } - latestSnapshot.liabilityPrincipalCNY
                    ) >= 0.005 {
                        Label(
                            "负债清单已在快照后变化；保存新的完整快照后，首页才会采用新金额。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(FIREPalette.amber)
                    }
                }
            } else {
                EmptyState(
                    icon: "camera.viewfinder",
                    title: "还没有资产快照",
                    message: "选择全部资产截图并补充现金、负债后，就能算出真实 FIRE 距离。"
                )
            }
        }
    }

    private var screenshotImportCard: some View {
        let pickerTitle = selectedPhotos.isEmpty
            ? "选择多张截图"
            : "继续添加截图"

        return FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "text.viewfinder")
                        .font(.title2)
                        .foregroundStyle(FIREPalette.moss)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择本月全部资产截图").font(.headline)
                        Text("平台只是导入来源。首页和资产列表只展示产品。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                PhotosPicker(
                    selection: $photosToAdd,
                    maxSelectionCount: max(
                        1,
                        BridgeWire.maximumAssetImages - selectedPhotos.count
                    ),
                    matching: .images
                ) {
                    Label(
                        pickerTitle,
                        systemImage: "photo.stack"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(
                    appState.isWorking
                        || appState.assetRecognitionState
                            == .awaitingBridgeDecision
                        || (
                            !selectedPhotos.isEmpty
                                && appState.assetRecognitionState == .invalid
                        )
                        || selectedPhotos.count
                            >= BridgeWire.maximumAssetImages
                )

                if appState.assetRecognitionImageCount > 0 {
                    HStack {
                        Text(
                            "本月已选择 \(appState.assetRecognitionImageCount) 张截图"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FIREPalette.moss)
                        Spacer()
                        Button(role: .destructive) {
                            clearImportedRecognition()
                        } label: {
                            Label("全部清空", systemImage: "trash")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    Text("新增截图只识别新增内容；已有识别结果和手工修正会保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appState.assetRecognitionState == .awaitingBridgeDecision {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            appState.assetRecognitionRequiresBridgeConnection
                                ? "需要恢复 Mac 连接"
                                : "截图识别尚未完成",
                            systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FIREPalette.amber)
                        Text(
                            appState.assetRecognitionBridgeIssue
                                ?? "Mac/Codex 暂不可用。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack {
                            if appState.assetRecognitionRequiresBridgeConnection {
                                Button("先去桥接") {
                                    onOpenBridge()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(FIREPalette.moss)
                            } else {
                                Button("重试 Codex") {
                                    appState.retryAssetRecognitionWithBridge()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(FIREPalette.moss)
                            }
                            if appState.canUseLocalAssetRecognitionFallback {
                                Button("仍用本机识别") {
                                    appState.useLocalAssetRecognitionFallback()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .padding(12)
                    .background(
                        FIREPalette.amber.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
                Label(
                    appState.isWorking
                        ? "正在读字并请 Mac 上的 Codex 整理产品…"
                        : "设备端 Vision 读字，Codex 只接收文字和位置；原图不上传、不保存",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var recognizedProductsCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("识别结果").font(.headline)
                    Spacer()
                    Text("\(appState.aggregatedPositions.count) 个产品")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(appState.aggregatedPositions) { position in
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: position.kind.systemImage)
                                .foregroundStyle(FIREPalette.moss)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(position.name)
                                    .font(.subheadline.weight(.semibold))
                        Text([
                            position.code,
                            position.currency,
                            position.sourceCount > 1 ? "\(position.sourceCount) 条待确认汇总" : nil
                        ].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                verificationBadge(for: position)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(
                                    privacyFormatter.value(
                                        "\(position.currency) \(position.originalMarketValue.formatted(.number.precision(.fractionLength(2))))"
                                    )
                                )
                                    .font(.subheadline.monospacedDigit())
                                HStack(spacing: 6) {
                                    Button {
                                        editingPosition = position
                                    } label: {
                                        Label("修正", systemImage: "pencil")
                                    }
                                    .buttonStyle(.bordered)
                                    Button(role: .destructive) {
                                        appState.deleteAggregatedPosition(
                                            id: position.id
                                        )
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel("删除 \(position.name)")
                                }
                                .font(.caption.weight(.semibold))
                                .disabled(appState.isWorking)
                            }
                        }
                        if position.requiresConfirmation {
                            if position.code == nil {
                                Menu {
                                    Button("明确新建产品") {
                                        appState.setUncodedResolution(
                                            .createNewInstrument,
                                            positionID: position.id
                                        )
                                    }
                                    let matches = matchingInstruments(for: position)
                                    if !matches.isEmpty {
                                        Section("关联已有产品") {
                                            ForEach(matches) { instrument in
                                                Button(
                                                    [
                                                        instrument.name,
                                                        instrument.code,
                                                        instrument.isActive ? nil : "已清仓"
                                                    ]
                                                    .compactMap { $0 }
                                                    .joined(separator: " · ")
                                                ) {
                                                    appState.setUncodedResolution(
                                                        .existingInstrument(instrument.id),
                                                        positionID: position.id
                                                    )
                                                }
                                            }
                                        }
                                    }
                                    let batchTargets = appState.sameBatchMergeTargets(
                                        for: position
                                    )
                                    if !batchTargets.isEmpty {
                                        Section("与本批同名产品合并") {
                                            ForEach(batchTargets) { target in
                                                Button(
                                                    "合并到 \(target.name) · \(target.currency) \(target.originalMarketValue.formatted(.number.precision(.fractionLength(2))))"
                                                ) {
                                                    appState.setUncodedResolution(
                                                        .batchCanonical(target.id),
                                                        positionID: position.id
                                                    )
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Label(
                                        resolutionLabel(for: position),
                                        systemImage: "arrow.triangle.branch"
                                    )
                                }
                                .font(.caption.weight(.semibold))
                                .tint(FIREPalette.moss)
                                .disabled(appState.isWorking)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    Divider()
                }

                Text("名称和金额识别正确时，也可能因代码、产品类型或同名份额无法通过唯一校验；这不等于截图识别错误，可点“修正”核对后保存。无代码产品仍需明确关联已有、新建，或合并到本批同名主项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func verificationBadge(
        for position: AggregatedPosition
    ) -> some View {
        switch position.verification {
        case .verified:
            Label("联网已核验", systemImage: "checkmark.seal.fill")
                .foregroundStyle(FIREPalette.moss)
        case .manual:
            Label("已手动修正", systemImage: "pencil.circle.fill")
                .foregroundStyle(FIREPalette.moss)
        case .notApplicable:
            Label("无需产品核验", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("联网核验暂不可用，需修正", systemImage: "wifi.exclamationmark")
                .foregroundStyle(FIREPalette.amber)
        case .ambiguous:
            Label("联网找到多个可能产品，需修正", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(FIREPalette.amber)
        case .notFound:
            Label("联网未找到对应产品，需修正", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(FIREPalette.amber)
        case .localOnly:
            Label("仅本机识别，需修正", systemImage: "iphone")
                .foregroundStyle(FIREPalette.amber)
        }
    }

    private var snapshotConfirmationCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 14) {
                Text("完成月度快照").font(.headline)
                if canCreateSnapshotToday {
                    DatePicker(
                        "快照日期",
                        selection: $snapshotDate,
                        in: earliestAllowedSnapshotDate...Date(),
                        displayedComponents: .date
                    )
                } else {
                    Label(
                        "今天已有最新快照，请改天再创建新快照。",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .font(.subheadline)
                    .foregroundStyle(FIREPalette.amber)
                }
                Text("为避免旧数据改乱当前持仓，首版不支持同日重复或历史回填。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.isAssetRecognitionBatchValid {
                    Toggle("我已选择本月全部资产截图", isOn: $confirmsCompleteSelection)
                        .tint(FIREPalette.moss)
                        .disabled(
                            !appState.isAssetRecognitionBatchValid
                                || !canCreateSnapshotToday
                        )
                    Text("仅在你确认完整后，未出现在本月截图中的旧产品才会标记为已清仓。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if canSaveCashAndLiabilitiesOnly {
                    Text("未添加投资截图，将只保存本次填写的现金和负债。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("添加基金或股票截图，或者先填写现金、负债后再保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    if appState.isAssetRecognitionBatchValid {
                        saveAssetSnapshot(
                            confirmsNoInvestmentPositions: false
                        )
                    } else if canSaveCashAndLiabilitiesOnly {
                        if hasActiveInvestmentProducts {
                            showingCashAndLiabilitiesOnlyConfirmation = true
                        } else {
                            saveAssetSnapshot(
                                confirmsNoInvestmentPositions: true
                            )
                        }
                    }
                } label: {
                    Label("保存资产快照", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(
                    isSavingAssetSnapshot
                        || appState.isWorking
                        || !hasSavableAssetInput
                        || !canCreateSnapshotToday
                )
            }
        }
    }

    private func saveAssetSnapshot(
        confirmsNoInvestmentPositions: Bool
    ) {
        guard !isSavingAssetSnapshot else { return }
        isSavingAssetSnapshot = true
        Task {
            defer { isSavingAssetSnapshot = false }
            let saved = await appState.confirmAssetSnapshot(
                capturedAt: snapshotDate,
                cashCNY: max(cashCNY, 0),
                cashUSD: max(cashUSD, 0),
                cashHKD: max(cashHKD, 0),
                confirmsAllScreenshotsWereSelected: confirmsCompleteSelection,
                confirmsNoInvestmentPositions: confirmsNoInvestmentPositions,
                latestConfirmedSnapshotDate: latestSnapshot?.capturedAt,
                existingInstruments: instruments,
                liabilities: liabilities
            )
            if saved {
                photosToAdd = []
                selectedPhotos = []
                confirmsCompleteSelection = false
                cashCNY = 0
                cashUSD = 0
                cashHKD = 0
                withAnimation(.snappy) {
                    isSnapshotEntryExpanded = false
                }
            }
        }
    }

    private var instrumentsCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("产品中心").font(.headline)
                    Spacer()
                    Text("\(latestPositions.count) 项本期持仓")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if instruments.isEmpty {
                    Text("完成首个月度快照后，基金、股票和期权会在这里按产品汇总。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(instruments) { instrument in
                        let position = currentPosition(for: instrument)
                        HStack {
                            Image(systemName: instrument.kind.systemImage)
                                .foregroundStyle(instrument.isActive ? FIREPalette.moss : .secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(instrument.name)
                                    .foregroundStyle(instrument.isActive ? .primary : .secondary)
                                Text([instrument.code, instrument.currency]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let position {
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text(
                                        privacyFormatter.value(
                                            position.cnyMarketValue.cnyText
                                        )
                                    )
                                        .font(
                                            .subheadline
                                                .monospacedDigit()
                                                .weight(.semibold)
                                        )
                                    if isSnapshotEntryExpanded {
                                        HStack(spacing: 12) {
                                            Button {
                                                editingSavedPosition = position
                                            } label: {
                                                Image(systemName: "pencil")
                                                    .frame(
                                                        width: 44,
                                                        height: 44
                                                    )
                                            }
                                            .accessibilityLabel(
                                                "编辑 \(instrument.name)"
                                            )
                                            Button(role: .destructive) {
                                                positionPendingDeletion =
                                                    position
                                            } label: {
                                                Image(systemName: "trash")
                                                    .frame(
                                                        width: 44,
                                                        height: 44
                                                    )
                                            }
                                            .accessibilityLabel(
                                                "删除 \(instrument.name)"
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } else if !instrument.isActive {
                                Text("已清仓")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if isSnapshotEntryExpanded {
                    Button {
                        showingManualPositionSheet = true
                    } label: {
                        Label(
                            "手动补录资产或期权",
                            systemImage: "plus.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FIREPalette.moss)
                    .disabled(latestSnapshot == nil)
                    Text("可补录或修正最新快照；历史快照保持只读。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cashAndLiabilitiesCard: some View {
        FIRECard {
            VStack(alignment: .leading, spacing: 12) {
                Text("现金与负债").font(.headline)
                Text("本次快照现金")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Text("人民币")
                    Spacer()
                    TextField("0", value: $cashCNY, format: .number)
                        .keyboardType(.decimalPad)
                        .focused($focusedCashField, equals: .cny)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140)
                }
                DisclosureGroup("其他币种现金") {
                    HStack {
                        Text("USD")
                        Spacer()
                        TextField("0", value: $cashUSD, format: .number)
                            .keyboardType(.decimalPad)
                            .focused($focusedCashField, equals: .usd)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                    HStack {
                        Text("HKD")
                        Spacer()
                        TextField("0", value: $cashHKD, format: .number)
                            .keyboardType(.decimalPad)
                            .focused($focusedCashField, equals: .hkd)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                }
                Divider()
                HStack {
                    Text("未偿负债本金").font(.headline)
                    Spacer()
                    Text(
                        liabilities.reduce(0) {
                            $0 + $1.cnyRemainingPrincipal
                        }.cnyText
                    )
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                if liabilities.isEmpty {
                    Text("没有记录负债。FIRE 净资产会直接扣除未偿本金。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(liabilities) { liability in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(liability.name)
                                Text("\(liability.currency) \(liability.remainingPrincipal.formatted(.number))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(liability.cnyRemainingPrincipal.cnyText)
                                .font(.subheadline.monospacedDigit())
                            Button {
                                editingLiability = liability
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel("编辑 \(liability.name)")
                            Button(role: .destructive) {
                                appState.deleteLiability(liability)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                Button {
                    showingLiabilitySheet = true
                } label: {
                    Label("手动输入负债", systemImage: "minus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(FIREPalette.moss)
                Text("负债修改会立即保存；确认完整快照时会采用这里填写的现金和当前负债。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SavedPositionEditor: View {
    private enum Field: Hashable {
        case name
        case code
        case marketValue
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(FIREAppState.self) private var appState
    let snapshot: AssetSnapshotEntity
    let existingPosition: PositionSnapshotEntity?
    @State private var name: String
    @State private var code: String
    @State private var kind: AssetKind
    @State private var currency: String
    @State private var marketValue: Double
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    init(
        snapshot: AssetSnapshotEntity,
        existingPosition: PositionSnapshotEntity?,
        instrument: InstrumentEntity?
    ) {
        self.snapshot = snapshot
        self.existingPosition = existingPosition
        _name = State(initialValue: instrument?.name ?? "公司期权")
        _code = State(initialValue: instrument?.code ?? "")
        _kind = State(initialValue: instrument?.kind ?? .option)
        _currency = State(initialValue: instrument?.currency ?? "CNY")
        _marketValue = State(
            initialValue: existingPosition?.originalMarketValue ?? 0
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("产品") {
                    TextField("产品名称", text: $name)
                        .focused($focusedField, equals: .name)
                    TextField("产品代码（可留空）", text: $code)
                        .textInputAutocapitalization(.characters)
                        .focused($focusedField, equals: .code)
                    Picker("类型", selection: $kind) {
                        ForEach(
                            AssetKind.allCases.filter { $0 != .cash }
                        ) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    Picker("币种", selection: $currency) {
                        ForEach(["CNY", "USD", "HKD"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                Section {
                    TextField(
                        kind == .option ? "当前可实现净值" : "当前市值",
                        value: $marketValue,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .marketValue)
                } footer: {
                    if kind == .option {
                        Text(
                            "只填写已归属、可行权，并扣除行权成本和预估税费后愿意计入 FIRE 的价值。"
                        )
                    } else {
                        Text("外币资产保存时会采用该快照日期的汇率。")
                    }
                }
            }
            .navigationTitle(
                existingPosition == nil ? "补录资产" : "编辑本期持仓"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            let saved = await appState.saveManualPosition(
                                snapshot: snapshot,
                                existingPosition: existingPosition,
                                name: name,
                                code: code.nilIfEmpty,
                                kind: kind,
                                currency: currency,
                                originalMarketValue: marketValue
                            )
                            isSaving = false
                            if saved {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        isSaving
                            || appState.isWorking
                            || name.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                            || !marketValue.isFinite
                            || marketValue <= 0
                    )
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct AggregatedPositionEditor: View {
    private enum Field: Hashable {
        case name
        case code
        case marketValue
    }

    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String?, AssetKind, String, Double) -> Void
    @State private var name: String
    @State private var code: String
    @State private var kind: AssetKind
    @State private var currency: String
    @State private var marketValue: Double
    @FocusState private var focusedField: Field?

    init(
        position: AggregatedPosition,
        onSave: @escaping (String, String?, AssetKind, String, Double) -> Void
    ) {
        _name = State(initialValue: position.name)
        _code = State(initialValue: position.code ?? "")
        _kind = State(initialValue: position.kind)
        _currency = State(initialValue: position.currency)
        _marketValue = State(initialValue: position.originalMarketValue)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("产品名称", text: $name)
                    .focused($focusedField, equals: .name)
                TextField("产品代码（可留空）", text: $code)
                    .textInputAutocapitalization(.characters)
                    .focused($focusedField, equals: .code)
                Picker("类型", selection: $kind) {
                    ForEach(AssetKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("币种", selection: $currency) {
                    ForEach(["CNY", "USD", "HKD"], id: \.self) { Text($0).tag($0) }
                }
                TextField(
                    "市值",
                    value: $marketValue,
                    format: .number
                )
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .marketValue)
                Section {
                    Text("这里修改的是汇总后的产品，不再逐条显示或排除 OCR 明细。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("修正识别")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(
                            name,
                            code.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                            kind,
                            currency,
                            marketValue
                        )
                        dismiss()
                    }
                    .disabled(
                        name
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                            || !marketValue.isFinite
                            || marketValue <= 0
                    )
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct LiabilityEditor: View {
    private enum Field: Hashable {
        case name
        case principal
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(FIREAppState.self) private var appState
    let existing: LiabilityEntity?
    let liabilities: [LiabilityEntity]
    @State private var name: String
    @State private var currency: String
    @State private var principal: Double
    @FocusState private var focusedField: Field?

    init(existing: LiabilityEntity?, liabilities: [LiabilityEntity]) {
        self.existing = existing
        self.liabilities = liabilities
        _name = State(initialValue: existing?.name ?? "")
        _currency = State(initialValue: existing?.currency ?? "CNY")
        _principal = State(initialValue: existing?.remainingPrincipal ?? 0)
    }

    private var matchingExisting: LiabilityEntity? {
        guard existing == nil else { return nil }
        let normalizedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return liabilities.first {
            $0.currency.uppercased() == currency.uppercased()
                && $0.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
                )
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: "",
                    options: .regularExpression
                ) == normalizedName
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称，例如房贷", text: $name)
                    .focused($focusedField, equals: .name)
                Picker("币种", selection: $currency) {
                    ForEach(["CNY", "USD", "HKD"], id: \.self) { Text($0).tag($0) }
                }
                TextField("剩余本金", value: $principal, format: .number)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .principal)
                if currency != "CNY" {
                    Label(
                        "保存时自动获取 ECB 最近工作日汇率",
                        systemImage: "network"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let matchingExisting {
                    Label(
                        "将更新已有记录“\(matchingExisting.name)”，不会重复新增。",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(FIREPalette.amber)
                }
            }
            .navigationTitle(existing == nil ? "录入负债" : "编辑负债")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing != nil || matchingExisting != nil ? "确认更新" : "新增") {
                        Task {
                            let saved = await appState.saveLiability(
                                existing: existing,
                                name: name,
                                currency: currency,
                                principal: max(principal, 0)
                            )
                            if saved {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || principal <= 0
                            || appState.isWorking
                    )
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct ManualRateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FIREAppState.self) private var appState
    let snapshotDate: Date
    @State private var currency = "USD"
    @State private var rate = 0.0
    @FocusState private var isRateFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Picker("币种", selection: $currency) {
                    Text("USD").tag("USD")
                    Text("HKD").tag("HKD")
                }
                TextField("1 \(currency) = 人民币", value: $rate, format: .number)
                    .keyboardType(.decimalPad)
                    .focused($isRateFocused)
                Text("仅在 Mac 桥接、iPhone 直连 ECB 和本地缓存都不可用时使用；资产快照会明确标记为手动汇率。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("手动汇率")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        appState.saveManualRate(
                            currency: currency,
                            rateToCNY: rate,
                            snapshotDate: snapshotDate
                        )
                        dismiss()
                    }
                    .disabled(rate <= 0)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        isRateFocused = false
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
