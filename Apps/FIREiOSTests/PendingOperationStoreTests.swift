import CryptoKit
import FIREBridgeKit
import XCTest
@testable import FIRE

final class PendingOperationStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    @MainActor
    func testStatusMessageAutomaticallyDismisses() async throws {
        let state = FIREAppState(
            pendingOperationStore: makeStore(),
            statusMessageVisibilityDuration: .milliseconds(20)
        )

        state.statusMessage = "已保存"
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertNil(state.statusMessage)
    }

    @MainActor
    func testNewStatusMessageRestartsDismissalTimer() async throws {
        let state = FIREAppState(
            pendingOperationStore: makeStore(),
            statusMessageVisibilityDuration: .milliseconds(60)
        )

        state.statusMessage = "第一条"
        try await Task.sleep(for: .milliseconds(40))
        state.statusMessage = "第二条"
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(state.statusMessage, "第二条")

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(state.statusMessage)
    }

    func testAssetRecognitionPersistenceContainsOnlyRedactedOCRAndCandidateFields()
        throws {
        let store = makeStore()
        let record = makeAssetRecord(
            lineText:
                "姓名：张三，手机 13800138000，邮箱 zhangsan@example.com，卡号 6222020202020202"
        )

        try store.saveAssetRecognition(record)

        let data = try Data(contentsOf: store.fileURL)
        let persistedText = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        XCTAssertFalse(persistedText.contains("张三"))
        XCTAssertFalse(persistedText.contains("13800138000"))
        XCTAssertFalse(persistedText.contains("zhangsan@example.com"))
        XCTAssertFalse(persistedText.contains("6222020202020202"))
        XCTAssertFalse(persistedText.contains("rawEvidence"))
        XCTAssertFalse(persistedText.contains("imageData"))
        XCTAssertFalse(persistedText.contains("imagePath"))
        XCTAssertFalse(persistedText.contains(".jpg"))
        XCTAssertTrue(persistedText.contains("[已移除]"))

        let restored = try XCTUnwrap(store.loadAssetRecognition())
        XCTAssertEqual(restored.operationID, record.operationID)
        XCTAssertEqual(restored.imageCount, 1)
        XCTAssertEqual(restored.fallbackCandidates.count, 1)
    }

    @MainActor
    func testAssetRecognitionStateRestoresAfterRestartAndClearRemovesIt()
        throws {
        let store = makeStore()
        let retained = candidate(
            id: UUID(),
            imageIndex: 0,
            name: "已识别基金",
            code: "000001"
        )
        let record = PendingAssetRecognitionRecordV1(
            operationID: UUID(),
            batchID: UUID(),
            imageCount: 1,
            imageIndexOffset: 2,
            lines: [line(text: "新增基金 000002 1000.00")],
            fallbackCandidates: [
                candidate(
                    id: UUID(),
                    imageIndex: 0,
                    name: "新增基金",
                    code: "000002"
                ),
            ],
            retainedCandidates: [retained]
        )
        try store.saveAssetRecognition(record)

        let restoredState = FIREAppState(pendingOperationStore: store)

        XCTAssertEqual(
            restoredState.assetRecognitionState,
            .awaitingBridgeDecision
        )
        XCTAssertEqual(restoredState.assetRecognitionImageCount, 3)
        XCTAssertTrue(restoredState.assetRecognitionRequiresBridgeConnection)
        XCTAssertTrue(restoredState.canUseLocalAssetRecognitionFallback)
        XCTAssertEqual(restoredState.ocrCandidates.map(\.id), [retained.id])
        XCTAssertEqual(restoredState.aggregatedPositions.count, 1)
        XCTAssertEqual(
            try store.loadAssetRecognition()?.operationID,
            record.operationID
        )

        restoredState.clearAssetRecognition()
        let relaunchedState = FIREAppState(pendingOperationStore: store)

        XCTAssertEqual(relaunchedState.assetRecognitionState, .idle)
        XCTAssertEqual(relaunchedState.assetRecognitionImageCount, 0)
        XCTAssertNil(try store.loadAssetRecognition())
    }

    @MainActor
    func testReportMetadataRestoresWithoutPersistingAnalysisPacket() throws {
        let store = makeStore()
        let reportMonth = Date(timeIntervalSince1970: 1_780_243_200)
        let record = PendingReportOperationRecordV1(
            reportID: UUID(),
            packetSignature: Data(SHA256.hash(data: Data("packet".utf8))),
            reportMonth: reportMonth
        )
        try store.saveReportOperation(record)

        let relaunchedState = FIREAppState(
            pendingOperationStore: PendingOperationStore(
                fileURL: store.fileURL
            )
        )

        XCTAssertEqual(relaunchedState.persistedReportOperation, record)
        let persistedText = try String(
            contentsOf: store.fileURL,
            encoding: .utf8
        )
        XCTAssertFalse(persistedText.contains("transactions"))
        XCTAssertFalse(persistedText.contains("assetSnapshot"))
        XCTAssertFalse(persistedText.contains("monthlySummary"))
        XCTAssertTrue(persistedText.contains(record.reportID.uuidString))
        XCTAssertEqual(
            try store.loadReportOperation()?.reportMonth,
            reportMonth
        )
    }

    func testPendingOperationFileIsExcludedFromDeviceBackup() throws {
        let store = makeStore()
        try store.saveReportOperation(
            PendingReportOperationRecordV1(
                reportID: UUID(),
                packetSignature: Data(
                    SHA256.hash(data: Data("packet".utf8))
                )
            )
        )

        let values = try store.fileURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    @MainActor
    func testFollowUpRestoresWithStableIDAndRedactedQuestion() throws {
        let store = makeStore()
        let record = PendingFollowUpOperationRecordV1(
            operationID: UUID(),
            reportID: UUID(),
            question: "姓名：张三，手机号 13800138000，资产变化是什么？"
        )

        try store.saveFollowUpOperation(record)

        let data = try Data(contentsOf: store.fileURL)
        let persistedText = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        XCTAssertFalse(persistedText.contains("张三"))
        XCTAssertFalse(persistedText.contains("13800138000"))
        XCTAssertTrue(persistedText.contains("[已移除]"))

        let state = FIREAppState(pendingOperationStore: store)
        XCTAssertEqual(
            state.pendingFollowUpOperationID,
            record.operationID
        )
        XCTAssertEqual(
            state.persistedFollowUpOperation,
            try store.loadFollowUpOperation()
        )

        try store.clearFollowUpOperation()
        XCTAssertNil(try store.loadFollowUpOperation())
    }

    func testPendingBridgeWorkPrioritizesUnattemptedAsset() {
        let assetID = UUID()
        let reportID = UUID()

        XCTAssertEqual(
            PendingBridgeWorkSelector.next(
                assetOperationID: assetID,
                assetIsAwaiting: true,
                lastAttemptedAssetID: nil,
                reportOperationID: reportID,
                lastAttemptedReportID: nil,
                isWorking: false
            ),
            .asset(assetID)
        )
    }

    func testPendingBridgeWorkDoesNotRetryWhileAppIsBackgrounded() {
        XCTAssertNil(
            PendingBridgeWorkSelector.next(
                assetOperationID: nil,
                assetIsAwaiting: false,
                lastAttemptedAssetID: nil,
                reportOperationID: UUID(),
                lastAttemptedReportID: nil,
                isWorking: false,
                isSceneActive: false
            )
        )
    }

    func testPendingBridgeWorkDoesNotCompeteWithSystemRecovery() {
        let reportID = UUID()

        XCTAssertNil(
            PendingBridgeWorkSelector.next(
                assetOperationID: nil,
                assetIsAwaiting: false,
                lastAttemptedAssetID: nil,
                reportOperationID: reportID,
                lastAttemptedReportID: nil,
                recoveringOperationIDs: [reportID],
                isWorking: false
            )
        )
    }

    func testOnlyNewUserInitiatedReportSubmitsVisibleBackgroundTask() {
        XCTAssertTrue(
            ReportBackgroundActivityPolicy.shouldBegin(
                isNewOperation: true,
                startsBackgroundActivity: true,
                isSystemRecovery: false
            )
        )
        XCTAssertFalse(
            ReportBackgroundActivityPolicy.shouldBegin(
                isNewOperation: false,
                startsBackgroundActivity: true,
                isSystemRecovery: false
            )
        )
        XCTAssertTrue(
            ReportBackgroundActivityPolicy.shouldBegin(
                isNewOperation: false,
                startsBackgroundActivity: false,
                isSystemRecovery: true
            )
        )
    }

    func testAttemptedAssetDoesNotStarvePendingReport() {
        let assetID = UUID()
        let reportID = UUID()

        XCTAssertEqual(
            PendingBridgeWorkSelector.next(
                assetOperationID: assetID,
                assetIsAwaiting: true,
                lastAttemptedAssetID: assetID,
                reportOperationID: reportID,
                lastAttemptedReportID: nil,
                isWorking: false
            ),
            .report(reportID)
        )
    }

    func testNewAssetOperationIsAttemptedAfterEarlierFailure() {
        let oldAssetID = UUID()
        let newAssetID = UUID()

        XCTAssertEqual(
            PendingBridgeWorkSelector.next(
                assetOperationID: newAssetID,
                assetIsAwaiting: true,
                lastAttemptedAssetID: oldAssetID,
                reportOperationID: nil,
                lastAttemptedReportID: nil,
                isWorking: false
            ),
            .asset(newAssetID)
        )
    }

    func testFollowUpResumesAfterEarlierWorkWasAlreadyAttempted() {
        let assetID = UUID()
        let followUpID = UUID()

        XCTAssertEqual(
            PendingBridgeWorkSelector.next(
                assetOperationID: assetID,
                assetIsAwaiting: true,
                lastAttemptedAssetID: assetID,
                reportOperationID: nil,
                lastAttemptedReportID: nil,
                followUpOperationID: followUpID,
                lastAttemptedFollowUpID: nil,
                isWorking: false
            ),
            .followUp(followUpID)
        )
    }

    func testReconnectStartsOneNewBoundedRetryCycle() {
        let assetID = UUID()
        let reportID = UUID()
        let followUpID = UUID()
        var gate = PendingBridgeRetryGate()

        gate.markAttempted(.asset(assetID))
        gate.markAttempted(.report(reportID))
        gate.markAttempted(.followUp(followUpID))
        XCTAssertNil(
            PendingBridgeWorkSelector.next(
                assetOperationID: assetID,
                assetIsAwaiting: true,
                lastAttemptedAssetID: gate.lastAttemptedAssetID,
                reportOperationID: reportID,
                lastAttemptedReportID: gate.lastAttemptedReportID,
                followUpOperationID: followUpID,
                lastAttemptedFollowUpID: gate.lastAttemptedFollowUpID,
                isWorking: false
            )
        )

        gate.beginConnectionCycle()

        XCTAssertEqual(
            PendingBridgeWorkSelector.next(
                assetOperationID: assetID,
                assetIsAwaiting: true,
                lastAttemptedAssetID: gate.lastAttemptedAssetID,
                reportOperationID: reportID,
                lastAttemptedReportID: gate.lastAttemptedReportID,
                followUpOperationID: followUpID,
                lastAttemptedFollowUpID: gate.lastAttemptedFollowUpID,
                isWorking: false
            ),
            .asset(assetID)
        )
    }

    func testRetryGateAdvancesWithoutStarvingLaterWork() {
        let assetID = UUID()
        let reportID = UUID()
        let followUpID = UUID()
        var gate = PendingBridgeRetryGate()

        gate.markAttempted(.asset(assetID))
        XCTAssertEqual(
            PendingBridgeWorkSelector.next(
                assetOperationID: assetID,
                assetIsAwaiting: true,
                lastAttemptedAssetID: gate.lastAttemptedAssetID,
                reportOperationID: reportID,
                lastAttemptedReportID: gate.lastAttemptedReportID,
                followUpOperationID: followUpID,
                lastAttemptedFollowUpID: gate.lastAttemptedFollowUpID,
                isWorking: false
            ),
            .report(reportID)
        )

        gate.markAttempted(.report(reportID))
        XCTAssertEqual(
            PendingBridgeWorkSelector.next(
                assetOperationID: assetID,
                assetIsAwaiting: true,
                lastAttemptedAssetID: gate.lastAttemptedAssetID,
                reportOperationID: reportID,
                lastAttemptedReportID: gate.lastAttemptedReportID,
                followUpOperationID: followUpID,
                lastAttemptedFollowUpID: gate.lastAttemptedFollowUpID,
                isWorking: false
            ),
            .followUp(followUpID)
        )
    }

    private func makeStore() -> PendingOperationStore {
        PendingOperationStore(
            fileURL: temporaryDirectory
                .appendingPathComponent("pending-operations.json")
        )
    }

    private func makeAssetRecord(
        lineText: String
    ) -> PendingAssetRecognitionRecordV1 {
        PendingAssetRecognitionRecordV1(
            operationID: UUID(),
            batchID: UUID(),
            imageCount: 1,
            imageIndexOffset: nil,
            lines: [line(text: lineText)],
            fallbackCandidates: [
                candidate(
                    id: UUID(),
                    imageIndex: 0,
                    name: "姓名：张三的基金",
                    code: "000001"
                ),
            ],
            retainedCandidates: []
        )
    }

    private func line(text: String) -> AssetOCRLineV1 {
        AssetOCRLineV1(
            imageIndex: 0,
            text: text,
            confidence: 0.9,
            boundingBox: AssetOCRBoundingBoxV1(
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.04
            )
        )
    }

    private func candidate(
        id: UUID,
        imageIndex: Int,
        name: String,
        code: String
    ) -> OCRPositionCandidate {
        OCRPositionCandidate(
            id: id,
            sourceImageIndex: imageIndex,
            productName: name,
            productCode: code,
            kind: .fund,
            currency: "CNY",
            originalMarketValue: 1_000,
            confidence: 0.8,
            requiresMergeConfirmation: false,
            rawEvidence: "不应持久化的原始 OCR 证据",
            verification: .localOnly
        )
    }
}
