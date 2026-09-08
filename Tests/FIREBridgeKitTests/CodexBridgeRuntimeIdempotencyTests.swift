#if os(macOS)
import FIRECore
import Foundation
import XCTest
@testable import FIREBridgeKit

// Product names, identifiers, API responses, and amounts are synthetic test fixtures.
final class CodexBridgeRuntimeIdempotencyTests: XCTestCase {
    func testReportRetryReusesPersistedEphemeralResultAndTurn() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        let packet = makePacket()

        async let first = fixture.runtime.generateReport(
            reportID: reportID,
            packet: packet
        )
        async let second = fixture.runtime.generateReport(
            reportID: reportID,
            packet: packet
        )
        let responses = try await (first, second)

        XCTAssertEqual(responses.0.report, responses.1.report)
        var metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.startedThreads, 0)
        XCTAssertEqual(metrics.ephemeralThreads, 1)
        XCTAssertEqual(metrics.unsubscribedThreads, 1)
        XCTAssertEqual(metrics.reportTurns, 1)

        let restartedClient = FakeCodexAppServer()
        let restartedRuntime = try fixture.makeRestartedRuntime(
            client: restartedClient
        )
        let cached = try await restartedRuntime.generateReport(
            reportID: reportID,
            packet: packet
        )

        XCTAssertEqual(cached.report, responses.0.report)
        metrics = await restartedClient.metrics()
        XCTAssertEqual(metrics.startedThreads, 0)
        XCTAssertEqual(metrics.reportTurns, 0)
        await fixture.runtime.shutdown()
        await restartedRuntime.shutdown()
    }

    func testReportRetryAfterRestartIgnoresVolatileMetadataOrderingAndPII()
        async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        let originalPacket = makeOperationPacket(metadataVariant: false)
        let rebuiltPacket = makeOperationPacket(metadataVariant: true)
        XCTAssertEqual(
            originalPacket.normalizedForOperationFingerprint(),
            rebuiltPacket.normalizedForOperationFingerprint()
        )

        let first = try await fixture.runtime.generateReport(
            reportID: reportID,
            packet: originalPacket
        )
        let restartedClient = FakeCodexAppServer()
        let restartedRuntime = try fixture.makeRestartedRuntime(
            client: restartedClient
        )

        let recovered = try await restartedRuntime.generateReport(
            reportID: reportID,
            packet: rebuiltPacket
        )

        XCTAssertEqual(recovered, first)
        let metrics = await restartedClient.metrics()
        XCTAssertEqual(metrics.startedThreads, 0)
        XCTAssertEqual(metrics.reportTurns, 0)
        await fixture.runtime.shutdown()
        await restartedRuntime.shutdown()
    }

    func testReportRetryRejectsSemanticContentChange() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        _ = try await fixture.runtime.generateReport(
            reportID: reportID,
            packet: makeOperationPacket(metadataVariant: false)
        )
        let restartedClient = FakeCodexAppServer()
        let restartedRuntime = try fixture.makeRestartedRuntime(
            client: restartedClient
        )

        do {
            _ = try await restartedRuntime.generateReport(
                reportID: reportID,
                packet: makeOperationPacket(
                    metadataVariant: true,
                    expenseAmount: 121
                )
            )
            XCTFail("同一 reportID 的真实财务内容变化应被拒绝。")
        } catch let error as FIREBridgeError {
            guard case .invalidMessage = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let metrics = await restartedClient.metrics()
        XCTAssertEqual(metrics.startedThreads, 0)
        XCTAssertEqual(metrics.reportTurns, 0)
        await fixture.runtime.shutdown()
        await restartedRuntime.shutdown()
    }

    func testFollowUpRetryReusesOperationAndTurn() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        let operationID = UUID()
        _ = try await fixture.runtime.generateReport(
            reportID: reportID,
            packet: makePacket()
        )

        async let first = fixture.runtime.followUp(
            operationID: operationID,
            reportID: reportID,
            question: "我的主要风险是什么？"
        )
        async let second = fixture.runtime.followUp(
            operationID: operationID,
            reportID: reportID,
            question: "我的主要风险是什么？"
        )
        let responses = try await (first, second)

        XCTAssertEqual(responses.0, responses.1)
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.answerTurns, 1)

        do {
            _ = try await fixture.runtime.followUp(
                operationID: operationID,
                reportID: reportID,
                question: "换一个问题"
            )
            XCTFail("复用 operationID 时更换问题应失败。")
        } catch let error as FIREBridgeError {
            guard case .invalidMessage = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        await fixture.runtime.shutdown()
    }

    func testEphemeralFollowUpSurvivesBridgeRestartAndReplaysHistory()
        async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        _ = try await fixture.runtime.generateReport(
            reportID: reportID,
            packet: makeOperationPacket(metadataVariant: false)
        )
        await fixture.runtime.shutdown()

        let restartedClient = FakeCodexAppServer()
        let restartedRuntime = try fixture.makeRestartedRuntime(
            client: restartedClient
        )
        _ = try await restartedRuntime.followUp(
            operationID: UUID(),
            reportID: reportID,
            question: "第一次追问"
        )
        _ = try await restartedRuntime.followUp(
            operationID: UUID(),
            reportID: reportID,
            question: "第二次追问"
        )

        let metrics = await restartedClient.metrics()
        XCTAssertEqual(metrics.startedThreads, 0)
        XCTAssertEqual(metrics.ephemeralThreads, 2)
        XCTAssertEqual(metrics.resumedThreads, 0)
        XCTAssertEqual(metrics.answerTurns, 2)
        XCTAssertEqual(metrics.unsubscribedThreads, 2)
        let contexts = await restartedClient.answerContexts()
        XCTAssertEqual(contexts.count, 2)
        XCTAssertTrue(contexts[1]?.contains("第一次追问") == true)
        let reloadedStore = CodexThreadStore(
            storeURL: fixture.rootDirectory.appendingPathComponent(
                "threads.json"
            )
        )
        let stored = try await reloadedStore.thread(for: reportID)
        XCTAssertEqual(stored?.isEphemeral, true)
        XCTAssertEqual(stored?.completedFollowUps?.count, 2)
        await restartedRuntime.shutdown()
    }

    func testEphemeralReportStoresOnlyRedactedRecoveryPacket() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        _ = try await fixture.runtime.generateReport(
            reportID: reportID,
            packet: makeOperationPacket(metadataVariant: false)
        )

        let storedValue = try await fixture.store.thread(for: reportID)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.isEphemeral, true)
        let data = try JSONEncoder().encode(stored.redactedPacket)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("13812345678"))
        XCTAssertFalse(json.contains("6222020212345678"))
        await fixture.runtime.shutdown()
    }

    func testLegacyPersistentReportStillDeletesRemoteThread() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        let workingDirectory = try fixture.factory.create()
        try await fixture.store.upsert(
            StoredCodexThread(
                reportID: reportID,
                threadID: "legacy-thread",
                isolatedWorkingDirectory: workingDirectory.path,
                generatedReport: makeReport()
            )
        )
        await fixture.client.setDeleteError(
            .appServerRejected(code: nil, message: "thread not found")
        )

        _ = try await fixture.runtime.deleteReport(reportID: reportID)

        let stored = try await fixture.store.thread(for: reportID)
        let metrics = await fixture.client.metrics()
        XCTAssertNil(stored)
        XCTAssertEqual(metrics.deletedThreads, 1)
        await fixture.runtime.shutdown()
    }

    func testDeleteTreatsMissingMappingAndEphemeralReportAsSuccess() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }

        _ = try await fixture.runtime.deleteReport(reportID: UUID())
        var metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.deletedThreads, 0)

        let reportID = UUID()
        _ = try await fixture.runtime.generateReport(
            reportID: reportID,
            packet: makePacket()
        )
        _ = try await fixture.runtime.deleteReport(reportID: reportID)
        _ = try await fixture.runtime.deleteReport(reportID: reportID)

        let storedThread = try await fixture.store.thread(for: reportID)
        XCTAssertNil(storedThread)
        metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.deletedThreads, 0)
        await fixture.runtime.shutdown()
    }

    func testConcurrentDeleteSharesOneLocalEphemeralDeletion() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        _ = try await fixture.runtime.generateReport(
            reportID: reportID,
            packet: makePacket()
        )
        await fixture.client.setDeleteDelay(.milliseconds(50))

        async let first = fixture.runtime.deleteReport(reportID: reportID)
        async let second = fixture.runtime.deleteReport(reportID: reportID)
        let responses = try await (first, second)

        XCTAssertEqual(responses.0, responses.1)
        let storedThread = try await fixture.store.thread(for: reportID)
        XCTAssertNil(storedThread)
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.deletedThreads, 0)
        await fixture.runtime.shutdown()
    }

    func testDeleteCancelsAndWaitsForPendingReportBeforeReturning() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        await fixture.client.setReportDelay(.seconds(5))
        let generation = Task {
            try await fixture.runtime.generateReport(
                reportID: reportID,
                packet: makePacket()
            )
        }
        var reportTurnStarted = false
        for _ in 0..<100 {
            if await fixture.client.metrics().reportTurns == 1 {
                reportTurnStarted = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard reportTurnStarted else {
            generation.cancel()
            return XCTFail("报告生成未在预期时间内开始。")
        }

        _ = try await fixture.runtime.deleteReport(reportID: reportID)
        let generationResult = await generation.result

        guard case .failure(let error) = generationResult,
              error is CancellationError else {
            return XCTFail("删除应取消仍在运行的报告任务。")
        }
        let storedThread = try await fixture.store.thread(for: reportID)
        XCTAssertNil(storedThread)
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.reportTurns, 1)
        XCTAssertEqual(metrics.deletedThreads, 0)
        await fixture.runtime.shutdown()
    }

    func testDeleteCancelsAndWaitsForPendingFollowUpBeforeReturning() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let reportID = UUID()
        _ = try await fixture.runtime.generateReport(
            reportID: reportID,
            packet: makePacket()
        )
        await fixture.client.setAnswersSuspended(true)
        let followUp = Task {
            try await fixture.runtime.followUp(
                operationID: UUID(),
                reportID: reportID,
                question: "删除时仍在追问"
            )
        }
        var answerTurnStarted = false
        for _ in 0..<100 {
            if await fixture.client.metrics().answerTurns == 1 {
                answerTurnStarted = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard answerTurnStarted else {
            followUp.cancel()
            await fixture.client.releaseAnswers()
            return XCTFail("追问未在预期时间内开始。")
        }

        let deletion = Task {
            try await fixture.runtime.deleteReport(reportID: reportID)
        }
        try await Task.sleep(for: .milliseconds(30))
        let metricsWhileDeleting = await fixture.client.metrics()
        XCTAssertEqual(
            metricsWhileDeleting.deletedThreads,
            0,
            "删除必须等待仍在运行的追问结束。"
        )

        await fixture.client.releaseAnswers()
        _ = try await deletion.value
        let followUpResult = await followUp.result

        guard case .failure(let error) = followUpResult,
              error is CancellationError else {
            return XCTFail("删除应取消仍在运行的追问任务。")
        }
        let storedThread = try await fixture.store.thread(for: reportID)
        XCTAssertNil(storedThread)
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.answerTurns, 1)
        XCTAssertEqual(metrics.deletedThreads, 0)
        await fixture.runtime.shutdown()
    }

    func testAssetRecognitionUsesEphemeralThreadAndCleansUpLocalDirectory() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let operationID = UUID()
        let request = makeRecognitionRequest(operationID: operationID)

        async let first = fixture.runtime.recognizeAssets(request: request)
        async let second = fixture.runtime.recognizeAssets(request: request)
        let responses = try await (first, second)

        XCTAssertEqual(responses.0, makeRecognitionResponse())
        XCTAssertEqual(responses.1, makeRecognitionResponse())
        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.ephemeralThreads, 1)
        XCTAssertEqual(metrics.recognitionTurns, 1)
        XCTAssertEqual(metrics.deletedThreads, 0)
        let storedThreads = try await fixture.store.allThreads()
        XCTAssertEqual(storedThreads.count, 0)
        let storedOperations = try await fixture.assetRecognitionStore
            .allOperations()
        XCTAssertEqual(storedOperations.count, 1)
        XCTAssertEqual(storedOperations.first?.operationID, operationID)
        XCTAssertEqual(try fixture.isolatedDirectoryCount(), 1)
        await fixture.runtime.shutdown()
    }

    func testAssetRecognitionRetryAfterRestartReturnsPersistedResult() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let request = makeRecognitionRequest(operationID: UUID())
        let first = try await fixture.runtime.recognizeAssets(request: request)

        let restartedClient = FakeCodexAppServer()
        let restartedRuntime = try fixture.makeRestartedRuntime(
            client: restartedClient
        )
        let recovered = try await restartedRuntime.recognizeAssets(
            request: request
        )

        XCTAssertEqual(recovered, first)
        let metrics = await restartedClient.metrics()
        XCTAssertEqual(metrics.ephemeralThreads, 0)
        XCTAssertEqual(metrics.recognitionTurns, 0)
        await fixture.runtime.shutdown()
        await restartedRuntime.shutdown()
    }

    func testAssetRecognitionRetryAfterRestartAcceptsRedactedCheckpoint()
        async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let operationID = UUID()
        let original = makeRecognitionRequest(
            operationID: operationID,
            productLine:
                "示例基金 000001，姓名：张三，手机 13812345678"
        )
        let first = try await fixture.runtime.recognizeAssets(
            request: original
        )
        let restartedClient = FakeCodexAppServer()
        let restartedRuntime = try fixture.makeRestartedRuntime(
            client: restartedClient
        )
        let checkpoint = RecognizeAssetsRequestV1(
            operationID: operationID,
            imageCount: original.imageCount,
            lines: original.lines.map { line in
                AssetOCRLineV1(
                    imageIndex: line.imageIndex,
                    text: PIIRedactor.redact(text: line.text),
                    confidence: line.confidence,
                    boundingBox: line.boundingBox
                )
            }
        )

        let recovered = try await restartedRuntime.recognizeAssets(
            request: checkpoint
        )

        XCTAssertEqual(recovered, first)
        let metrics = await restartedClient.metrics()
        XCTAssertEqual(metrics.ephemeralThreads, 0)
        XCTAssertEqual(metrics.recognitionTurns, 0)
        await fixture.runtime.shutdown()
        await restartedRuntime.shutdown()
    }

    func testAssetRecognitionRejectsDifferentRequestForSameOperationID() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let operationID = UUID()
        _ = try await fixture.runtime.recognizeAssets(
            request: makeRecognitionRequest(operationID: operationID)
        )

        do {
            _ = try await fixture.runtime.recognizeAssets(
                request: makeRecognitionRequest(
                    operationID: operationID,
                    productLine: "另一只基金 000002"
                )
            )
            XCTFail("复用资产识别 operationID 时更换内容应失败。")
        } catch let error as FIREBridgeError {
            guard case .invalidMessage = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.ephemeralThreads, 1)
        XCTAssertEqual(metrics.recognitionTurns, 1)
        await fixture.runtime.shutdown()
    }

    func testAssetRecognitionRejectsInvalidOutputAndStillCleansUpLocalDirectory() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        await fixture.client.setRecognitionResponse(
            RecognizeAssetsResponseV1(
                positions: [
                    RecognizedAssetPositionV1(
                        imageIndex: 0,
                        productName: "示例基金",
                        productCode: "000001",
                        kind: .fund,
                        currency: .CNY,
                        originalMarketValue: 0,
                        confidence: 0.8,
                        evidence: "示例基金 000001 市值 100"
                    ),
                ]
            )
        )

        do {
            _ = try await fixture.runtime.recognizeAssets(
                request: makeRecognitionRequest()
            )
            XCTFail("非正市值应被拒绝。")
        } catch let error as FIREBridgeError {
            guard case .invalidStructuredOutput = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.ephemeralThreads, 1)
        XCTAssertEqual(metrics.recognitionTurns, 1)
        XCTAssertEqual(metrics.deletedThreads, 0)
        XCTAssertEqual(try fixture.isolatedDirectoryCount(), 1)
        await fixture.runtime.shutdown()
    }

    func testAssetRecognitionEnvelopeRoundTripsWithoutProtocolBump() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let envelope = try BridgeEnvelopeV1(
            type: .recognizeAssets,
            payload: makeRecognitionRequest()
        )

        let result = await fixture.runtime.handle(envelope)

        XCTAssertEqual(BridgeWire.protocolVersion, "1")
        XCTAssertEqual(result.id, envelope.id)
        XCTAssertEqual(result.type, .assetsRecognized)
        XCTAssertEqual(
            try result.decodePayload(RecognizeAssetsResponseV1.self),
            makeRecognitionResponse()
        )
        await fixture.runtime.shutdown()
    }

    func testAssetRecognitionRejectsInvalidInputBeforeStartingThread() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let invalid = RecognizeAssetsRequestV1(
            imageCount: 1,
            lines: [
                AssetOCRLineV1(
                    imageIndex: 1,
                    text: "越界截图",
                    confidence: 0.8,
                    boundingBox: .init(x: 0, y: 0, width: 0.5, height: 0.1)
                ),
            ]
        )

        do {
            _ = try await fixture.runtime.recognizeAssets(request: invalid)
            XCTFail("越界截图序号应被拒绝。")
        } catch let error as FIREBridgeError {
            guard case .invalidMessage = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let metrics = await fixture.client.metrics()
        XCTAssertEqual(metrics.ephemeralThreads, 0)
        XCTAssertEqual(metrics.recognitionTurns, 0)
        await fixture.runtime.shutdown()
    }

    func testExchangeRateEnvelopeUsesInjectedECBFetcherWithoutCodexTurn() async throws {
        let expected = ExchangeRatesFetchedResponseV1(
            observationDate: Date(timeIntervalSince1970: 1_783_765_200),
            fetchedAt: Date(timeIntervalSince1970: 1_783_800_000),
            ratesToCNY: ["CNY": 1, "USD": 7.2]
        )
        let rateFetcher = FakeReferenceExchangeRateFetcher(response: expected)
        let fixture = try RuntimeFixture(exchangeRateFetcher: rateFetcher)
        defer { fixture.removeFiles() }
        let envelope = try BridgeEnvelopeV1(
            type: .fetchExchangeRates,
            payload: FetchExchangeRatesRequestV1(
                snapshotDate: Date(timeIntervalSince1970: 1_783_800_000),
                currencies: ["USD"]
            )
        )

        let result = await fixture.runtime.handle(envelope)

        XCTAssertEqual(result.id, envelope.id)
        XCTAssertEqual(result.type, .exchangeRatesFetched)
        XCTAssertEqual(
            try result.decodePayload(ExchangeRatesFetchedResponseV1.self),
            expected
        )
        let codexMetrics = await fixture.client.metrics()
        XCTAssertEqual(codexMetrics.startedThreads, 0)
        XCTAssertEqual(codexMetrics.reportTurns, 0)
        XCTAssertEqual(codexMetrics.recognitionTurns, 0)
        let rateRequestCount = await rateFetcher.requestCount()
        XCTAssertEqual(rateRequestCount, 1)
        await fixture.runtime.shutdown()
    }

    func testPingAdvertisesExchangeRateCapabilityWithoutProtocolBump() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.removeFiles() }
        let envelope = try BridgeEnvelopeV1(
            type: .ping,
            payload: PingPayloadV1()
        )

        let result = await fixture.runtime.handle(envelope)
        let pong = try result.decodePayload(PongPayloadV1.self)

        XCTAssertEqual(BridgeWire.protocolVersion, "1")
        XCTAssertEqual(result.type, .pong)
        XCTAssertEqual(
            pong.capabilities,
            [
                BridgeWire.exchangeRatesCapability,
                BridgeWire.durableAssetRecognitionCapability,
            ]
        )
        await fixture.runtime.shutdown()
    }

    func testNewClientDecodesLegacyPongWithoutCapabilities() throws {
        let data = try BridgeWire.makeEncoder().encode(
            LegacyPongPayload(
                sentAt: Date(timeIntervalSince1970: 0),
                codexReady: true
            )
        )

        let decoded = try BridgeWire.makeDecoder().decode(
            PongPayloadV1.self,
            from: data
        )

        XCTAssertTrue(decoded.codexReady)
        XCTAssertNil(decoded.capabilities)
    }
}

private struct RuntimeFixture {
    let rootDirectory: URL
    let factory: IsolatedWorkingDirectoryFactory
    let store: CodexThreadStore
    let assetRecognitionStore: AssetRecognitionOperationStore
    let client: FakeCodexAppServer
    let runtime: CodexBridgeRuntime

    init(
        exchangeRateFetcher: (any ReferenceExchangeRateFetching)? = nil
    ) throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: false
        )
        factory = IsolatedWorkingDirectoryFactory(
            baseURL: rootDirectory.appendingPathComponent(
                "isolated",
                isDirectory: true
            )
        )
        store = CodexThreadStore(
            storeURL: rootDirectory.appendingPathComponent("threads.json")
        )
        assetRecognitionStore = AssetRecognitionOperationStore(
            storeURL: rootDirectory.appendingPathComponent(
                "asset-recognition-operations.json"
            )
        )
        client = FakeCodexAppServer()
        runtime = CodexBridgeRuntime(
            health: CodexHealthStatus(
                executablePath: "/tmp/codex",
                authenticatedWithChatGPT: true
            ),
            client: client,
            threadStore: store,
            assetRecognitionStore: assetRecognitionStore,
            exchangeRateFetcher: exchangeRateFetcher,
            directoryFactory: factory,
            serverWorkingDirectory: try factory.create()
        )
    }

    func makeRestartedRuntime(
        client: FakeCodexAppServer
    ) throws -> CodexBridgeRuntime {
        CodexBridgeRuntime(
            health: CodexHealthStatus(
                executablePath: "/tmp/codex",
                authenticatedWithChatGPT: true
            ),
            client: client,
            threadStore: CodexThreadStore(
                storeURL: rootDirectory.appendingPathComponent("threads.json")
            ),
            assetRecognitionStore: AssetRecognitionOperationStore(
                storeURL: rootDirectory.appendingPathComponent(
                    "asset-recognition-operations.json"
                )
            ),
            directoryFactory: factory,
            serverWorkingDirectory: try factory.create()
        )
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func isolatedDirectoryCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: rootDirectory.appendingPathComponent("isolated", isDirectory: true),
            includingPropertiesForKeys: nil
        ).count
    }
}

private actor FakeReferenceExchangeRateFetcher:
    ReferenceExchangeRateFetching {
    private let response: ExchangeRatesFetchedResponseV1
    private var requests = 0

    init(response: ExchangeRatesFetchedResponseV1) {
        self.response = response
    }

    func fetchRates(
        for snapshotDate: Date,
        currencies: [String]
    ) async throws -> ExchangeRatesFetchedResponseV1 {
        requests += 1
        return response
    }

    func requestCount() -> Int {
        requests
    }
}

private struct LegacyPongPayload: Codable {
    let sentAt: Date
    let codexReady: Bool
}

private actor FakeCodexAppServer: CodexAppServerServing {
    struct Metrics {
        var startedThreads: Int
        var ephemeralThreads: Int
        var resumedThreads: Int
        var deletedThreads: Int
        var unsubscribedThreads: Int
        var reportTurns: Int
        var answerTurns: Int
        var recognitionTurns: Int
    }

    private var startedThreads = 0
    private var ephemeralThreads = 0
    private var resumedThreads = 0
    private var deletedThreads = 0
    private var unsubscribedThreads = 0
    private var reportTurns = 0
    private var answerTurns = 0
    private var recognitionTurns = 0
    private var deleteError: FIREBridgeError?
    private var deleteDelay: Duration = .zero
    private var reportDelay: Duration = .milliseconds(30)
    private var recognitionResponse = makeRecognitionResponse()
    private var answersSuspended = false
    private var answerWaiters: [CheckedContinuation<Void, Never>] = []
    private var capturedAnswerContexts: [String?] = []

    func connect() async throws {}

    func disconnect() async {}

    func startThread(workingDirectory: URL) async throws -> String {
        startedThreads += 1
        return "thread-\(startedThreads)"
    }

    func startEphemeralThread(
        workingDirectory: URL,
        purpose: CodexEphemeralThreadPurpose
    ) async throws -> String {
        ephemeralThreads += 1
        return "ephemeral-thread-\(ephemeralThreads)"
    }

    func resumeThread(threadID: String, workingDirectory: URL) async throws {
        resumedThreads += 1
    }

    func deleteThread(threadID: String) async throws {
        deletedThreads += 1
        try await Task.sleep(for: deleteDelay)
        if let deleteError {
            throw deleteError
        }
    }

    func unsubscribeThread(threadID: String) async throws {
        unsubscribedThreads += 1
    }

    func generateReport(
        threadID: String,
        packetJSON: String
    ) async throws -> AnalysisReportV1 {
        reportTurns += 1
        try await Task.sleep(for: reportDelay)
        return makeReport()
    }

    func answer(
        threadID: String,
        question: String,
        contextJSON: String?
    ) async throws -> AnalysisAnswerV1 {
        answerTurns += 1
        capturedAnswerContexts.append(contextJSON)
        if answersSuspended {
            await withCheckedContinuation { continuation in
                answerWaiters.append(continuation)
            }
        } else {
            try await Task.sleep(for: .milliseconds(30))
        }
        return AnalysisAnswerV1(
            answer: "主要风险来自数据历史较短。",
            evidenceRefs: ["e1"],
            limitations: []
        )
    }

    func recognizeAssets(
        threadID: String,
        requestJSON: String
    ) async throws -> RecognizeAssetsResponseV1 {
        recognitionTurns += 1
        return recognitionResponse
    }

    func setDeleteError(_ error: FIREBridgeError?) {
        deleteError = error
    }

    func setDeleteDelay(_ delay: Duration) {
        deleteDelay = delay
    }

    func setReportDelay(_ delay: Duration) {
        reportDelay = delay
    }

    func setAnswersSuspended(_ suspended: Bool) {
        answersSuspended = suspended
    }

    func releaseAnswers() {
        answersSuspended = false
        let waiters = answerWaiters
        answerWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func setRecognitionResponse(_ response: RecognizeAssetsResponseV1) {
        recognitionResponse = response
    }

    func answerContexts() -> [String?] {
        capturedAnswerContexts
    }

    func metrics() -> Metrics {
        Metrics(
            startedThreads: startedThreads,
            ephemeralThreads: ephemeralThreads,
            resumedThreads: resumedThreads,
            deletedThreads: deletedThreads,
            unsubscribedThreads: unsubscribedThreads,
            reportTurns: reportTurns,
            answerTurns: answerTurns,
            recognitionTurns: recognitionTurns
        )
    }
}

private func makeRecognitionRequest(
    operationID: UUID = UUID(),
    productLine: String = "示例基金 000001"
) -> RecognizeAssetsRequestV1 {
    RecognizeAssetsRequestV1(
        operationID: operationID,
        imageCount: 1,
        lines: [
            AssetOCRLineV1(
                imageIndex: 0,
                text: productLine,
                confidence: 0.95,
                boundingBox: .init(x: 0.1, y: 0.7, width: 0.5, height: 0.08)
            ),
            AssetOCRLineV1(
                imageIndex: 0,
                text: "市值 12,345.67",
                confidence: 0.98,
                boundingBox: .init(x: 0.6, y: 0.7, width: 0.3, height: 0.08)
            ),
        ]
    )
}

private func makeRecognitionResponse() -> RecognizeAssetsResponseV1 {
    RecognizeAssetsResponseV1(
        positions: [
            RecognizedAssetPositionV1(
                imageIndex: 0,
                productName: "示例基金",
                productCode: "000001",
                kind: .fund,
                currency: .CNY,
                originalMarketValue: 12_345.67,
                confidence: 0.92,
                evidence: "示例基金 000001 · 市值 12,345.67"
            ),
        ]
    )
}

private func makePacket() -> AnalysisPacketV1 {
    let expense = ExpenseAnalysis(
        annualSpending: 0,
        recurringAnnualized: 0,
        irregularObservedOrRolling12: 0,
        refundOffset: 0,
        completeMonthCount: 3,
        confidence: .low,
        excludedTransactionCount: 0,
        duplicateTransactionCount: 0,
        periodStart: nil,
        periodEnd: nil
    )
    let state = FIREState(
        calculatedAt: Date(timeIntervalSince1970: 0),
        investableNetWorth: 0,
        annualSpending: 0,
        targetAmount: 0,
        progress: 0,
        remainingAmount: 0,
        confirmedMonthlyContribution: nil,
        suggestedMonthlyContribution: MonthlyContributionSuggestion(
            amount: nil,
            monthsUsed: 0,
            confidence: .low,
            rationale: ""
        ),
        estimatedFreedomDate: nil,
        estimatedMonthsRemaining: nil,
        confidence: .low,
        assumptions: .balanced,
        expenseAnalysis: expense
    )
    return AnalysisPacketV1(
        periodStart: nil,
        periodEnd: nil,
        transactions: [],
        assetSnapshot: AssetSnapshot(
            capturedAt: Date(timeIntervalSince1970: 0),
            positions: [],
            status: .confirmedComplete
        ),
        fireState: state
    )
}

private func makeOperationPacket(
    metadataVariant: Bool,
    expenseAmount: Decimal = 120
) -> AnalysisPacketV1 {
    let periodStart = Date(timeIntervalSince1970: 1_767_225_600)
    let periodEnd = Date(timeIntervalSince1970: 1_769_904_000)
    let snapshotDate = periodEnd
    var expense = TransactionRecord(
        id: operationUUID(1),
        occurredAt: periodStart.addingTimeInterval(3_600),
        direction: .expense,
        amount: expenseAmount,
        primaryCategory: "日常",
        secondaryCategory: "餐饮",
        merchantNote: metadataVariant
            ? "微信转账-李雷；手机号 13912345678"
            : "微信转账-张三；手机号 13812345678",
        tags: metadataVariant ? ["必要", "餐饮"] : ["餐饮", "必要"],
        accountName: metadataVariant ? "尾号 5678" : "尾号 1234",
        ledgerName: "日常账本",
        fingerprint: "expense-source",
        importRow: 10
    )
    expense.fingerprint = "expense-source"
    var income = TransactionRecord(
        id: operationUUID(2),
        occurredAt: periodStart.addingTimeInterval(7_200),
        direction: .income,
        amount: 10_000,
        primaryCategory: "收入",
        secondaryCategory: "工资",
        merchantNote: "工资",
        tags: metadataVariant ? ["固定", "工作"] : ["工作", "固定"],
        accountName: metadataVariant ? "工资卡 2222" : "工资卡 1111",
        ledgerName: "日常账本",
        fingerprint: "income-source",
        importRow: 11
    )
    income.fingerprint = "income-source"

    let fund = Instrument(
        id: operationUUID(metadataVariant ? 31 : 11),
        code: "000001",
        name: metadataVariant
            ? "示例基金，持有人：李雷"
            : "示例基金，持有人：张三",
        kind: .fund,
        currency: .cny
    )
    let stock = Instrument(
        id: operationUUID(metadataVariant ? 32 : 12),
        code: "09875",
        name: "示例控股",
        kind: .stock,
        currency: .hkd
    )
    let fundPosition = PositionSnapshot(
        id: operationUUID(metadataVariant ? 41 : 21),
        instrument: fund,
        originalMarketValue: 20_000,
        marketValueInCNY: 20_000,
        quantity: 10_000,
        unitPrice: 2,
        capturedAt: metadataVariant
            ? snapshotDate.addingTimeInterval(600)
            : snapshotDate,
        recognitionConfidence: 0.9,
        sourceImportID: metadataVariant ? "platform-b" : "platform-a"
    )
    let stockPosition = PositionSnapshot(
        id: operationUUID(metadataVariant ? 42 : 22),
        instrument: stock,
        originalMarketValue: 30_000,
        marketValueInCNY: 27_000,
        quantity: 1_000,
        unitPrice: 30,
        capturedAt: metadataVariant
            ? snapshotDate.addingTimeInterval(1_200)
            : snapshotDate,
        recognitionConfidence: 0.95,
        sourceImportID: metadataVariant ? "account-b" : "account-a"
    )
    let mortgage = Liability(
        id: operationUUID(metadataVariant ? 51 : 23),
        name: metadataVariant ? "李雷的住房贷款" : "张三的住房贷款",
        currency: .cny,
        remainingPrincipal: 100_000,
        remainingPrincipalInCNY: 100_000,
        updatedAt: metadataVariant
            ? snapshotDate.addingTimeInterval(2_400)
            : snapshotDate
    )
    let card = Liability(
        id: operationUUID(metadataVariant ? 52 : 24),
        name: metadataVariant ? "李雷的信用卡" : "张三的信用卡",
        currency: .cny,
        remainingPrincipal: 5_000,
        remainingPrincipalInCNY: 5_000,
        updatedAt: metadataVariant
            ? snapshotDate.addingTimeInterval(3_600)
            : snapshotDate
    )
    let positions = metadataVariant
        ? [stockPosition, fundPosition]
        : [fundPosition, stockPosition]
    let liabilities = metadataVariant
        ? [card, mortgage]
        : [mortgage, card]
    let dataIssues = metadataVariant
        ? ["卡号 6222020211112222", "手机号 13912345678"]
        : ["手机号 13812345678", "卡号 6222020212345678"]
    let snapshot = AssetSnapshot(
        id: operationUUID(metadataVariant ? 61 : 25),
        capturedAt: snapshotDate,
        positions: positions,
        cashBalances: ["CNY": 8_000, "USD": 100],
        cashValueInCNY: 8_700,
        liabilities: liabilities,
        exchangeRates: ExchangeRateSnapshot(
            asOf: snapshotDate.addingTimeInterval(-86_400),
            fetchedAt: metadataVariant
                ? snapshotDate.addingTimeInterval(4_800)
                : snapshotDate,
            cnyPerUnit: ["CNY": 1, "USD": 7, "HKD": 0.9],
            source: "ECB"
        ),
        status: .confirmedComplete,
        dataIssues: dataIssues
    )
    let expenseAnalysis = ExpenseAnalysis(
        annualSpending: 24_000,
        recurringAnnualized: 20_000,
        irregularObservedOrRolling12: 4_000,
        refundOffset: 0,
        completeMonthCount: 6,
        confidence: .low,
        excludedTransactionCount: 0,
        duplicateTransactionCount: 0,
        periodStart: periodStart,
        periodEnd: periodEnd
    )
    let state = FIREState(
        calculatedAt: metadataVariant
            ? snapshotDate.addingTimeInterval(7_200)
            : snapshotDate,
        investableNetWorth: -49_300,
        annualSpending: 24_000,
        targetAmount: 685_714,
        progress: 0,
        remainingAmount: 735_014,
        confirmedMonthlyContribution: 5_000,
        confirmedAnnualBonusContribution: 20_000,
        suggestedMonthlyContribution: MonthlyContributionSuggestion(
            amount: 5_000,
            monthsUsed: 6,
            confidence: .low,
            rationale: "近期结余中位数"
        ),
        estimatedFreedomDate: metadataVariant
            ? snapshotDate.addingTimeInterval(20 * 365 * 86_400)
            : snapshotDate.addingTimeInterval(19 * 365 * 86_400),
        estimatedMonthsRemaining: 228,
        confidence: .low,
        assumptions: .balanced,
        expenseAnalysis: expenseAnalysis
    )
    let transactions = metadataVariant ? [income, expense] : [expense, income]
    return AnalysisPacketV1(
        generatedAt: metadataVariant
            ? snapshotDate.addingTimeInterval(10_000)
            : snapshotDate,
        periodStart: periodStart,
        periodEnd: periodEnd,
        transactions: transactions,
        assetSnapshot: snapshot,
        fireState: state,
        monthlySummary: MonthlyFinancialSummaryV1(
            periodStart: periodStart,
            periodEnd: periodEnd,
            isCompleteMonth: true,
            transactionCount: 2,
            income: 10_000,
            livingExpense: expenseAmount,
            netCashFlow: 10_000 - expenseAmount,
            assetSnapshotDate: snapshotDate,
            fundValue: 20_000,
            stockValue: 27_000,
            cashValue: 8_700,
            totalAssets: 55_700,
            liabilities: 105_000,
            investableNetWorth: -49_300
        )
    )
}

private func operationUUID(_ suffix: Int) -> UUID {
    UUID(
        uuidString: String(
            format: "00000000-0000-0000-0000-%012d",
            suffix
        )
    )!
}

private func makeReport() -> AnalysisReportV1 {
    AnalysisReportV1(
        coreConclusion: "当前仍需继续积累。",
        dataConfidence: AnalysisConfidenceV1(
            level: .low,
            explanation: "历史不足六个月。",
            evidenceRefs: ["e1"]
        ),
        spendingFindings: [],
        assetStructureRisks: [],
        fireDrivers: [],
        actions: [
            AnalysisActionV1(
                title: "补齐数据",
                rationale: "提高可信度",
                evidenceRefs: ["e1"]
            ),
            AnalysisActionV1(
                title: "确认结余",
                rationale: "稳定预测",
                evidenceRefs: ["e1"]
            ),
            AnalysisActionV1(
                title: "定期复盘",
                rationale: "跟踪进度",
                evidenceRefs: ["e1"]
            ),
        ],
        evidence: [
            AnalysisEvidenceV1(
                id: "e1",
                label: "数据可信度",
                value: DataConfidence.low.rawValue
            ),
        ],
        limitations: []
    )
}
#endif
