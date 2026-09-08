import FIRECore
import XCTest
@testable import FIRE

final class PositionAggregationServiceTests: XCTestCase {
    // Product names, codes, amounts, and OCR text in these fixtures are synthetic.
    private struct PhotoReference: Equatable {
        let identifier: String?
        let value: Int
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private let service = PositionAggregationService()

    func testAssetOCRRedactionRunsBeforePersistingFallbackEvidence() {
        let input =
            "姓名：张三 · 账户 6222 0200 1234 5678 · 手机 13812345678 · test@example.com"

        let redacted = AssetOCRService.redactPersonalInformation(in: input)

        XCTAssertFalse(redacted.contains("张三"))
        XCTAssertFalse(redacted.contains("6222 0200 1234 5678"))
        XCTAssertFalse(redacted.contains("13812345678"))
        XCTAssertFalse(redacted.contains("test@example.com"))
        XCTAssertTrue(redacted.contains("[已移除]"))
    }

    func testAssetOCRCancellationCoordinatorFinishesOnlyOnce() async throws {
        let coordinator = AssetOCRCancellationCoordinator<Int>()

        XCTAssertTrue(coordinator.finish(.success(42)))
        XCTAssertFalse(coordinator.finish(.success(99)))

        let result = try await withCheckedThrowingContinuation { continuation in
            XCTAssertFalse(coordinator.installContinuation(continuation))
        }
        XCTAssertEqual(result, 42)
    }

    func testAssetOCRCancellationCoordinatorCancelsLateInstalledRequestOnce() async {
        let coordinator = AssetOCRCancellationCoordinator<Int>()
        let cancellationCounter = LockedCounter()

        coordinator.cancel()
        coordinator.cancel()
        XCTAssertFalse(
            coordinator.installCancellationAction {
                cancellationCounter.increment()
            }
        )

        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(coordinator.installContinuation(continuation))
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(cancellationCounter.value, 1)
            XCTAssertFalse(coordinator.finish(.success(42)))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAssetOCRCancellationCoordinatorCancelsInstalledRequestOnce() async {
        let coordinator = AssetOCRCancellationCoordinator<Int>()
        let cancellationCounter = LockedCounter()

        XCTAssertTrue(
            coordinator.installCancellationAction {
                cancellationCounter.increment()
            }
        )
        coordinator.cancel()
        coordinator.cancel()

        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(coordinator.installContinuation(continuation))
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(cancellationCounter.value, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPhotoSelectionAccumulatorKeepsExistingAndAddsNewItems() {
        let first = PhotoReference(identifier: "first", value: 1)
        let second = PhotoReference(identifier: "second", value: 2)

        let merged = PhotoSelectionAccumulator.appendingUnique(
            [second],
            to: [first],
            identifier: \.identifier
        )

        XCTAssertEqual(merged, [first, second])
    }

    func testPhotoSelectionAccumulatorDoesNotAddDuplicateIdentifiers() {
        let original = PhotoReference(identifier: "same", value: 1)
        let duplicate = PhotoReference(identifier: "same", value: 2)

        let merged = PhotoSelectionAccumulator.appendingUnique(
            [duplicate],
            to: [original],
            identifier: \.identifier
        )

        XCTAssertEqual(merged, [original])
    }

    func testPhotoSelectionAccumulatorUsesEqualityWhenIdentifierIsMissing() {
        let first = PhotoReference(identifier: nil, value: 1)
        let second = PhotoReference(identifier: nil, value: 2)

        let merged = PhotoSelectionAccumulator.appendingUnique(
            [first, second],
            to: [first],
            identifier: \.identifier
        )

        XCTAssertEqual(merged, [first, second])
    }

    func testCandidateAccumulatorPreservesManualEditsWhenAppending() {
        let corrected = OCRPositionCandidate(
            sourceImageIndex: 0,
            productName: "手工修正产品",
            productCode: "000001",
            kind: .stock,
            currency: "CNY",
            originalMarketValue: 12_000,
            confidence: 0.8,
            requiresMergeConfirmation: false,
            rawEvidence: "人工修正",
            verification: .manual
        )
        let addition = OCRPositionCandidate(
            sourceImageIndex: 0,
            productName: "新增产品",
            productCode: "000002",
            kind: .fund,
            currency: "CNY",
            originalMarketValue: 8_000,
            confidence: 0.9,
            requiresMergeConfirmation: false,
            rawEvidence: "第二张截图"
        )
        let matchingAddition = OCRPositionCandidate(
            sourceImageIndex: 1,
            productName: "新增截图里的同一产品",
            productCode: "000001",
            kind: .stock,
            currency: "CNY",
            originalMarketValue: 3_000,
            confidence: 0.9,
            requiresMergeConfirmation: false,
            rawEvidence: "第三张截图"
        )

        let merged = AssetRecognitionCandidateAccumulator.merging(
            existing: [corrected],
            additions: [addition, matchingAddition],
            imageIndexOffset: 2
        )

        XCTAssertEqual(merged[0], corrected)
        XCTAssertEqual(merged[1].id, addition.id)
        XCTAssertEqual(merged[1].sourceImageIndex, 2)
        XCTAssertEqual(merged[2].id, matchingAddition.id)
        XCTAssertEqual(merged[2].sourceImageIndex, 3)

        let aggregated = service.aggregate(merged)
        let matchedPosition = aggregated.first { $0.code == "000001" }
        XCTAssertEqual(matchedPosition?.originalMarketValue, 15_000)
        XCTAssertEqual(matchedPosition?.sourceCount, 2)
        XCTAssertEqual(
            Set(matchedPosition?.candidateIDs ?? []),
            Set([corrected.id, matchingAddition.id])
        )
    }

    func testCandidateAccumulatorReplacesCandidatesForNewSelection() {
        let existing = codedCandidate(value: 1_000)
        let replacement = codedCandidate(value: 2_000)

        let merged = AssetRecognitionCandidateAccumulator.merging(
            existing: [existing],
            additions: [replacement],
            imageIndexOffset: nil
        )

        XCTAssertEqual(merged, [replacement])
    }

    func testSameNamedUncodedCandidatesRemainSeparateWithoutExplicitMerge() throws {
        let positions = service.aggregate([
            candidate(value: 100),
            candidate(value: 200),
        ])

        let plan = try service.makeSavePlan(
            positions: positions,
            uncodedResolutions: Dictionary(
                uniqueKeysWithValues: positions.map {
                    ($0.id, .createNewInstrument)
                }
            )
        )

        XCTAssertEqual(plan.positions.count, 2)
        XCTAssertEqual(
            plan.positions.reduce(0) { $0 + $1.originalMarketValue },
            300
        )
    }

    func testExplicitSameBatchCanonicalMergesValueAndSourceCount() throws {
        let firstCandidate = candidate(value: 100)
        let secondCandidate = candidate(value: 200)
        let positions = service.aggregate([firstCandidate, secondCandidate])
        let canonical = try XCTUnwrap(positions.first)
        let source = try XCTUnwrap(positions.first { $0.id != canonical.id })

        let plan = try service.makeSavePlan(
            positions: positions,
            uncodedResolutions: [
                canonical.id: .createNewInstrument,
                source.id: .batchCanonical(canonical.id),
            ]
        )

        let merged = try XCTUnwrap(plan.positions.first)
        XCTAssertEqual(plan.positions.count, 1)
        XCTAssertEqual(merged.id, canonical.id)
        XCTAssertEqual(merged.originalMarketValue, 300)
        XCTAssertEqual(merged.sourceCount, 2)
        XCTAssertEqual(
            Set(merged.candidateIDs),
            Set([firstCandidate.id, secondCandidate.id])
        )
        XCTAssertEqual(
            plan.uncodedResolutions[canonical.id],
            .createNewInstrument
        )
    }

    func testBatchMergeRejectsDifferentName() throws {
        let positions = service.aggregate([
            candidate(name: "现金管理 A", value: 100),
            candidate(name: "现金管理 B", value: 200),
        ])
        let canonical = try XCTUnwrap(positions.first)
        let source = try XCTUnwrap(positions.first { $0.id != canonical.id })

        XCTAssertThrowsError(
            try service.makeSavePlan(
                positions: positions,
                uncodedResolutions: [
                    canonical.id: .createNewInstrument,
                    source.id: .batchCanonical(canonical.id),
                ]
            )
        )
    }

    @MainActor
    func testAggregateCorrectionReplacesGroupedCandidatesWithOneCorrectedPosition() throws {
        let first = codedCandidate(value: 100)
        let second = codedCandidate(value: 200)
        let state = FIREAppState()
        state.ocrCandidates = [first, second]
        state.aggregatedPositions = service.aggregate(state.ocrCandidates)
        let grouped = try XCTUnwrap(state.aggregatedPositions.first)

        state.updateAggregatedPosition(
            id: grouped.id,
            name: "示例宽基 ETF",
            code: "599991",
            kind: .fund,
            currency: "CNY",
            originalMarketValue: 360
        )

        let corrected = try XCTUnwrap(state.ocrCandidates.first)
        XCTAssertEqual(state.ocrCandidates.count, 1)
        XCTAssertEqual(corrected.id, first.id)
        XCTAssertEqual(corrected.productName, "示例宽基 ETF")
        XCTAssertEqual(corrected.productCode, "599991")
        XCTAssertEqual(corrected.originalMarketValue, 360)
        XCTAssertEqual(corrected.verification, .manual)
        XCTAssertEqual(state.aggregatedPositions.count, 1)
        XCTAssertEqual(state.aggregatedPositions.first?.originalMarketValue, 360)
    }

    func testOnlineVerificationStateIsPreservedInAggregation() throws {
        let verified = OCRPositionCandidate(
            sourceImageIndex: 0,
            productName: "示例健康混合A",
            productCode: "999991",
            kind: .fund,
            currency: "CNY",
            originalMarketValue: 1_234.56,
            confidence: 0.93,
            requiresMergeConfirmation: false,
            rawEvidence: "示例健康混合A · 1,234.56",
            verification: .verified
        )

        let position = try XCTUnwrap(service.aggregate([verified]).first)

        XCTAssertEqual(position.verification, .verified)
        XCTAssertFalse(position.requiresConfirmation)
    }

    func testLocalGeometryParserPairsNamesWithMarketValueColumn() async {
        let lines = [
            line("名称", x: 0.06, y: 0.74, width: 0.07),
            line("金额/昨日收益", x: 0.47, y: 0.74, width: 0.20),
            line("持有收益/率", x: 0.78, y: 0.74, width: 0.17),
            line("示例健康混合A", x: 0.06, y: 0.68, width: 0.33),
            line("1,234.56", x: 0.50, y: 0.68, width: 0.17),
            line("34.56", x: 0.80, y: 0.68, width: 0.14),
            line("示例健康混合C", x: 0.06, y: 0.58, width: 0.33),
            line("2,345.67", x: 0.50, y: 0.58, width: 0.17),
            line("45.67", x: 0.78, y: 0.58, width: 0.17),
            line("示例全球创新科", x: 0.06, y: 0.49, width: 0.37),
            line("技指数（QDII-⋯", x: 0.06, y: 0.467, width: 0.36),
            line("3,456.78", x: 0.50, y: 0.49, width: 0.17),
            line("56.78", x: 0.77, y: 0.49, width: 0.18),
            line("投资锦囊 示例市场观察资讯", x: 0.08, y: 0.42, width: 0.80),
            line("示例消费优选混合", x: 0.06, y: 0.34, width: 0.31),
            line("4,567.89", x: 0.50, y: 0.34, width: 0.17),
            line("67.89", x: 0.75, y: 0.34, width: 0.19),
            line("示例价值精选混合", x: 0.06, y: 0.16, width: 0.34),
            line("5,678.90", x: 0.50, y: 0.16, width: 0.17),
            line("78.90", x: 0.77, y: 0.16, width: 0.17),
            line("60", x: 0.34, y: 0.06, width: 0.06),
        ]

        let candidates = await AssetOCRService().parse(
            lines,
            imageIndex: 0
        )

        XCTAssertEqual(
            candidates.map(\.productName),
            [
                "示例健康混合A",
                "示例健康混合C",
                "示例全球创新科技指数（QDII-⋯",
                "示例消费优选混合",
                "示例价值精选混合",
            ]
        )
        XCTAssertEqual(
            candidates.map(\.originalMarketValue),
            [1_234.56, 2_345.67, 3_456.78, 4_567.89, 5_678.90]
        )
        XCTAssertTrue(candidates.allSatisfy(\.requiresMergeConfirmation))
        XCTAssertTrue(candidates.allSatisfy { $0.verification == .localOnly })
    }

    func testLocalGeometryParserNormalizesHongKongNumericCodes() async {
        let lines = [
            line("名称", x: 0.06, y: 0.74, width: 0.07),
            line("市值", x: 0.50, y: 0.74, width: 0.10),
            line("示例香港ETF 9991", x: 0.06, y: 0.68, width: 0.31),
            line("10,000.00", x: 0.50, y: 0.68, width: 0.17),
            line("示例香港ETF 09991", x: 0.06, y: 0.58, width: 0.32),
            line("20,000.00", x: 0.50, y: 0.58, width: 0.17),
            line("示例宽基ETF 599991", x: 0.06, y: 0.48, width: 0.38),
            line("30,000.00", x: 0.50, y: 0.48, width: 0.17),
        ]

        let candidates = await AssetOCRService().parse(lines, imageIndex: 0)

        XCTAssertEqual(
            candidates.map(\.productName),
            ["示例香港ETF", "示例香港ETF", "示例宽基ETF"]
        )
        XCTAssertEqual(
            candidates.map(\.productCode),
            ["09991", "09991", "599991"]
        )
    }

    func testLocalGeometryParserRejectsYearAndAmountCodeNoise() async {
        let lines = [
            line("名称", x: 0.06, y: 0.74, width: 0.07),
            line("市值", x: 0.50, y: 0.74, width: 0.10),
            line("年度策略 2026", x: 0.06, y: 0.68, width: 0.28),
            line("10,000.00", x: 0.50, y: 0.68, width: 0.17),
            line("现金管理 ¥4321.00", x: 0.06, y: 0.58, width: 0.30),
            line("20,000.00", x: 0.50, y: 0.58, width: 0.17),
        ]

        let candidates = await AssetOCRService().parse(lines, imageIndex: 0)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.productCode == nil })
    }

    @MainActor
    func testDeletingAggregatedPositionRemovesAllBackingCandidates() throws {
        let first = codedCandidate(value: 100)
        let second = codedCandidate(value: 200)
        let remaining = OCRPositionCandidate(
            sourceImageIndex: 1,
            productName: "现金管理",
            productCode: "000001",
            kind: .fund,
            currency: "CNY",
            originalMarketValue: 500,
            confidence: 0.9,
            requiresMergeConfirmation: false,
            rawEvidence: "现金管理 000001"
        )
        let state = FIREAppState()
        state.ocrCandidates = [first, second, remaining]
        state.aggregatedPositions = service.aggregate(state.ocrCandidates)
        let grouped = try XCTUnwrap(
            state.aggregatedPositions.first { $0.code == "599991" }
        )

        state.deleteAggregatedPosition(id: grouped.id)

        XCTAssertEqual(state.ocrCandidates.map(\.id), [remaining.id])
        XCTAssertEqual(state.aggregatedPositions.count, 1)
        XCTAssertEqual(state.aggregatedPositions.first?.code, "000001")
        XCTAssertTrue(state.isAssetRecognitionBatchValid)
        XCTAssertEqual(state.assetRecognitionState, .valid)
    }

    @MainActor
    func testDeletingLastAggregatedPositionKeepsBatchInvalid() throws {
        let onlyCandidate = codedCandidate(value: 100)
        let state = FIREAppState()
        state.ocrCandidates = [onlyCandidate]
        state.aggregatedPositions = service.aggregate(state.ocrCandidates)
        let onlyPosition = try XCTUnwrap(state.aggregatedPositions.first)

        state.deleteAggregatedPosition(id: onlyPosition.id)

        XCTAssertTrue(state.ocrCandidates.isEmpty)
        XCTAssertTrue(state.aggregatedPositions.isEmpty)
        XCTAssertFalse(state.isAssetRecognitionBatchValid)
        XCTAssertEqual(state.assetRecognitionState, .invalid)
    }

    @MainActor
    func testClearAssetRecognitionRemovesEntireTransientBatch() {
        let state = FIREAppState()
        state.ocrCandidates = [codedCandidate(value: 100)]
        state.aggregatedPositions = service.aggregate(state.ocrCandidates)

        state.clearAssetRecognition()

        XCTAssertTrue(state.ocrCandidates.isEmpty)
        XCTAssertTrue(state.aggregatedPositions.isEmpty)
        XCTAssertFalse(state.isAssetRecognitionBatchValid)
        XCTAssertEqual(state.assetRecognitionState, .idle)
        XCTAssertEqual(state.assetRecognitionImageCount, 0)
    }

    @MainActor
    func testAssetRecognitionFailureOnlyRequestsBridgeWhenConnectionIsMissing() {
        XCTAssertTrue(
            FIREAppState.shouldRequestBridgeConnection(
                after: BridgeConnectionError.invalidResponse,
                bridgeConnected: false
            )
        )
        XCTAssertTrue(
            FIREAppState.shouldRequestBridgeConnection(
                after: BridgeConnectionError.authenticationRequired,
                bridgeConnected: true
            )
        )
        XCTAssertTrue(
            FIREAppState.shouldRequestBridgeConnection(
                after: BridgeConnectionError.notConnected,
                bridgeConnected: true
            )
        )
        XCTAssertFalse(
            FIREAppState.shouldRequestBridgeConnection(
                after: BridgeConnectionError.timedOut,
                bridgeConnected: true
            )
        )
        XCTAssertFalse(
            FIREAppState.shouldRequestBridgeConnection(
                after: BridgeConnectionError.invalidResponse,
                bridgeConnected: true
            )
        )
        XCTAssertFalse(
            FIREAppState.shouldRequestBridgeConnection(
                after: BridgeConnectionError.sendFailed(
                    NSError(domain: NSURLErrorDomain, code: -1009)
                ),
                bridgeConnected: true
            )
        )
    }

    private func candidate(
        name: String = "现金管理",
        value: Double
    ) -> OCRPositionCandidate {
        OCRPositionCandidate(
            sourceImageIndex: 0,
            productName: name,
            kind: .fund,
            currency: "CNY",
            originalMarketValue: value,
            confidence: 0.9,
            requiresMergeConfirmation: true,
            rawEvidence: name
        )
    }

    private func codedCandidate(value: Double) -> OCRPositionCandidate {
        OCRPositionCandidate(
            sourceImageIndex: 0,
            productName: "示例宽基",
            productCode: "599991",
            kind: .fund,
            currency: "CNY",
            originalMarketValue: value,
            confidence: 0.9,
            requiresMergeConfirmation: false,
            rawEvidence: "示例宽基 599991 \(value)"
        )
    }

    private func line(
        _ text: String,
        x: Double,
        y: Double,
        width: Double
    ) -> RecognizedLine {
        RecognizedLine(
            text: text,
            confidence: 0.95,
            boundingBox: .init(
                x: x,
                y: y,
                width: width,
                height: 0.02
            )
        )
    }
}
