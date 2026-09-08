import CryptoKit
import FIREBridgeKit
import FIRECore
import Foundation
import Observation
import PhotosUI
import SwiftData
import SwiftUI

@MainActor
@Observable
final class FIREAppState {
    private struct PendingAssetRecognition {
        let operationID: UUID
        let batchID: UUID
        let result: AssetOCRRecognitionResult
        let imageIndexOffset: Int?
    }

    private struct PendingReportOperation {
        let reportID: UUID
        let packetSignature: Data
        let packet: FIRECore.AnalysisPacketV1
    }

    private struct PendingFollowUpKey: Hashable {
        let reportID: UUID
        let question: String
    }

    private struct BackgroundRecoveryTask {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var context: ModelContext?
    private let ocrService = AssetOCRService()
    private let aggregationService = PositionAggregationService()
    private let fxService = ECBExchangeRateService()
    private let pendingOperationStore: PendingOperationStore
    @ObservationIgnored private var assetRecognitionTask: Task<Void, Never>?
    @ObservationIgnored private var assetRecognitionTaskID: UUID?
    @ObservationIgnored private var activeOCRBatchID: UUID?
    @ObservationIgnored
    private var pendingAssetRecognition: PendingAssetRecognition?
    @ObservationIgnored private var ocrCandidateRevision = 0
    @ObservationIgnored private var pendingReportOperation: PendingReportOperation?
    @ObservationIgnored private(set)
    var persistedReportOperation: PendingReportOperationRecordV1?
    @ObservationIgnored private var activeAssetBackgroundOperationID: UUID?
    @ObservationIgnored
    private var pendingFollowUpOperations: [PendingFollowUpKey: UUID] = [:]
    @ObservationIgnored private(set)
    var persistedFollowUpOperation: PendingFollowUpOperationRecordV1?
    @ObservationIgnored
    private var activeReportRequest: Task<ReportGeneratedResponseV1, Error>?
    @ObservationIgnored private var activeReportRequestID: UUID?
    @ObservationIgnored
    private var activeFollowUpRequest: Task<AnswerGeneratedResponseV1, Error>?
    @ObservationIgnored private var activeFollowUpRequestID: UUID?
    @ObservationIgnored
    private var backgroundRecoveryTasks: [UUID: BackgroundRecoveryTask] = [:]
    @ObservationIgnored
    private var statusMessageDismissTask: Task<Void, Never>?
    private let statusMessageVisibilityDuration: Duration

    let bridge = BridgeConnectionController()

    var dashboard = DashboardSnapshot.empty
    var importSummary: ImportSummary?
    private(set) var pendingKapiSync: KapiSyncPreview?
    private(set) var latestKapiSyncReceipt: KapiSyncReceipt?
    var ocrCandidates: [OCRPositionCandidate] = []
    var aggregatedPositions: [AggregatedPosition] = []
    var confirmedPositionIDs: Set<String> = []
    var uncodedPositionResolutions: [String: UncodedPositionResolution] = [:]
    private(set) var isAssetRecognitionBatchValid = false
    private(set) var assetRecognitionState = AssetRecognitionState.idle
    private(set) var assetRecognitionImageCount = 0
    private(set) var assetRecognitionBridgeIssue: String?
    private(set) var assetRecognitionRequiresBridgeConnection = false
    private(set) var canUseLocalAssetRecognitionFallback = false
    var lastExchangeQuote: FXQuote?
    var isWorking = false
    var statusMessage: String? {
        didSet { scheduleStatusMessageDismissal() }
    }
    var errorMessage: String?
    private(set) var dataRevision = 0
    private(set) var resumableWorkRevision = 0

    init(
        pendingOperationStore: PendingOperationStore = .live(),
        statusMessageVisibilityDuration: Duration = .seconds(5)
    ) {
        self.pendingOperationStore = pendingOperationStore
        self.statusMessageVisibilityDuration =
            statusMessageVisibilityDuration
        restorePendingOperations()
    }

    private func scheduleStatusMessageDismissal() {
        statusMessageDismissTask?.cancel()
        guard statusMessage != nil else {
            statusMessageDismissTask = nil
            return
        }

        let presentedMessage = statusMessage
        let visibilityDuration = statusMessageVisibilityDuration
        statusMessageDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: visibilityDuration)
            } catch {
                return
            }
            guard let self,
                  self.statusMessage == presentedMessage else {
                return
            }
            self.statusMessage = nil
        }
    }

    var pendingAssetRecognitionOperationID: UUID? {
        pendingAssetRecognition?.operationID
    }

    var pendingReportOperationID: UUID? {
        persistedReportOperation?.reportID
    }

    var pendingFollowUpOperationID: UUID? {
        persistedFollowUpOperation?.operationID
    }

    func canRecoverBackgroundOperation(_ operationID: UUID) -> Bool {
        pendingAssetRecognitionOperationID == operationID
            || pendingReportOperationID == operationID
            || pendingFollowUpOperationID == operationID
    }

    func installBackgroundOperationRecoveryHandler() {
        let backgroundController = BackgroundOperationController.shared
        for descriptor in backgroundController.recoverableOperations
        where !canRecoverBackgroundOperation(descriptor.id) {
            backgroundController.updateProgress(
                operationID: descriptor.id,
                completedUnitCount: descriptor.totalUnitCount,
                totalUnitCount: descriptor.totalUnitCount,
                subtitle: "任务已收尾"
            )
            backgroundController.finish(
                operationID: descriptor.id,
                success: true
            )
        }
        backgroundController.setRecoveryHandler {
            [weak self] descriptor in
            guard let self else {
                BackgroundOperationController.shared.finish(
                    operationID: descriptor.id,
                    success: true
                )
                return
            }
            guard canRecoverBackgroundOperation(descriptor.id) else {
                BackgroundOperationController.shared.finish(
                    operationID: descriptor.id,
                    success: true
                )
                return
            }
            startBackgroundRecovery(for: descriptor)
        }
    }

    private func startBackgroundRecovery(
        for descriptor: BackgroundOperationController.OperationDescriptor
    ) {
        let operationID = descriptor.id
        backgroundRecoveryTasks[operationID]?.task.cancel()
        bridge.startBrowsing()

        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if backgroundRecoveryTasks[operationID]?.token == token {
                    backgroundRecoveryTasks[operationID] = nil
                }
            }
            do {
                try await waitForBridgeConnection()
                try await waitUntilIdle()
                try Task.checkCancellation()

                if pendingAssetRecognitionOperationID == operationID {
                    guard assetRecognitionState == .awaitingBridgeDecision else {
                        finishBackgroundProtection(
                            operationID: operationID,
                            success: false
                        )
                        return
                    }
                    retryAssetRecognitionWithBridge()
                    return
                }

                if pendingFollowUpOperationID == operationID {
                    await resumePersistedFollowUp()
                    return
                }

                guard pendingReportOperationID == operationID,
                      let context else {
                    finishBackgroundProtection(
                        operationID: operationID,
                        success: false
                    )
                    return
                }
                let transactions = try context.fetch(
                    FetchDescriptor<TransactionEntity>()
                )
                let assetSnapshots = try context.fetch(
                    FetchDescriptor<AssetSnapshotEntity>()
                )
                let positions = try context.fetch(
                    FetchDescriptor<PositionSnapshotEntity>()
                )
                let instruments = try context.fetch(
                    FetchDescriptor<InstrumentEntity>()
                )
                let liabilities = try context.fetch(
                    FetchDescriptor<LiabilityEntity>()
                )
                let settings = try context.fetch(
                    FetchDescriptor<FIRESettingsEntity>()
                )
                await generateReport(
                    startsBackgroundActivity: false,
                    transactions: transactions,
                    assetSnapshots: assetSnapshots,
                    positions: positions,
                    instruments: instruments,
                    liabilities: liabilities,
                    settings: settings
                )
            } catch is CancellationError {
                finishBackgroundProtection(
                    operationID: operationID,
                    success: false
                )
            } catch {
                finishBackgroundProtection(
                    operationID: operationID,
                    success: false
                )
                errorMessage =
                    "后台恢复未完成：\(error.localizedDescription) 打开 F.I.R.E 后会继续保留待办。"
            }
        }
        backgroundRecoveryTasks[operationID] = BackgroundRecoveryTask(
            token: token,
            task: task
        )
        BackgroundOperationController.shared.attachRecoveryExpirationHandler(
            operationID: operationID,
            completesSuccessfully: true
        ) { [weak self] in
            self?.backgroundRecoveryTasks[operationID]?.task.cancel()
        }
    }

    private func waitForBridgeConnection() async throws {
        while bridge.connectedPeerName == nil {
            try Task.checkCancellation()
            bridge.startBrowsing()
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func waitUntilIdle() async throws {
        while isWorking {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func requestReport(
        reportID: UUID,
        packet: FIRECore.AnalysisPacketV1
    ) async throws -> ReportGeneratedResponseV1 {
        let request = Task {
            try await bridge.generateReport(
                reportID: reportID,
                packet: packet
            )
        }
        activeReportRequest?.cancel()
        activeReportRequestID = reportID
        activeReportRequest = request
        defer {
            if activeReportRequestID == reportID {
                activeReportRequestID = nil
                activeReportRequest = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
    }

    private func cancelReportRequest(reportID: UUID) {
        guard activeReportRequestID == reportID else { return }
        activeReportRequest?.cancel()
    }

    private func requestFollowUp(
        operationID: UUID,
        reportID: UUID,
        question: String
    ) async throws -> AnswerGeneratedResponseV1 {
        let request = Task {
            try await bridge.followUp(
                operationID: operationID,
                reportID: reportID,
                question: question
            )
        }
        activeFollowUpRequest?.cancel()
        activeFollowUpRequestID = operationID
        activeFollowUpRequest = request
        defer {
            if activeFollowUpRequestID == operationID {
                activeFollowUpRequestID = nil
                activeFollowUpRequest = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
    }

    private func cancelFollowUpRequest(operationID: UUID) {
        guard activeFollowUpRequestID == operationID else { return }
        activeFollowUpRequest?.cancel()
    }

    func configure(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        reloadKapiSyncReceipt()
    }

    func reloadKapiSyncReceipt() {
        guard let context else { return }
        do {
            latestKapiSyncReceipt = try KapiSyncService(
                context: context
            ).latestReceipt()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh(
        transactions: [TransactionEntity],
        assetSnapshots: [AssetSnapshotEntity],
        positions: [PositionSnapshotEntity],
        instruments: [InstrumentEntity],
        liabilities: [LiabilityEntity],
        settings: [FIRESettingsEntity]
    ) {
        guard let context else { return }
        let completeAssetSnapshots = assetSnapshots.filter(\.isComplete)
        let latest = completeAssetSnapshots.max(by: Self.snapshotIsEarlier)
        dashboard = CoreDataAdapter(context: context).dashboard(
            transactions: transactions,
            latestAssetSnapshot: latest,
            assetSnapshots: completeAssetSnapshots,
            allPositions: positions,
            instruments: instruments,
            liabilities: liabilities,
            settings: settings.first
        )
    }

    func prepareKapiSync(at url: URL) {
        guard let context else { return }
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            pendingKapiSync = try KapiSyncService(
                context: context
            ).previewWorkbook(at: url)
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    func cancelKapiSyncPreview() {
        guard !isWorking else { return }
        pendingKapiSync = nil
    }

    func confirmKapiSync(
        previewID: UUID,
        confirmsCompleteUnfilteredExport: Bool
    ) {
        guard let context,
              let preview = pendingKapiSync,
              preview.id == previewID,
              !isWorking else {
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try KapiSyncService(context: context).apply(
                preview,
                confirmsCompleteUnfilteredExport:
                    confirmsCompleteUnfilteredExport
            )
            importSummary = result.summary
            latestKapiSyncReceipt = result.receipt
            pendingKapiSync = nil
            dataRevision &+= 1
            statusMessage =
                "账单同步完成：新增 \(result.receipt.addedCount) 笔，移除 \(result.receipt.removedCount) 笔。"
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    func undoLastKapiSync() {
        guard let context, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            latestKapiSyncReceipt = try KapiSyncService(
                context: context
            ).undoLatest()
            importSummary = nil
            dataRevision &+= 1
            statusMessage = "最近一次咔皮账单同步已撤回。"
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    func keepSuspectedDuplicate(_ transaction: TransactionEntity) {
        guard let context else { return }
        transaction.isSuspectedDuplicate = false
        do {
            try context.save()
            dataRevision &+= 1
            statusMessage = "这笔流水已确认为真实支出，会重新进入 FIRE 计算。"
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    func notifyDataChanged() {
        dataRevision &+= 1
    }

    @discardableResult
    private func beginBackgroundProtection(
        operationID: UUID,
        title: String,
        subtitle: String,
        completesSuccessfullyOnExpiration: Bool = false,
        onExpiration: BackgroundOperationController.ExpirationHandler? = nil
    ) -> Bool {
        do {
            _ = try BackgroundOperationController.shared.begin(
                operationID: operationID,
                title: title,
                subtitle: subtitle,
                completesSuccessfullyOnExpiration:
                    completesSuccessfullyOnExpiration,
                onExpiration: onExpiration
            )
            return true
        } catch {
            // The foreground operation remains valid even when the system
            // declines extra background runtime.
            return false
        }
    }

    private func updateBackgroundProgress(
        operationID: UUID,
        completed: Int64,
        subtitle: String
    ) {
        BackgroundOperationController.shared.updateProgress(
            operationID: operationID,
            completedUnitCount: completed,
            subtitle: subtitle
        )
    }

    private func finishBackgroundProtection(
        operationID: UUID,
        success: Bool
    ) {
        BackgroundOperationController.shared.finish(
            operationID: operationID,
            success: success
        )
    }

    func recognizeAssetScreenshots(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else {
            resetAssetRecognitionState()
            return
        }
        guard items.count <= BridgeWire.maximumAssetImages else {
            errorMessage = "一次最多添加 \(BridgeWire.maximumAssetImages) 张资产截图。"
            return
        }

        beginAssetRecognition(items, imageIndexOffset: nil)
    }

    @discardableResult
    func appendAssetScreenshots(_ items: [PhotosPickerItem]) -> Bool {
        guard !items.isEmpty else { return false }
        guard assetRecognitionState == .valid,
              activeOCRBatchID != nil,
              !ocrCandidates.isEmpty else {
            errorMessage = "请先完成当前截图识别，再继续添加截图。"
            return false
        }
        guard assetRecognitionTask == nil else {
            errorMessage = "新增截图正在识别，请完成后再继续添加。"
            return false
        }
        guard assetRecognitionImageCount + items.count
                <= BridgeWire.maximumAssetImages else {
            errorMessage = "一次最多添加 \(BridgeWire.maximumAssetImages) 张资产截图。"
            return false
        }

        beginAssetRecognition(
            items,
            imageIndexOffset: assetRecognitionImageCount
        )
        return true
    }

    private func beginAssetRecognition(
        _ items: [PhotosPickerItem],
        imageIndexOffset: Int?
    ) {
        if imageIndexOffset == nil {
            resetAssetRecognitionState()
        } else {
            pendingAssetRecognition = nil
            assetRecognitionBridgeIssue = nil
            assetRecognitionRequiresBridgeConnection = false
            canUseLocalAssetRecognitionFallback = false
            isAssetRecognitionBatchValid = false
        }

        let batchID = UUID()
        let operationID = UUID()
        activeOCRBatchID = batchID
        assetRecognitionImageCount = (imageIndexOffset ?? 0) + items.count
        assetRecognitionState = .recognizing
        errorMessage = nil
        statusMessage = nil
        isWorking = true
        activeAssetBackgroundOperationID = operationID
        beginBackgroundProtection(
            operationID: operationID,
            title: "F.I.R.E 正在识别资产",
            subtitle: "正在安全读取资产截图"
        ) { [weak self] in
            self?.assetRecognitionTask?.cancel()
        }
        updateBackgroundProgress(
            operationID: operationID,
            completed: 5,
            subtitle: "正在安全读取资产截图"
        )
        let taskID = UUID()
        assetRecognitionTaskID = taskID
        assetRecognitionTask = Task { [weak self] in
            guard let self else { return }
            var completedSuccessfully = false
            defer {
                finishBackgroundProtection(
                    operationID: operationID,
                    success: completedSuccessfully
                )
                if activeAssetBackgroundOperationID == operationID {
                    activeAssetBackgroundOperationID = nil
                }
                finishAssetRecognitionTask(
                    taskID: taskID,
                    batchID: batchID,
                    wasCancelled: Task.isCancelled
                )
            }
            do {
                let localResult = try await ocrService.recognize(items: items)
                guard !Task.isCancelled, activeOCRBatchID == batchID else {
                    return
                }
                updateBackgroundProgress(
                    operationID: operationID,
                    completed: 55,
                    subtitle: "本机读字完成，正在连接 Mac"
                )
                let pending = PendingAssetRecognition(
                    operationID: operationID,
                    batchID: batchID,
                    result: localResult,
                    imageIndexOffset: imageIndexOffset
                )
                pendingAssetRecognition = pending
                persistAssetRecognition(pending)
                do {
                    updateBackgroundProgress(
                        operationID: operationID,
                        completed: 65,
                        subtitle: "Mac 上的 Codex 正在整理资产"
                    )
                    let response = try await bridge.recognizeAssets(
                        operationID: operationID,
                        imageCount: localResult.imageCount,
                        lines: localResult.lines
                    )
                    try Task.checkCancellation()
                    let codexCandidates = response.positions.map {
                        makeOCRCandidate(from: $0)
                    }
                    guard !codexCandidates.isEmpty else {
                        throw BridgeConnectionError.invalidResponse
                    }
                    updateBackgroundProgress(
                        operationID: operationID,
                        completed: 90,
                        subtitle: "正在核对并汇总产品"
                    )
                    applyAssetRecognitionCandidates(
                        codexCandidates,
                        batchID: batchID,
                        imageIndexOffset: imageIndexOffset,
                        description: "Vision 读字 + Codex 整理"
                    )
                    updateBackgroundProgress(
                        operationID: operationID,
                        completed: 100,
                        subtitle: "资产识别已完成"
                    )
                    completedSuccessfully = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard activeOCRBatchID == batchID else { return }
                    holdAssetRecognitionForRecovery(
                        pending,
                        error: error
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard activeOCRBatchID == batchID else { return }
                handleAssetRecognitionFailure(
                    error,
                    imageIndexOffset: imageIndexOffset
                )
            }
        }
    }

    func retryAssetRecognitionWithBridge() {
        guard let pending = pendingAssetRecognition,
              activeOCRBatchID == pending.batchID else {
            errorMessage = "没有可以重试的截图识别数据，请重新选择截图。"
            return
        }

        guard assetRecognitionTask == nil else { return }
        assetRecognitionBridgeIssue = nil
        assetRecognitionRequiresBridgeConnection = false
        canUseLocalAssetRecognitionFallback = false
        assetRecognitionState = .recognizing
        errorMessage = nil
        statusMessage = nil
        isWorking = true
        activeAssetBackgroundOperationID = pending.operationID
        beginBackgroundProtection(
            operationID: pending.operationID,
            title: "F.I.R.E 正在识别资产",
            subtitle: "正在从 Mac 领取识别结果"
        ) { [weak self] in
            self?.assetRecognitionTask?.cancel()
        }
        updateBackgroundProgress(
            operationID: pending.operationID,
            completed: 65,
            subtitle: "正在从 Mac 领取识别结果"
        )

        let taskID = UUID()
        assetRecognitionTaskID = taskID
        assetRecognitionTask = Task { [weak self] in
            guard let self else { return }
            var completedSuccessfully = false
            defer {
                finishBackgroundProtection(
                    operationID: pending.operationID,
                    success: completedSuccessfully
                )
                if activeAssetBackgroundOperationID == pending.operationID {
                    activeAssetBackgroundOperationID = nil
                }
                finishAssetRecognitionTask(
                    taskID: taskID,
                    batchID: pending.batchID,
                    wasCancelled: Task.isCancelled
                )
            }
            do {
                let response = try await bridge.recognizeAssets(
                    operationID: pending.operationID,
                    imageCount: pending.result.imageCount,
                    lines: pending.result.lines
                )
                try Task.checkCancellation()
                let candidates = response.positions.map {
                    makeOCRCandidate(from: $0)
                }
                guard !candidates.isEmpty else {
                    throw BridgeConnectionError.invalidResponse
                }
                updateBackgroundProgress(
                    operationID: pending.operationID,
                    completed: 90,
                    subtitle: "正在恢复并汇总产品"
                )
                applyAssetRecognitionCandidates(
                    candidates,
                    batchID: pending.batchID,
                    imageIndexOffset: pending.imageIndexOffset,
                    description: "桥接后由 Codex 重新整理"
                )
                updateBackgroundProgress(
                    operationID: pending.operationID,
                    completed: 100,
                    subtitle: "资产识别已完成"
                )
                completedSuccessfully = true
            } catch is CancellationError {
                return
            } catch {
                guard activeOCRBatchID == pending.batchID else { return }
                holdAssetRecognitionForRecovery(pending, error: error)
            }
        }
    }

    func useLocalAssetRecognitionFallback() {
        guard let pending = pendingAssetRecognition,
              activeOCRBatchID == pending.batchID else {
            errorMessage = "没有可采用的本机识别结果，请重新选择截图。"
            return
        }
        guard !pending.result.fallbackCandidates.isEmpty else {
            handleAssetRecognitionFailure(
                AssetOCRError.noText,
                imageIndexOffset: pending.imageIndexOffset
            )
            return
        }
        applyAssetRecognitionCandidates(
            pending.result.fallbackCandidates,
            batchID: pending.batchID,
            imageIndexOffset: pending.imageIndexOffset,
            description: "已确认使用本机基础识别"
        )
    }

    func clearAssetRecognition() {
        resetAssetRecognitionState()
        errorMessage = nil
        statusMessage = "已清空本次截图和识别结果。"
    }

    func deleteAggregatedPosition(id: String) {
        guard let position = aggregatedPositions.first(where: { $0.id == id }) else {
            return
        }
        let candidateIDs = Set(position.candidateIDs)
        guard !candidateIDs.isEmpty else {
            errorMessage = "这个识别结果缺少可删除的原始条目，请清空后重新识别。"
            return
        }
        ocrCandidates.removeAll { candidateIDs.contains($0.id) }
        ocrCandidateRevision &+= 1
        rebuildAggregatedPositions()
        isAssetRecognitionBatchValid = !aggregatedPositions.isEmpty
        assetRecognitionState = isAssetRecognitionBatchValid ? .valid : .invalid
        statusMessage = isAssetRecognitionBatchValid
            ? "已删除“\(position.name)”，请继续核对识别结果。"
            : "已删除最后一个产品；可清空本批次或重新选择截图。"
    }

    private func applyAssetRecognitionCandidates(
        _ candidates: [OCRPositionCandidate],
        batchID: UUID,
        imageIndexOffset: Int?,
        description: String
    ) {
        guard activeOCRBatchID == batchID, !candidates.isEmpty else { return }
        ocrCandidates = AssetRecognitionCandidateAccumulator.merging(
            existing: ocrCandidates,
            additions: candidates,
            imageIndexOffset: imageIndexOffset
        )
        pendingAssetRecognition = nil
        assetRecognitionBridgeIssue = nil
        assetRecognitionRequiresBridgeConnection = false
        canUseLocalAssetRecognitionFallback = false
        ocrCandidateRevision &+= 1
        rebuildAggregatedPositions()
        isAssetRecognitionBatchValid = !aggregatedPositions.isEmpty
        assetRecognitionState = isAssetRecognitionBatchValid ? .valid : .invalid
        let verifiedCount = aggregatedPositions.filter {
            $0.verification == .verified
        }.count
        let verificationDescription = verifiedCount > 0
            ? "，其中 \(verifiedCount) 个已联网核验"
            : ""
        let actionDescription = imageIndexOffset == nil
            ? description
            : "新增截图完成：\(description)"
        statusMessage = "\(actionDescription)，当前共 \(aggregatedPositions.count) 个产品\(verificationDescription)；原图未上传或保存。"
    }

    private func handleAssetRecognitionFailure(
        _ error: Error,
        imageIndexOffset: Int?
    ) {
        pendingAssetRecognition = nil
        assetRecognitionBridgeIssue = nil
        assetRecognitionRequiresBridgeConnection = false
        canUseLocalAssetRecognitionFallback = false

        if imageIndexOffset != nil, !ocrCandidates.isEmpty {
            isAssetRecognitionBatchValid = false
            assetRecognitionState = .invalid
            statusMessage = "新增截图未产生可用结果；已有识别和手工修正已保留。请清空后重新选择，再保存快照。"
        } else {
            ocrCandidates = []
            aggregatedPositions = []
            confirmedPositionIDs = []
            uncodedPositionResolutions = [:]
            isAssetRecognitionBatchValid = false
            assetRecognitionState = .invalid
        }
        errorMessage = error.localizedDescription
    }

    private func finishAssetRecognitionTask(
        taskID: UUID,
        batchID: UUID,
        wasCancelled: Bool
    ) {
        guard assetRecognitionTaskID == taskID,
              activeOCRBatchID == batchID else {
            return
        }

        assetRecognitionTaskID = nil
        assetRecognitionTask = nil
        if wasCancelled {
            if let pendingAssetRecognition,
               pendingAssetRecognition.batchID == batchID {
                assetRecognitionBridgeIssue =
                    "后台处理时间已结束，本机识别进度已保存；连接 Mac 后会自动继续。"
                assetRecognitionRequiresBridgeConnection =
                    bridge.connectedPeerName == nil
                canUseLocalAssetRecognitionFallback =
                    !pendingAssetRecognition.result.fallbackCandidates.isEmpty
                isAssetRecognitionBatchValid = false
                assetRecognitionState = .awaitingBridgeDecision
                resumableWorkRevision &+= 1
            } else if assetRecognitionState == .recognizing {
                isAssetRecognitionBatchValid = false
                assetRecognitionState = .invalid
                errorMessage = "截图尚未完成本机读字，后台时间已结束，请重新选择截图。"
            }
        }
        isWorking = false
    }

    private func resetAssetRecognitionState() {
        let cancelledActiveRecognition = assetRecognitionTask != nil
        if let activeAssetBackgroundOperationID {
            finishBackgroundProtection(
                operationID: activeAssetBackgroundOperationID,
                success: false
            )
            self.activeAssetBackgroundOperationID = nil
        }
        assetRecognitionTaskID = nil
        assetRecognitionTask?.cancel()
        assetRecognitionTask = nil
        activeOCRBatchID = nil
        pendingAssetRecognition = nil
        ocrCandidates = []
        aggregatedPositions = []
        confirmedPositionIDs = []
        uncodedPositionResolutions = [:]
        isAssetRecognitionBatchValid = false
        assetRecognitionState = .idle
        assetRecognitionImageCount = 0
        assetRecognitionBridgeIssue = nil
        assetRecognitionRequiresBridgeConnection = false
        canUseLocalAssetRecognitionFallback = false
        if cancelledActiveRecognition {
            isWorking = false
        }
        ocrCandidateRevision &+= 1
        clearPersistedAssetRecognition()
    }

    private func restorePendingOperations() {
        do {
            if let record = try pendingOperationStore.loadAssetRecognition() {
                guard isValidPendingAssetRecognition(record) else {
                    try pendingOperationStore.clearAssetRecognition()
                    throw CocoaError(.fileReadCorruptFile)
                }
                let pending = PendingAssetRecognition(
                    operationID: record.operationID,
                    batchID: record.batchID,
                    result: record.recognitionResult,
                    imageIndexOffset: record.imageIndexOffset
                )
                pendingAssetRecognition = pending
                activeOCRBatchID = record.batchID
                assetRecognitionImageCount =
                    (record.imageIndexOffset ?? 0) + record.imageCount
                ocrCandidates = record.retainedCandidates.map { $0.candidate() }
                rebuildAggregatedPositions()
                isAssetRecognitionBatchValid = false
                assetRecognitionState = .awaitingBridgeDecision
                assetRecognitionBridgeIssue =
                    "上次截图已完成本机读字，等待 Mac 继续整理。"
                assetRecognitionRequiresBridgeConnection = true
                canUseLocalAssetRecognitionFallback =
                    !record.fallbackCandidates.isEmpty
                ocrCandidateRevision &+= 1
            }
        } catch {
            try? pendingOperationStore.clearAssetRecognition()
            errorMessage = "未能恢复上次资产识别任务，请重新选择截图。"
        }

        do {
            let record = try pendingOperationStore.loadReportOperation()
            guard record?.packetSignature.count == SHA256.Digest.byteCount
                    || record == nil else {
                try pendingOperationStore.clearReportOperation()
                throw CocoaError(.fileReadCorruptFile)
            }
            persistedReportOperation = record
        } catch {
            try? pendingOperationStore.clearReportOperation()
            persistedReportOperation = nil
            errorMessage = "未能恢复上次月报任务，请重新生成。"
        }

        do {
            let record = try pendingOperationStore.loadFollowUpOperation()
            guard record.map({
                !$0.question.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    && $0.question.count
                        <= BridgeWire.maximumQuestionCharacters
            }) ?? true else {
                try pendingOperationStore.clearFollowUpOperation()
                throw CocoaError(.fileReadCorruptFile)
            }
            persistedFollowUpOperation = record
            if let record {
                pendingFollowUpOperations[
                    PendingFollowUpKey(
                        reportID: record.reportID,
                        question: record.question
                    )
                ] = record.operationID
            }
        } catch {
            try? pendingOperationStore.clearFollowUpOperation()
            persistedFollowUpOperation = nil
            errorMessage = "未能恢复上次追问任务，请重新提交问题。"
        }
    }

    private func isValidPendingAssetRecognition(
        _ record: PendingAssetRecognitionRecordV1
    ) -> Bool {
        let totalImageCount =
            (record.imageIndexOffset ?? 0) + record.imageCount
        guard (1...BridgeWire.maximumAssetImages).contains(record.imageCount),
              (1...BridgeWire.maximumAssetImages).contains(totalImageCount),
              record.imageIndexOffset.map({ $0 >= 0 }) ?? true,
              !record.lines.isEmpty,
              record.lines.count <= BridgeWire.maximumAssetOCRLines else {
            return false
        }
        return record.lines.allSatisfy {
            (0..<record.imageCount).contains($0.imageIndex)
                && !$0.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                && $0.confidence.isFinite
                && (0...1).contains($0.confidence)
        }
    }

    private func persistAssetRecognition(
        _ pending: PendingAssetRecognition
    ) {
        do {
            try pendingOperationStore.saveAssetRecognition(
                PendingAssetRecognitionRecordV1(
                    operationID: pending.operationID,
                    batchID: pending.batchID,
                    imageCount: pending.result.imageCount,
                    imageIndexOffset: pending.imageIndexOffset,
                    lines: pending.result.lines,
                    fallbackCandidates: pending.result.fallbackCandidates,
                    retainedCandidates: ocrCandidates
                )
            )
        } catch {
            errorMessage =
                "识别仍可继续，但未能保存断点；完成前请不要关闭 F.I.R.E。"
        }
    }

    private func clearPersistedAssetRecognition() {
        do {
            try pendingOperationStore.clearAssetRecognition()
        } catch {
            errorMessage = "未能清理已完成的截图识别断点。"
        }
    }

    static func shouldRequestBridgeConnection(
        after error: Error,
        bridgeConnected: Bool
    ) -> Bool {
        guard bridgeConnected else { return true }
        guard let bridgeError = error as? BridgeConnectionError else {
            return false
        }
        switch bridgeError {
        case .notConnected, .authenticationRequired:
            return true
        case .featureUnavailable, .invalidResponse, .remote, .timedOut,
             .sendFailed:
            return false
        }
    }

    private func holdAssetRecognitionForRecovery(
        _ pending: PendingAssetRecognition,
        error: Error
    ) {
        pendingAssetRecognition = pending
        persistAssetRecognition(pending)
        assetRecognitionBridgeIssue = error.localizedDescription
        assetRecognitionRequiresBridgeConnection =
            Self.shouldRequestBridgeConnection(
                after: error,
                bridgeConnected: bridge.connectedPeerName != nil
            )
        canUseLocalAssetRecognitionFallback =
            !pending.result.fallbackCandidates.isEmpty
        isAssetRecognitionBatchValid = false
        assetRecognitionState = .awaitingBridgeDecision
    }

    private func makeOCRCandidate(
        from position: RecognizedAssetPositionV1
    ) -> OCRPositionCandidate {
        let codeValue = position.productCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            ?? ""
        let verification = position.verification
            .flatMap {
                AssetProductVerification(rawValue: $0.status.rawValue)
            }
            ?? .localOnly
        let verificationEvidence = position.verification.map {
            "\($0.sourceName)：\($0.message)"
        }
        return OCRPositionCandidate(
            sourceImageIndex: position.imageIndex,
            productName: position.productName
                .trimmingCharacters(in: .whitespacesAndNewlines),
            productCode: codeValue.isEmpty ? nil : codeValue,
            kind: AssetKind(rawValue: position.kind.rawValue) ?? .fund,
            currency: position.currency.rawValue,
            originalMarketValue: position.originalMarketValue,
            confidence: position.confidence,
            requiresMergeConfirmation: codeValue.isEmpty
                || verification != .verified,
            rawEvidence: [position.evidence, verificationEvidence]
                .compactMap { $0 }
                .joined(separator: " · "),
            verification: verification
        )
    }

    func updateAggregatedPosition(
        id: String,
        name: String,
        code: String?,
        kind: AssetKind,
        currency: String,
        originalMarketValue: Double
    ) {
        guard let position = aggregatedPositions.first(where: { $0.id == id }),
              let firstCandidate = ocrCandidates.first(where: {
                  position.candidateIDs.contains($0.id)
              }) else {
            return
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCodeValue = code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            ?? ""
        let normalizedCode = normalizedCodeValue.isEmpty
            ? nil
            : normalizedCodeValue
        let normalizedCurrency = currency.uppercased()
        guard !normalizedName.isEmpty,
              originalMarketValue.isFinite,
              originalMarketValue > 0,
              ["CNY", "USD", "HKD"].contains(normalizedCurrency) else {
            errorMessage = "产品名称不能为空，市值必须大于 0。"
            return
        }

        let evidence = ocrCandidates
            .filter { position.candidateIDs.contains($0.id) }
            .map(\.rawEvidence)
            .joined(separator: " · ")
        let replacement = OCRPositionCandidate(
            id: firstCandidate.id,
            sourceImageIndex: firstCandidate.sourceImageIndex,
            productName: normalizedName,
            productCode: normalizedCode,
            kind: kind,
            currency: normalizedCurrency,
            originalMarketValue: originalMarketValue,
            confidence: firstCandidate.confidence,
            requiresMergeConfirmation: normalizedCode == nil,
            rawEvidence: evidence,
            verification: .manual
        )
        let candidateIDs = Set(position.candidateIDs)
        ocrCandidates.removeAll { candidateIDs.contains($0.id) }
        ocrCandidates.append(replacement)
        uncodedPositionResolutions = [:]
        ocrCandidateRevision &+= 1
        rebuildAggregatedPositions()
        isAssetRecognitionBatchValid = !aggregatedPositions.isEmpty
        assetRecognitionState = isAssetRecognitionBatchValid ? .valid : .invalid
        statusMessage = "产品信息已修正，请核对汇总金额。"
    }

    func setUncodedResolution(
        _ resolution: UncodedPositionResolution,
        positionID: String
    ) {
        guard aggregatedPositions.contains(where: {
            $0.id == positionID && $0.code == nil
        }) else {
            return
        }
        if case let .batchCanonical(targetID) = resolution {
            let hasDependents = uncodedPositionResolutions.contains {
                guard case let .batchCanonical(existingTargetID) = $0.value else {
                    return false
                }
                return existingTargetID == positionID
            }
            guard !hasDependents,
                  aggregationService.isSameBatchMergeValid(
                    sourceID: positionID,
                    targetID: targetID,
                    positions: aggregatedPositions
                  ),
                  let target = aggregatedPositions.first(where: {
                      $0.id == targetID
                  }) else {
                errorMessage = AssetOCRError.invalidBatchMerge.localizedDescription
                return
            }
            if case .batchCanonical? = uncodedPositionResolutions[target.id] {
                errorMessage = AssetOCRError.invalidBatchMerge.localizedDescription
                return
            }
            if uncodedPositionResolutions[target.id] == nil {
                uncodedPositionResolutions[target.id] = .createNewInstrument
                confirmedPositionIDs.remove(target.id)
            }
        }
        uncodedPositionResolutions[positionID] = resolution
        confirmedPositionIDs.remove(positionID)
        ocrCandidateRevision &+= 1
    }

    func sameBatchMergeTargets(
        for position: AggregatedPosition
    ) -> [AggregatedPosition] {
        let hasDependents = uncodedPositionResolutions.contains {
            guard case let .batchCanonical(targetID) = $0.value else {
                return false
            }
            return targetID == position.id
        }
        guard !hasDependents else { return [] }
        return aggregationService.sameBatchMergeTargets(
            for: position,
            in: aggregatedPositions
        )
        .filter {
            if case .batchCanonical? = uncodedPositionResolutions[$0.id] {
                return false
            }
            return true
        }
    }

    private func rebuildAggregatedPositions(
        resetManualConfirmations _: Bool = true
    ) {
        aggregatedPositions = aggregationService.aggregate(ocrCandidates)
        let validUncodedIDs = Set(
            aggregatedPositions.filter { $0.code == nil }.map(\.id)
        )
        uncodedPositionResolutions = uncodedPositionResolutions.filter {
            guard validUncodedIDs.contains($0.key) else { return false }
            if case let .batchCanonical(targetID) = $0.value {
                return validUncodedIDs.contains(targetID)
                    && aggregationService.isSameBatchMergeValid(
                        sourceID: $0.key,
                        targetID: targetID,
                        positions: aggregatedPositions
                    )
            }
            return true
        }
        // 识别结果改为汇总级“修正”，不再要求逐条确认开关。
        confirmedPositionIDs = Set(aggregatedPositions.map(\.id))
    }

    func confirmAssetSnapshot(
        capturedAt: Date,
        cashCNY: Double,
        cashUSD: Double,
        cashHKD: Double,
        confirmsAllScreenshotsWereSelected: Bool,
        confirmsNoInvestmentPositions: Bool,
        latestConfirmedSnapshotDate: Date?,
        existingInstruments: [InstrumentEntity],
        liabilities: [LiabilityEntity]
    ) async -> Bool {
        guard let context else { return false }
        guard !isWorking else {
            errorMessage = "正在处理其他操作，请稍后再保存。"
            return false
        }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        let calendar = Calendar.current
        let capturedDay = calendar.startOfDay(for: capturedAt)
        let today = calendar.startOfDay(for: .now)
        guard capturedDay <= today else {
            errorMessage = "快照日期不能晚于今天。"
            return false
        }
        if let latestConfirmedSnapshotDate {
            let latestDay = calendar.startOfDay(for: latestConfirmedSnapshotDate)
            guard capturedDay > latestDay else {
                errorMessage = "首版不支持同日重复或历史回填；新快照日期必须晚于现有最新快照。"
                return false
            }
        }

        rebuildAggregatedPositions(resetManualConfirmations: false)
        let isConfirmedCashOnlySnapshot = confirmsNoInvestmentPositions
            && assetRecognitionState == .idle
            && activeOCRBatchID == nil
            && ocrCandidates.isEmpty
            && aggregatedPositions.isEmpty
        if confirmsNoInvestmentPositions, !isConfirmedCashOnlySnapshot {
            errorMessage = "只有未选择截图且没有 OCR 失败时，才能确认本月无基金、股票或期权。"
            return false
        }
        if !isConfirmedCashOnlySnapshot {
            guard activeOCRBatchID != nil,
                  assetRecognitionState == .valid,
                  isAssetRecognitionBatchValid,
                  !ocrCandidates.isEmpty,
                  !aggregatedPositions.isEmpty else {
                errorMessage = "当前没有有效的 OCR 识别批次，请重新选择全部资产截图。"
                return false
            }
        }
        let invalidCandidateCount = ocrCandidates.filter {
            $0.productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.originalMarketValue.isFinite
                || $0.originalMarketValue <= 0
        }.count
        guard invalidCandidateCount == 0 else {
            errorMessage = "还有 \(invalidCandidateCount) 条识别明细缺少有效名称或金额。"
            return false
        }
        guard isConfirmedCashOnlySnapshot || confirmsAllScreenshotsWereSelected else {
            errorMessage = "请先确认本月所有资产截图都已选入，系统才会安全判断已清仓产品。"
            return false
        }
        let positionsForBatch = aggregatedPositions
        let confirmationsForBatch = Set(positionsForBatch.map(\.id))
        let uncodedResolutionsForBatch = uncodedPositionResolutions
        let candidateRevision = ocrCandidateRevision
        let batchID = activeOCRBatchID
        let unresolvedUncoded = positionsForBatch.filter {
            $0.code == nil && uncodedResolutionsForBatch[$0.id] == nil
        }
        guard unresolvedUncoded.isEmpty else {
            errorMessage = "还有 \(unresolvedUncoded.count) 个无代码产品需要明确关联已有、新建或合并到本批同名主项。"
            return false
        }
        let savePlan: PositionSavePlan
        do {
            savePlan = try aggregationService.makeSavePlan(
                positions: positionsForBatch,
                uncodedResolutions: uncodedResolutionsForBatch
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let positionsForSnapshot = savePlan.positions
        let resolutionsForSnapshot = savePlan.uncodedResolutions
        let invalidExistingResolution = positionsForSnapshot.contains { position in
            guard position.code == nil,
                  case let .existingInstrument(instrumentID)? =
                    resolutionsForSnapshot[position.id] else {
                return false
            }
            return !existingInstruments.contains {
                $0.id == instrumentID
                    && $0.kind == position.kind
                    && $0.currency.uppercased() == position.currency.uppercased()
            }
        }
        guard !invalidExistingResolution else {
            errorMessage = AssetOCRError.invalidInstrumentResolution.localizedDescription
            return false
        }

        do {
            let currencies = Set(
                positionsForSnapshot.map { $0.currency.uppercased() }
                    + liabilities.map { $0.currency.uppercased() }
                    + (cashUSD > 0 ? ["USD"] : [])
                    + (cashHKD > 0 ? ["HKD"] : [])
            )
            let quote: FXQuote
            if currencies.subtracting(["CNY"]).isEmpty {
                quote = FXQuote(
                    ratesToCNY: ["CNY": 1],
                    observationDate: capturedAt,
                    state: .current,
                    source: "无需换算"
                )
            } else {
                quote = try await resolveFXQuote(
                    for: capturedAt,
                    currencies: currencies,
                    context: context
                )
            }
            lastExchangeQuote = quote

            if isConfirmedCashOnlySnapshot {
                guard activeOCRBatchID == nil,
                      assetRecognitionState == .idle,
                      ocrCandidateRevision == candidateRevision else {
                    errorMessage = "资产输入在保存前发生了变化，请重新确认。"
                    return false
                }
            } else {
                guard activeOCRBatchID == batchID,
                      assetRecognitionState == .valid,
                      isAssetRecognitionBatchValid,
                      ocrCandidateRevision == candidateRevision else {
                    errorMessage = "识别批次在保存前发生了变化，请重新核对并确认。"
                    return false
                }
            }

            let snapshotID = UUID()
            var instruments = existingInstruments
            var activeIdentity = Set<String>()
            var positionValues: [(AggregatedPosition, InstrumentEntity, Double)] = []
            var recognizedCashCNY = 0.0

            for position in positionsForSnapshot {
                guard let cnyValue = quote.cnyValue(
                    position.originalMarketValue,
                    currency: position.currency
                ) else {
                    throw FXServiceError.missingCurrency(position.currency)
                }
                if position.kind == .cash {
                    recognizedCashCNY += cnyValue
                    continue
                }

                let identity: String
                let instrument: InstrumentEntity
                if position.code?.isEmpty == false {
                    identity = InstrumentEntity.identity(
                        code: position.code,
                        name: position.name,
                        kind: position.kind,
                        currency: position.currency
                    )
                    if let existing = instruments.first(where: {
                        $0.normalizedIdentity == identity
                    }) {
                        instrument = existing
                        instrument.name = position.name
                        instrument.kind = position.kind
                        instrument.isActive = true
                        instrument.closedAt = nil
                    } else {
                        instrument = InstrumentEntity(
                            code: position.code,
                            name: position.name,
                            kind: position.kind,
                            currency: position.currency
                        )
                        context.insert(instrument)
                        instruments.append(instrument)
                    }
                } else {
                    switch resolutionsForSnapshot[position.id] {
                    case let .existingInstrument(instrumentID)?:
                        guard let existing = instruments.first(where: {
                            $0.id == instrumentID
                        }) else {
                            throw AssetOCRError.invalidInstrumentResolution
                        }
                        instrument = existing
                        identity = existing.normalizedIdentity
                        instrument.isActive = true
                        instrument.closedAt = nil
                    case .createNewInstrument?:
                        identity = "\(position.kind.rawValue)::\(position.currency.uppercased())::UNVERIFIED::\(position.id)"
                        instrument = InstrumentEntity(
                            code: nil,
                            name: position.name,
                            kind: position.kind,
                            currency: position.currency
                        )
                        instrument.normalizedIdentity = identity
                        context.insert(instrument)
                        instruments.append(instrument)
                    case .batchCanonical?:
                        throw AssetOCRError.invalidBatchMerge
                    case nil:
                        throw AssetOCRError.invalidInstrumentResolution
                    }
                }
                activeIdentity.insert(identity)
                positionValues.append((position, instrument, cnyValue))
            }

            // 只有本月完整快照完成确认后，未出现的旧产品才能被标记为清仓。
            for instrument in instruments where instrument.kind != .cash {
                if instrument.isActive, !activeIdentity.contains(instrument.normalizedIdentity) {
                    instrument.isActive = false
                    instrument.closedAt = capturedAt
                }
            }

            let positionsTotal = positionValues.reduce(0) { $0 + $1.2 }
            let manualCashUSDCNY: Double
            if cashUSD > 0 {
                guard let converted = quote.cnyValue(cashUSD, currency: "USD") else {
                    throw FXServiceError.missingCurrency("USD")
                }
                manualCashUSDCNY = converted
            } else {
                manualCashUSDCNY = 0
            }
            let manualCashHKDCNY: Double
            if cashHKD > 0 {
                guard let converted = quote.cnyValue(cashHKD, currency: "HKD") else {
                    throw FXServiceError.missingCurrency("HKD")
                }
                manualCashHKDCNY = converted
            } else {
                manualCashHKDCNY = 0
            }
            let liabilitiesTotal = try liabilities.reduce(0) { partial, liability in
                guard let converted = quote.cnyValue(
                    liability.remainingPrincipal,
                    currency: liability.currency
                ) else {
                    throw FXServiceError.missingCurrency(liability.currency)
                }
                liability.cnyRemainingPrincipal = converted
                liability.updatedAt = capturedAt
                return partial + converted
            }
            let snapshot = AssetSnapshotEntity(
                id: snapshotID,
                capturedAt: capturedAt,
                cashCNY: cashCNY,
                cashUSD: cashUSD,
                cashHKD: cashHKD,
                cashValueInCNY: cashCNY + manualCashUSDCNY + manualCashHKDCNY
                    + recognizedCashCNY,
                liabilityPrincipalCNY: liabilitiesTotal,
                positionsCNY: positionsTotal,
                isComplete: true,
                exchangeRateState: quote.state,
                exchangeRateAsOf: quote.observationDate,
                exchangeRateFetchedAt: quote.fetchedAt,
                exchangeRateSource: quote.source,
                usdToCNY: quote.ratesToCNY["USD"],
                hkdToCNY: quote.ratesToCNY["HKD"]
            )
            context.insert(snapshot)

            for (position, instrument, cnyValue) in positionValues {
                context.insert(
                    PositionSnapshotEntity(
                        assetSnapshotID: snapshotID,
                        instrumentID: instrument.id,
                        originalMarketValue: position.originalMarketValue,
                        cnyMarketValue: cnyValue,
                        capturedAt: capturedAt,
                        recognitionConfidence: position.confidence,
                        sourceCount: position.sourceCount,
                        wasManuallyConfirmed: confirmationsForBatch.contains(position.id)
                    )
                )
            }

            try context.save()
            dataRevision &+= 1
            resetAssetRecognitionState()
            statusMessage = "本月完整资产快照已保存。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveManualPosition(
        snapshot: AssetSnapshotEntity,
        existingPosition: PositionSnapshotEntity?,
        name: String,
        code: String?,
        kind: AssetKind,
        currency: String,
        originalMarketValue: Double
    ) async -> Bool {
        guard let context else { return false }
        guard !isWorking else {
            errorMessage = "正在处理其他操作，请稍后再保存。"
            return false
        }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        let normalizedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedCodeValue = code?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        let normalizedCode = normalizedCodeValue.isEmpty
            ? nil
            : normalizedCodeValue
        let normalizedCurrency = currency.uppercased()
        guard !normalizedName.isEmpty,
              originalMarketValue.isFinite,
              originalMarketValue > 0,
              kind != .cash,
              ["CNY", "USD", "HKD"].contains(normalizedCurrency) else {
            errorMessage = "产品名称和当前价值必须有效；现金请在现金区域填写。"
            return false
        }

        do {
            let snapshots = try context.fetch(
                FetchDescriptor<AssetSnapshotEntity>()
            )
            guard snapshots.max(by: Self.snapshotIsEarlier)?.id
                    == snapshot.id else {
                errorMessage = "只能修正最新一份资产快照，历史快照保持只读。"
                return false
            }

            let allPositions = try context.fetch(
                FetchDescriptor<PositionSnapshotEntity>()
            )
            var snapshotPositions = allPositions.filter {
                $0.assetSnapshotID == snapshot.id
            }
            let storedExistingPosition: PositionSnapshotEntity?
            if let existingPosition {
                guard let stored = snapshotPositions.first(where: {
                    $0.id == existingPosition.id
                }) else {
                    errorMessage = "这条持仓已发生变化，请刷新后重试。"
                    return false
                }
                storedExistingPosition = stored
            } else {
                storedExistingPosition = nil
            }

            let identity = InstrumentEntity.identity(
                code: normalizedCode,
                name: normalizedName,
                kind: kind,
                currency: normalizedCurrency
            )
            var instruments = try context.fetch(
                FetchDescriptor<InstrumentEntity>()
            )
            let previousInstrument = storedExistingPosition.flatMap { position in
                instruments.first { $0.id == position.instrumentID }
            }
            let targetInstrument: InstrumentEntity
            if let previousInstrument,
               previousInstrument.normalizedIdentity == identity {
                targetInstrument = previousInstrument
            } else if let matched = instruments.first(where: {
                $0.normalizedIdentity == identity
            }) {
                targetInstrument = matched
            } else {
                targetInstrument = InstrumentEntity(
                    code: normalizedCode,
                    name: normalizedName,
                    kind: kind,
                    currency: normalizedCurrency
                )
                context.insert(targetInstrument)
                instruments.append(targetInstrument)
            }

            let duplicatePosition = snapshotPositions.contains {
                $0.id != storedExistingPosition?.id
                    && $0.instrumentID == targetInstrument.id
            }
            guard !duplicatePosition else {
                errorMessage = "本期快照已经有这个产品，请直接编辑已有持仓。"
                return false
            }

            let rateResult = try await cnyRate(
                for: normalizedCurrency,
                snapshot: snapshot,
                context: context
            )
            let cnyMarketValue = originalMarketValue * rateResult.rate
            guard cnyMarketValue.isFinite, cnyMarketValue > 0 else {
                throw FXServiceError.invalidResponse
            }

            targetInstrument.code = normalizedCode
            targetInstrument.name = normalizedName
            targetInstrument.kind = kind
            targetInstrument.currency = normalizedCurrency
            targetInstrument.normalizedIdentity = identity
            targetInstrument.isActive = true
            targetInstrument.closedAt = nil

            let savedPosition: PositionSnapshotEntity
            if let storedExistingPosition {
                savedPosition = storedExistingPosition
                savedPosition.instrumentID = targetInstrument.id
                savedPosition.originalMarketValue = originalMarketValue
                savedPosition.cnyMarketValue = cnyMarketValue
                savedPosition.recognitionConfidence = 1
                savedPosition.sourceCount = 1
                savedPosition.wasManuallyConfirmed = true
            } else {
                savedPosition = PositionSnapshotEntity(
                    assetSnapshotID: snapshot.id,
                    instrumentID: targetInstrument.id,
                    originalMarketValue: originalMarketValue,
                    cnyMarketValue: cnyMarketValue,
                    capturedAt: snapshot.capturedAt,
                    recognitionConfidence: 1,
                    sourceCount: 1,
                    wasManuallyConfirmed: true
                )
                context.insert(savedPosition)
                snapshotPositions.append(savedPosition)
            }

            if let previousInstrument,
               previousInstrument.id != targetInstrument.id {
                let previousStillHeld = snapshotPositions.contains {
                    $0.id != savedPosition.id
                        && $0.instrumentID == previousInstrument.id
                }
                if !previousStillHeld {
                    previousInstrument.isActive = false
                    previousInstrument.closedAt = snapshot.capturedAt
                }
            }

            if let quote = rateResult.quote {
                applyExchangeRate(quote, to: snapshot)
            }
            snapshot.positionsCNY = snapshotPositions.reduce(0) {
                $0 + $1.cnyMarketValue
            }
            try context.save()
            dataRevision &+= 1
            statusMessage = existingPosition == nil
                ? "资产已补录到最新快照。"
                : "最新快照中的资产已更新。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deletePositionFromLatestSnapshot(
        _ position: PositionSnapshotEntity,
        snapshot: AssetSnapshotEntity
    ) -> Bool {
        guard let context else { return false }
        do {
            let snapshots = try context.fetch(
                FetchDescriptor<AssetSnapshotEntity>()
            )
            guard snapshots.max(by: Self.snapshotIsEarlier)?.id
                    == snapshot.id else {
                errorMessage = "只能修正最新一份资产快照，历史快照保持只读。"
                return false
            }
            let allPositions = try context.fetch(
                FetchDescriptor<PositionSnapshotEntity>()
            )
            guard let stored = allPositions.first(where: {
                $0.id == position.id && $0.assetSnapshotID == snapshot.id
            }) else {
                errorMessage = "这条持仓已经不存在。"
                return false
            }
            let remaining = allPositions.filter {
                $0.assetSnapshotID == snapshot.id && $0.id != stored.id
            }
            context.delete(stored)
            snapshot.positionsCNY = remaining.reduce(0) {
                $0 + $1.cnyMarketValue
            }

            let instrumentID = stored.instrumentID
            if !remaining.contains(where: {
                $0.instrumentID == instrumentID
            }),
            let instrument = try context.fetch(
                FetchDescriptor<InstrumentEntity>()
            ).first(where: { $0.id == instrumentID }) {
                instrument.isActive = false
                instrument.closedAt = snapshot.capturedAt
            }
            try context.save()
            dataRevision &+= 1
            statusMessage = "本期持仓已删除。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveManualRate(
        currency: String,
        rateToCNY: Double,
        snapshotDate: Date
    ) {
        guard let context else { return }
        do {
            try FXRateResolver(service: fxService, context: context).saveManualRate(
                sourceCurrency: currency,
                rateToCNY: rateToCNY,
                for: snapshotDate
            )
            statusMessage = "\(currency.uppercased()) 手动汇率已保存。"
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func cnyRate(
        for currency: String,
        snapshot: AssetSnapshotEntity,
        context: ModelContext
    ) async throws -> (rate: Double, quote: FXQuote?) {
        switch currency {
        case "CNY":
            return (1, nil)
        case "USD":
            if let rate = snapshot.usdToCNY, rate.isFinite, rate > 0 {
                return (rate, nil)
            }
        case "HKD":
            if let rate = snapshot.hkdToCNY, rate.isFinite, rate > 0 {
                return (rate, nil)
            }
        default:
            throw FXServiceError.missingCurrency(currency)
        }

        let quote = try await resolveFXQuote(
            for: snapshot.capturedAt,
            currencies: [currency],
            context: context
        )
        guard let rate = quote.ratesToCNY[currency],
              rate.isFinite,
              rate > 0 else {
            throw FXServiceError.missingCurrency(currency)
        }
        return (rate, quote)
    }

    private func applyExchangeRate(
        _ quote: FXQuote,
        to snapshot: AssetSnapshotEntity
    ) {
        snapshot.exchangeRateStateRawValue = quote.state.rawValue
        snapshot.exchangeRateAsOf = quote.observationDate
        snapshot.exchangeRateFetchedAt = quote.fetchedAt
        snapshot.exchangeRateSource = quote.source
        snapshot.usdToCNY = quote.ratesToCNY["USD"] ?? snapshot.usdToCNY
        snapshot.hkdToCNY = quote.ratesToCNY["HKD"] ?? snapshot.hkdToCNY
        lastExchangeQuote = quote
    }

    @discardableResult
    func saveLiability(
        existing: LiabilityEntity?,
        name: String,
        currency: String,
        principal: Double
    ) async -> Bool {
        guard let context else { return false }
        guard !isWorking else {
            errorMessage = "正在处理其他操作，请稍后再保存。"
            return false
        }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrency = currency.uppercased()
        guard !trimmedName.isEmpty, principal.isFinite, principal > 0 else {
            errorMessage = "负债名称和本金必须有效。"
            return false
        }

        do {
            let quote: FXQuote
            if normalizedCurrency == "CNY" {
                quote = FXQuote(
                    ratesToCNY: ["CNY": 1],
                    observationDate: .now,
                    state: .current,
                    source: "无需换算"
                )
            } else {
                quote = try await resolveFXQuote(
                    for: .now,
                    currencies: [normalizedCurrency],
                    context: context
                )
            }
            guard let rateToCNY = quote.ratesToCNY[normalizedCurrency],
                  rateToCNY.isFinite,
                  rateToCNY > 0 else {
                throw FXServiceError.missingCurrency(normalizedCurrency)
            }

            let allLiabilities = try context.fetch(FetchDescriptor<LiabilityEntity>())
            let normalizedName = Self.normalizedLiabilityName(trimmedName)
            let matches = allLiabilities.filter {
                $0.id != existing?.id
                    && $0.currency.uppercased() == normalizedCurrency
                    && Self.normalizedLiabilityName($0.name) == normalizedName
            }
            if existing != nil, !matches.isEmpty {
                errorMessage = "已有同名同币种负债，请编辑该记录或先删除重复项。"
                return false
            }
            if existing == nil, matches.count > 1 {
                errorMessage = "已存在多条同名同币种负债，请先在列表中删除重复项。"
                return false
            }

            let value: LiabilityEntity
            let isUpdating: Bool
            if let existing {
                value = existing
                isUpdating = true
            } else if let matched = matches.first {
                value = matched
                isUpdating = true
            } else {
                value = LiabilityEntity(
                    name: trimmedName,
                    currency: normalizedCurrency,
                    remainingPrincipal: principal,
                    cnyRemainingPrincipal: principal * rateToCNY
                )
                context.insert(value)
                isUpdating = false
            }
            value.name = trimmedName
            value.currency = normalizedCurrency
            value.remainingPrincipal = principal
            value.cnyRemainingPrincipal = principal * rateToCNY
            value.updatedAt = .now
            try context.save()
            lastExchangeQuote = quote
            dataRevision &+= 1
            let action = isUpdating ? "负债本金已更新" : "负债已新增"
            statusMessage = normalizedCurrency == "CNY"
                ? "\(action)。"
                : "\(action)，汇率来自 \(quote.source)。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func resolveFXQuote(
        for snapshotDate: Date,
        currencies: Set<String>,
        context: ModelContext
    ) async throws -> FXQuote {
        let preferredFetcher: (() async throws -> FXQuote)?
        if bridge.connectedPeerName != nil {
            preferredFetcher = { [bridge] in
                let response = try await bridge.fetchExchangeRates(
                    snapshotDate: snapshotDate,
                    currencies: currencies
                )
                let age = Calendar.current.dateComponents(
                    [.day],
                    from: Calendar.current.startOfDay(
                        for: response.observationDate
                    ),
                    to: Calendar.current.startOfDay(for: snapshotDate)
                ).day ?? 999
                return FXQuote(
                    ratesToCNY: response.ratesToCNY,
                    observationDate: response.observationDate,
                    state: age <= 4 ? .current : .stale,
                    fetchedAt: response.fetchedAt,
                    source: response.source
                )
            }
        } else {
            preferredFetcher = nil
        }

        return try await FXRateResolver(
            service: fxService,
            context: context
        ).quote(
            for: snapshotDate,
            requiredCurrencies: currencies,
            preferredFetcher: preferredFetcher
        )
    }

    func deleteLiability(_ liability: LiabilityEntity) {
        guard let context else { return }
        context.delete(liability)
        do {
            try context.save()
            dataRevision &+= 1
            statusMessage = "负债已删除。"
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private static func normalizedLiabilityName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    @discardableResult
    func saveIncomePlan(
        monthlyIncome: Double,
        annualIncome: Double
    ) -> Bool {
        guard let context else { return false }
        guard let monthlyIncomeDecimal = PlanAmountValue.decimal(
            from: monthlyIncome
        ),
        let annualIncomeDecimal = PlanAmountValue.decimal(
            from: annualIncome
        ),
        PlanAmountValue.annualExpenseTotal(
            monthlyExpense: monthlyIncomeDecimal,
            annualIrregularExpense: annualIncomeDecimal
        ) != nil else {
            errorMessage = "月度收入和年度收入必须是有效的非负金额。"
            return false
        }

        do {
            let metadata = try context.fetch(
                FetchDescriptor<AppMetadataEntity>()
            )
            let settings = try context.fetch(
                FetchDescriptor<FIRESettingsEntity>()
            )
            let savedAt = Date()
            upsertPlanMetadata(
                key: AppMetadataKey.plannedMonthlyIncome,
                value: monthlyIncome,
                savedAt: savedAt,
                metadata: metadata,
                context: context
            )
            upsertPlanMetadata(
                key: AppMetadataKey.plannedAnnualIncome,
                value: annualIncome,
                savedAt: savedAt,
                metadata: metadata,
                context: context
            )
            deleteMetadata(
                keys: [AppMetadataKey.confirmedAnnualBonusContribution],
                metadata: metadata,
                context: context
            )
            clearLegacyMonthlyContribution(
                settings,
                updatedAt: savedAt
            )

            try context.save()
            dataRevision &+= 1
            statusMessage = "收入规划已保存。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func clearIncomePlan() -> Bool {
        guard let context else { return false }
        do {
            let metadata = try context.fetch(
                FetchDescriptor<AppMetadataEntity>()
            )
            let settings = try context.fetch(
                FetchDescriptor<FIRESettingsEntity>()
            )
            deleteMetadata(
                keys: [
                    AppMetadataKey.plannedMonthlyIncome,
                    AppMetadataKey.plannedAnnualIncome,
                    AppMetadataKey.confirmedAnnualBonusContribution,
                ],
                metadata: metadata,
                context: context
            )
            clearLegacyMonthlyContribution(
                settings,
                updatedAt: .now
            )

            try context.save()
            dataRevision &+= 1
            statusMessage = "收入规划已清除。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveExpensePlan(
        monthlyExpense: Double,
        annualIrregularExpense: Double
    ) -> Bool {
        guard let context else { return false }
        guard let monthlyExpenseDecimal = PlanAmountValue.decimal(
            from: monthlyExpense
        ),
        let annualIrregularExpenseDecimal = PlanAmountValue.decimal(
            from: annualIrregularExpense
        ),
        let total = PlanAmountValue.annualExpenseTotal(
            monthlyExpense: monthlyExpenseDecimal,
            annualIrregularExpense: annualIrregularExpenseDecimal
        ),
        total > 0 else {
            errorMessage = "月度支出和年度不规则支出必须有效，年度支出合计需大于 0。"
            return false
        }

        do {
            let metadata = try context.fetch(
                FetchDescriptor<AppMetadataEntity>()
            )
            let savedAt = Date()
            upsertPlanMetadata(
                key: AppMetadataKey.plannedMonthlyExpense,
                value: monthlyExpense,
                savedAt: savedAt,
                metadata: metadata,
                context: context
            )
            upsertPlanMetadata(
                key: AppMetadataKey.plannedAnnualIrregularExpense,
                value: annualIrregularExpense,
                savedAt: savedAt,
                metadata: metadata,
                context: context
            )
            deleteMetadata(
                keys: [AppMetadataKey.plannedAnnualSpending],
                metadata: metadata,
                context: context
            )

            try context.save()
            dataRevision &+= 1
            statusMessage = "支出规划已保存。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func clearExpensePlan() -> Bool {
        guard let context else { return false }
        do {
            let metadata = try context.fetch(
                FetchDescriptor<AppMetadataEntity>()
            )
            deleteMetadata(
                keys: [
                    AppMetadataKey.plannedMonthlyExpense,
                    AppMetadataKey.plannedAnnualIrregularExpense,
                    AppMetadataKey.plannedAnnualSpending,
                ],
                metadata: metadata,
                context: context
            )

            try context.save()
            dataRevision &+= 1
            statusMessage = "支出规划已清除。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func upsertPlanMetadata(
        key: String,
        value: Double,
        savedAt: Date,
        metadata: [AppMetadataEntity],
        context: ModelContext
    ) {
        let matches = metadata.filter { $0.key == key }
        let entity: AppMetadataEntity
        if let existing = matches.first {
            entity = existing
        } else {
            entity = AppMetadataEntity(key: key)
            context.insert(entity)
        }
        for duplicate in matches.dropFirst() {
            context.delete(duplicate)
        }
        entity.doubleValue = value
        entity.dateValue = savedAt
    }

    private func deleteMetadata(
        keys: Set<String>,
        metadata: [AppMetadataEntity],
        context: ModelContext
    ) {
        for entity in metadata where keys.contains(entity.key) {
            context.delete(entity)
        }
    }

    private func clearLegacyMonthlyContribution(
        _ settings: [FIRESettingsEntity],
        updatedAt: Date
    ) {
        for setting in settings
        where setting.confirmedMonthlyContribution != nil
            || setting.contributionConfirmedAt != nil {
            setting.confirmedMonthlyContribution = nil
            setting.contributionConfirmedAt = nil
            setting.updatedAt = updatedAt
        }
    }

    @discardableResult
    func savePlannedAnnualSpending(_ annualSpending: Double) -> Bool {
        guard let context else { return false }
        guard PlannedAnnualSpendingValue.decimal(
            from: annualSpending
        ) != nil else {
            errorMessage = "规划年度支出必须是大于 0 的有效金额。"
            return false
        }
        do {
            let matches = try context.fetch(
                FetchDescriptor<AppMetadataEntity>()
            ).filter {
                $0.key == AppMetadataKey.plannedAnnualSpending
            }
            let metadata: AppMetadataEntity
            if let existing = matches.first {
                metadata = existing
            } else {
                metadata = AppMetadataEntity(
                    key: AppMetadataKey.plannedAnnualSpending
                )
                context.insert(metadata)
            }
            for duplicate in matches.dropFirst() {
                context.delete(duplicate)
            }
            metadata.doubleValue = annualSpending
            metadata.dateValue = .now

            try context.save()
            dataRevision &+= 1
            statusMessage = "规划年度支出已保存。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func clearPlannedAnnualSpending() -> Bool {
        guard let context else { return false }
        do {
            let matches = try context.fetch(
                FetchDescriptor<AppMetadataEntity>()
            ).filter {
                $0.key == AppMetadataKey.plannedAnnualSpending
            }
            for metadata in matches {
                context.delete(metadata)
            }

            try context.save()
            dataRevision &+= 1
            statusMessage = "年度支出已改回随账本自动更新。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveMonthlyContribution(_ monthlyContribution: Double) -> Bool {
        guard let context else { return false }
        guard PlanAmountValue.decimal(
            from: monthlyContribution
        ) != nil else {
            errorMessage = "每月结余必须是有效的非负金额。"
            return false
        }
        do {
            let descriptor = FetchDescriptor<FIRESettingsEntity>()
            let settings: FIRESettingsEntity
            if let existing = try context.fetch(descriptor).first {
                settings = existing
            } else {
                settings = FIRESettingsEntity()
                context.insert(settings)
            }
            settings.confirmedMonthlyContribution = monthlyContribution
            settings.contributionConfirmedAt = .now
            settings.updatedAt = .now

            try context.save()
            dataRevision &+= 1
            statusMessage = "接下来的每月可投资结余已保存。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveAnnualBonusContribution(
        _ annualBonusContribution: Double
    ) -> Bool {
        guard let context else { return false }
        guard PlanAmountValue.decimal(
            from: annualBonusContribution
        ) != nil else {
            errorMessage = "年度奖金结余必须是有效的非负金额。"
            return false
        }
        do {
            let metadata = try context.fetch(
                FetchDescriptor<AppMetadataEntity>()
            )
            let annualBonus: AppMetadataEntity
            if let existing = metadata.first(where: {
                $0.key == AppMetadataKey.confirmedAnnualBonusContribution
            }) {
                annualBonus = existing
            } else {
                annualBonus = AppMetadataEntity(
                    key: AppMetadataKey.confirmedAnnualBonusContribution
                )
                context.insert(annualBonus)
            }
            annualBonus.doubleValue = annualBonusContribution
            annualBonus.dateValue = .now

            try context.save()
            dataRevision &+= 1
            statusMessage = "接下来的年度奖金可投资结余已保存。"
            return true
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateAssumptions(
        withdrawalRate: Double,
        expectedReturn: Double,
        inflation: Double
    ) {
        guard let context else { return }
        guard withdrawalRate.isFinite,
              expectedReturn.isFinite,
              inflation.isFinite,
              (0.01...0.10).contains(withdrawalRate),
              (-0.99...1).contains(expectedReturn),
              (-0.99...1).contains(inflation) else {
            errorMessage = "提取率需填写 1% 到 10%；收益率和通胀率需填写 -99% 到 100%。"
            return
        }
        do {
            let descriptor = FetchDescriptor<FIRESettingsEntity>()
            let settings: FIRESettingsEntity
            if let existing = try context.fetch(descriptor).first {
                settings = existing
            } else {
                settings = FIRESettingsEntity()
                context.insert(settings)
            }
            settings.withdrawalRate = withdrawalRate
            settings.expectedReturn = expectedReturn
            settings.inflation = inflation
            settings.updatedAt = .now
            try context.save()
            statusMessage = "FIRE 假设已更新。"
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    func generateReport(
        reportDate requestedReportDate: Date? = nil,
        startsBackgroundActivity: Bool = true,
        transactions: [TransactionEntity],
        assetSnapshots: [AssetSnapshotEntity],
        positions: [PositionSnapshotEntity],
        instruments: [InstrumentEntity],
        liabilities: [LiabilityEntity],
        settings: [FIRESettingsEntity]
    ) async {
        guard let context else { return }
        guard !isWorking else {
            errorMessage = "正在处理其他操作，请稍后再生成月报。"
            return
        }
        guard let reportDate = requestedReportDate
                ?? persistedReportOperation?.reportMonth
                ?? MonthlyReportSelection.reportDate(from: transactions) else {
            errorMessage = "请先导入账单，再生成月度总结。"
            return
        }
        guard transactions.contains(where: {
            MonthlyReportSelection.isSameMonth(
                $0.transactionDate,
                reportDate
            )
        }) else {
            errorMessage = "所选月份没有可分析的账单。"
            return
        }
        guard let latest = MonthlyReportSelection.assetSnapshot(
            for: reportDate,
            from: assetSnapshots
        ) else {
            errorMessage = "请先保存一次完整资产快照，再生成月度总结。"
            return
        }
        let currentPacket = CoreDataAdapter(context: context).analysisPacket(
            transactions: transactions,
            latestAssetSnapshot: latest,
            allPositions: positions,
            instruments: instruments,
            liabilities: liabilities,
            settings: settings.first,
            reportDate: reportDate
        )

        isWorking = true
        var receivedRemoteReport = false
        var localMutationStarted = false
        var backgroundOperationID: UUID?
        var backgroundCompletedSuccessfully = false
        defer {
            isWorking = false
            if let backgroundOperationID {
                finishBackgroundProtection(
                    operationID: backgroundOperationID,
                    success: backgroundCompletedSuccessfully
                )
            }
        }
        do {
            let signature = try analysisPacketSignature(currentPacket)
            let operation: PendingReportOperation
            var isNewOperation = false
            if let pendingReportOperation,
               pendingReportOperation.packetSignature == signature {
                operation = pendingReportOperation
            } else if let persistedReportOperation,
                      persistedReportOperation.packetSignature == signature {
                operation = PendingReportOperation(
                    reportID: persistedReportOperation.reportID,
                    packetSignature: signature,
                    packet: currentPacket
                )
                pendingReportOperation = operation
            } else {
                if let staleOperation = persistedReportOperation {
                    guard bridge.connectedPeerName != nil else {
                        errorMessage =
                            "财务数据已变化。请先连接 Mac，清理上次未完成的月报后再生成新月报。"
                        return
                    }
                    do {
                        try await bridge.deleteReport(
                            reportID: staleOperation.reportID
                        )
                    } catch {
                        if BridgeOperationRecoveryPolicy.isRecoverable(error) {
                            statusMessage =
                                "财务数据已变化；旧月报任务仍安全保留。连接恢复后再试即可，无需重新核对短码。"
                        } else {
                            errorMessage =
                                "财务数据已变化，但 Mac 未能清理上次月报：\(error.localizedDescription) 未创建新的月报任务。"
                        }
                        return
                    }
                    finishBackgroundProtection(
                        operationID: staleOperation.reportID,
                        success: true
                    )
                    pendingReportOperation = nil
                }
                operation = PendingReportOperation(
                    reportID: UUID(),
                    packetSignature: signature,
                    packet: currentPacket
                )
                pendingReportOperation = operation
                isNewOperation = true
            }
            try persistReportOperation(operation)
            if try hasStoredReport(
                reportID: operation.reportID,
                context: context
            ) {
                finishBackgroundProtection(
                    operationID: operation.reportID,
                    success: true
                )
                clearPersistedReportOperation()
                statusMessage = "上次生成的月报已在本机，无需重复生成。"
                return
            }
            let backgroundController = BackgroundOperationController.shared
            let isSystemRecovery = backgroundController.isRecovering(
                operationID: operation.reportID
            )
            if ReportBackgroundActivityPolicy.shouldBegin(
                isNewOperation: isNewOperation,
                startsBackgroundActivity: startsBackgroundActivity,
                isSystemRecovery: isSystemRecovery
            ) {
                let started = beginBackgroundProtection(
                    operationID: operation.reportID,
                    title: "F.I.R.E 正在生成月报",
                    subtitle: "Mac 上的 Codex 正在分析脱敏数据",
                    completesSuccessfullyOnExpiration: true
                ) { [weak self] in
                    self?.cancelReportRequest(
                        reportID: operation.reportID
                    )
                    self?.backgroundRecoveryTasks[
                        operation.reportID
                    ]?.task.cancel()
                }
                if started {
                    backgroundOperationID = operation.reportID
                }
            }
            updateBackgroundProgress(
                operationID: operation.reportID,
                completed: 20,
                subtitle: "Mac 上的 Codex 正在分析脱敏数据"
            )
            try Task.checkCancellation()
            let response = try await requestReport(
                reportID: operation.reportID,
                packet: operation.packet
            )
            receivedRemoteReport = true
            try Task.checkCancellation()
            guard response.reportID == operation.reportID else {
                throw FIREBridgeError.invalidMessage("Mac 返回了不匹配的报告操作标识。")
            }
            var report = response.report
            report.monthlySummary = operation.packet.monthlySummary
            report.spendingAnalysis = operation.packet.spendingAnalysis
            try report.validate()
            updateBackgroundProgress(
                operationID: operation.reportID,
                completed: 85,
                subtitle: "分析完成，正在安全保存报告"
            )
            if try hasStoredReport(
                reportID: response.reportID,
                context: context
            ) {
                clearPersistedReportOperation()
                statusMessage = "月报已在本机，无需重复保存。"
                updateBackgroundProgress(
                    operationID: operation.reportID,
                    completed: 100,
                    subtitle: "月报已完成"
                )
                backgroundCompletedSuccessfully = true
                return
            }
            let data = try JSONEncoder().encode(report)
            context.insert(
                AnalysisReportEntity(
                    id: response.reportID,
                    bridgeReportID: response.reportID.uuidString,
                    codexThreadID: response.threadID,
                    title: monthlyReportTitle(
                        summary: operation.packet.monthlySummary
                    ),
                    reportJSON: data
                )
            )
            localMutationStarted = true
            try context.save()
            localMutationStarted = false
            clearPersistedReportOperation()
            statusMessage = "结构化报告已生成并保存在本机。"
            updateBackgroundProgress(
                operationID: operation.reportID,
                completed: 100,
                subtitle: "月报已完成"
            )
            backgroundCompletedSuccessfully = true
        } catch {
            if localMutationStarted {
                context.rollback()
            }
            if !receivedRemoteReport,
               BridgeOperationRecoveryPolicy.isRecoverable(error) {
                if let backgroundOperationID {
                    updateBackgroundProgress(
                        operationID: backgroundOperationID,
                        completed: 100,
                        subtitle: "任务已保存，连接 Mac 后继续"
                    )
                    backgroundCompletedSuccessfully = true
                }
                statusMessage =
                    "月报任务已保存；无需重新核对短码，回到前台并连接 Mac 后会用同一任务继续。"
                resumableWorkRevision &+= 1
                return
            }
            let originalMessage = error.localizedDescription
            if receivedRemoteReport,
               let reportID = pendingReportOperation?.reportID {
                do {
                    try await bridge.deleteReport(reportID: reportID)
                    clearPersistedReportOperation()
                    errorMessage = "\(originalMessage) 已回滚本机变更，并清理对应 Codex 会话。"
                } catch {
                    errorMessage = "\(originalMessage) 本机变更已回滚；Codex 会话清理失败，重试会复用同一报告操作。"
                }
            } else {
                errorMessage = originalMessage
            }
        }
    }

    func resumePersistedFollowUp() async {
        guard let record = persistedFollowUpOperation,
              let context else {
            return
        }
        do {
            if try context.fetch(
                FetchDescriptor<AnalysisAnswerEntity>()
            ).contains(where: { $0.id == record.operationID }) {
                clearPersistedFollowUpOperation()
                finishBackgroundProtection(
                    operationID: record.operationID,
                    success: true
                )
                return
            }
            guard let report = try context.fetch(
                FetchDescriptor<AnalysisReportEntity>()
            ).first(where: {
                $0.bridgeReportID == record.reportID.uuidString
            }) else {
                clearPersistedFollowUpOperation()
                finishBackgroundProtection(
                    operationID: record.operationID,
                    success: false
                )
                errorMessage = "上次追问对应的月报已不存在，已清理待办。"
                return
            }
            await followUp(report: report, question: record.question)
        } catch {
            errorMessage = "恢复上次追问失败：\(error.localizedDescription)"
        }
    }

    func followUp(report: AnalysisReportEntity, question: String) async {
        guard let context,
              let reportID = UUID(uuidString: report.bridgeReportID) else {
            errorMessage = "报告标识无效。"
            return
        }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let operationQuestion = PIIRedactor.redact(text: question)
        let operationKey = PendingFollowUpKey(
            reportID: reportID,
            question: operationQuestion
        )
        let operationID = pendingFollowUpOperations[operationKey] ?? UUID()
        if let stale = persistedFollowUpOperation,
           stale.operationID != operationID {
            finishBackgroundProtection(
                operationID: stale.operationID,
                success: false
            )
            pendingFollowUpOperations.removeValue(
                forKey: PendingFollowUpKey(
                    reportID: stale.reportID,
                    question: stale.question
                )
            )
        }
        pendingFollowUpOperations[operationKey] = operationID
        let persistedOperation = PendingFollowUpOperationRecordV1(
            operationID: operationID,
            reportID: reportID,
            question: operationQuestion
        )
        do {
            try pendingOperationStore.saveFollowUpOperation(
                persistedOperation
            )
            persistedFollowUpOperation = persistedOperation
        } catch {
            pendingFollowUpOperations.removeValue(forKey: operationKey)
            errorMessage = "无法保存追问断点，请检查设备存储空间后重试。"
            return
        }

        isWorking = true
        var localMutationStarted = false
        var backgroundCompletedSuccessfully = false
        beginBackgroundProtection(
            operationID: operationID,
            title: "F.I.R.E 正在回答追问",
            subtitle: "Mac 上的 Codex 正在分析本次问题",
            completesSuccessfullyOnExpiration: true
        ) { [weak self] in
            self?.cancelFollowUpRequest(operationID: operationID)
        }
        updateBackgroundProgress(
            operationID: operationID,
            completed: 20,
            subtitle: "Mac 上的 Codex 正在分析本次问题"
        )
        defer {
            isWorking = false
            finishBackgroundProtection(
                operationID: operationID,
                success: backgroundCompletedSuccessfully
            )
        }
        do {
            if try context.fetch(
                FetchDescriptor<AnalysisAnswerEntity>()
            ).contains(where: { $0.id == operationID }) {
                pendingFollowUpOperations.removeValue(forKey: operationKey)
                clearPersistedFollowUpOperation()
                statusMessage = "上次追问结果已在本机，无需重复保存。"
                backgroundCompletedSuccessfully = true
                return
            }
            let response = try await requestFollowUp(
                operationID: operationID,
                reportID: reportID,
                question: operationQuestion
            )
            guard response.operationID == operationID,
                  response.reportID == reportID,
                  response.answer.schemaVersion == "1.0",
                  !response.answer.answer.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else {
                throw FIREBridgeError.invalidStructuredOutput("追问回答不符合 AnalysisAnswerV1。")
            }
            updateBackgroundProgress(
                operationID: operationID,
                completed: 85,
                subtitle: "回答完成，正在安全保存"
            )
            let data = try JSONEncoder().encode(response.answer)
            context.insert(
                AnalysisAnswerEntity(
                    id: operationID,
                    reportID: report.id,
                    question: question,
                    answerJSON: data
                )
            )
            localMutationStarted = true
            try context.save()
            localMutationStarted = false
            pendingFollowUpOperations.removeValue(forKey: operationKey)
            clearPersistedFollowUpOperation()
            updateBackgroundProgress(
                operationID: operationID,
                completed: 100,
                subtitle: "追问回答已完成"
            )
            backgroundCompletedSuccessfully = true
        } catch {
            if localMutationStarted {
                context.rollback()
            }
            if BridgeOperationRecoveryPolicy.isRecoverable(error) {
                updateBackgroundProgress(
                    operationID: operationID,
                    completed: 100,
                    subtitle: "任务已保存，连接 Mac 后继续"
                )
                backgroundCompletedSuccessfully = true
                statusMessage =
                    "追问任务已保存；回到前台并连接 Mac 后会继续领取结果。"
                resumableWorkRevision &+= 1
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteReport(
        _ report: AnalysisReportEntity,
        answers: [AnalysisAnswerEntity]
    ) async {
        guard let context,
              let reportID = UUID(uuidString: report.bridgeReportID) else {
            return
        }
        isWorking = true
        defer { isWorking = false }
        var localMutationStarted = false
        do {
            try await bridge.deleteReport(reportID: reportID)
            if persistedFollowUpOperation?.reportID == reportID,
               let operationID = persistedFollowUpOperation?.operationID {
                finishBackgroundProtection(
                    operationID: operationID,
                    success: false
                )
                clearPersistedFollowUpOperation()
            }
            for answer in answers where answer.reportID == report.id {
                context.delete(answer)
            }
            context.delete(report)
            localMutationStarted = true
            try context.save()
            localMutationStarted = false
            statusMessage = "本机报告与问答记录均已删除。"
        } catch {
            if localMutationStarted {
                context.rollback()
            }
            errorMessage = error.localizedDescription
        }
    }

    private func persistReportOperation(
        _ operation: PendingReportOperation
    ) throws {
        let record = PendingReportOperationRecordV1(
            reportID: operation.reportID,
            packetSignature: operation.packetSignature,
            reportMonth: operation.packet.monthlySummary?.periodStart
        )
        do {
            try pendingOperationStore.saveReportOperation(record)
            persistedReportOperation = record
        } catch {
            throw PendingOperationStoreError.cannotSaveReport
        }
    }

    private func hasStoredReport(
        reportID: UUID,
        context: ModelContext
    ) throws -> Bool {
        try context.fetch(FetchDescriptor<AnalysisReportEntity>()).contains {
            $0.id == reportID
        }
    }

    private func clearPersistedReportOperation() {
        pendingReportOperation = nil
        persistedReportOperation = nil
        do {
            try pendingOperationStore.clearReportOperation()
        } catch {
            errorMessage = "月报已完成，但未能清理本机断点记录。"
        }
    }

    private func clearPersistedFollowUpOperation() {
        if let record = persistedFollowUpOperation {
            pendingFollowUpOperations.removeValue(
                forKey: PendingFollowUpKey(
                    reportID: record.reportID,
                    question: record.question
                )
            )
        }
        persistedFollowUpOperation = nil
        do {
            try pendingOperationStore.clearFollowUpOperation()
        } catch {
            errorMessage = "追问已完成，但未能清理本机断点记录。"
        }
    }

    private func analysisPacketSignature(
        _ packet: FIRECore.AnalysisPacketV1
    ) throws -> Data {
        let normalized = packet.normalizedForOperationFingerprint()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(normalized)))
    }

    private func monthlyReportTitle(
        summary: FIRECore.MonthlyFinancialSummaryV1?
    ) -> String {
        guard let summary else { return "月度财务分析" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy 年 M 月财务总结"
        return formatter.string(from: summary.periodStart)
    }

    private static func snapshotIsEarlier(
        _ lhs: AssetSnapshotEntity,
        _ rhs: AssetSnapshotEntity
    ) -> Bool {
        if lhs.capturedAt == rhs.capturedAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.capturedAt < rhs.capturedAt
    }
}
