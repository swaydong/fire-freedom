import FIRECore
import Foundation
import XCTest
@testable import FIREBridgeKit

final class CodexAppServerClientTests: XCTestCase {
    func testClientCompletesStructuredReportThroughFakeTransport() async throws {
        let report = AnalysisReportV1(
            coreConclusion: "仍需积累资产。",
            dataConfidence: AnalysisConfidenceV1(
                level: .low,
                explanation: "只有四个完整月。",
                evidenceRefs: ["e1"]
            ),
            spendingFindings: [],
            assetStructureRisks: [],
            fireDrivers: [],
            actions: [
                AnalysisActionV1(title: "行动一", rationale: "理由一", evidenceRefs: ["e1"]),
                AnalysisActionV1(title: "行动二", rationale: "理由二", evidenceRefs: ["e1"]),
                AnalysisActionV1(title: "行动三", rationale: "理由三", evidenceRefs: ["e1"]),
            ],
            evidence: [
                AnalysisEvidenceV1(id: "e1", label: "完整月份", value: "4"),
            ],
            limitations: ["历史不足十二个月。"]
        )
        let reportData = try JSONEncoder().encode(report)
        let connection = FakeAppServerConnection(
            finalMessage: String(decoding: reportData, as: UTF8.self)
        )
        let client = CodexAppServerClient(connection: connection)

        try await client.connect()
        let threadID = try await client.startThread(
            workingDirectory: URL(fileURLWithPath: "/private/tmp/fire-test")
        )
        let decoded = try await client.generateReport(
            threadID: threadID,
            packetJSON: #"{"schemaVersion":"1.0"}"#
        )

        XCTAssertEqual(threadID, "thread-test")
        XCTAssertEqual(decoded, report)
        let messages = await connection.sentMessages()
        XCTAssertEqual(
            messages.compactMap { $0["method"]?.stringValue },
            ["initialize", "initialized", "thread/start", "turn/start"]
        )
        XCTAssertEqual(
            messages.last?["params"]?["outputSchema"]?["properties"]?["schemaVersion"]?["const"],
            .string("1.0")
        )
        XCTAssertEqual(
            messages.last?["params"]?["effort"],
            .string("low")
        )
        await client.disconnect()
    }

    func testInterruptedTurnFailsExplicitly() async throws {
        let connection = FakeAppServerConnection(
            finalMessage: "",
            interruptsTurn: true
        )
        let client = CodexAppServerClient(connection: connection)

        try await client.connect()
        let threadID = try await client.startThread(
            workingDirectory: URL(fileURLWithPath: "/private/tmp/fire-test")
        )

        do {
            _ = try await client.generateReport(
                threadID: threadID,
                packetJSON: #"{"schemaVersion":"1.0"}"#
            )
            XCTFail("interrupted turn should fail")
        } catch let error as FIREBridgeError {
            guard case let .appServerDisconnected(message) = error else {
                return XCTFail("unexpected bridge error: \(error)")
            }
            XCTAssertTrue(message.contains("中断"))
        }
        await client.disconnect()
    }

    func testCancellingRequestDoesNotWaitForMissingServerResponse() async throws {
        let connection = FakeAppServerConnection(
            finalMessage: "",
            neverRespondsToThreadStart: true
        )
        let client = CodexAppServerClient(connection: connection)
        try await client.connect()

        let request = Task {
            try await client.startThread(
                workingDirectory: URL(fileURLWithPath: "/private/tmp/fire-test")
            )
        }
        try await waitForSentMethod("thread/start", connection: connection)
        let completion = expectation(description: "request cancellation")
        let observer = Task {
            let result = await request.result
            completion.fulfill()
            return result
        }

        request.cancel()
        await fulfillment(of: [completion], timeout: 1)
        await client.disconnect()
        let result = await observer.value
        guard case .failure(let error) = result else {
            return XCTFail("取消后请求不应成功。")
        }
        XCTAssertTrue(error is CancellationError)
    }

    func testCancellingTurnInterruptsServerAndDoesNotWaitForCompletion() async throws {
        let connection = FakeAppServerConnection(
            finalMessage: "",
            neverCompletesTurn: true
        )
        let client = CodexAppServerClient(connection: connection)
        try await client.connect()
        let threadID = try await client.startThread(
            workingDirectory: URL(fileURLWithPath: "/private/tmp/fire-test")
        )
        let turn = Task {
            try await client.generateReport(
                threadID: threadID,
                packetJSON: #"{"schemaVersion":"1.0"}"#
            )
        }
        try await waitForSentMethod("turn/start", connection: connection)
        let completion = expectation(description: "turn cancellation")
        let observer = Task {
            let result = await turn.result
            completion.fulfill()
            return result
        }

        turn.cancel()
        await fulfillment(of: [completion], timeout: 1)
        try await waitForSentMethod("turn/interrupt", connection: connection)
        await client.disconnect()
        let result = await observer.value
        guard case .failure(let error) = result else {
            return XCTFail("取消后回合不应成功。")
        }
        XCTAssertTrue(error is CancellationError)
        let interrupt = await connection.sentMessages().first {
            $0["method"]?.stringValue == "turn/interrupt"
        }
        XCTAssertEqual(
            interrupt?["params"]?["threadId"],
            .string("thread-test")
        )
        XCTAssertEqual(
            interrupt?["params"]?["turnId"],
            .string("turn-test")
        )
    }

    func testUnsupportedServerRequestDoesNotBreakActiveTurn() async throws {
        let expected = makeClientTestReport()
        let data = try JSONEncoder().encode(expected)
        let connection = FakeAppServerConnection(
            finalMessage: String(decoding: data, as: UTF8.self),
            emitsUnsupportedServerRequest: true
        )
        let client = CodexAppServerClient(connection: connection)

        try await client.connect()
        let threadID = try await client.startThread(
            workingDirectory: URL(fileURLWithPath: "/private/tmp/fire-report-test")
        )
        let report = try await client.generateReport(
            threadID: threadID,
            packetJSON: "{}"
        )

        XCTAssertEqual(report, expected)
        await client.disconnect()
    }

    func testClientRunsAssetRecognitionWithEphemeralThreadAndStrictSchema() async throws {
        let expected = RecognizeAssetsResponseV1(
            positions: [
                RecognizedAssetPositionV1(
                    imageIndex: 0,
                    productName: "示例股票",
                    productCode: "AAPL",
                    kind: .stock,
                    currency: .USD,
                    originalMarketValue: 1_234.5,
                    confidence: 0.9,
                    evidence: "AAPL · Market Value $1,234.50"
                ),
            ]
        )
        let data = try JSONEncoder().encode(expected)
        let connection = FakeAppServerConnection(
            finalMessage: String(decoding: data, as: UTF8.self)
        )
        let client = CodexAppServerClient(connection: connection)

        try await client.connect()
        let threadID = try await client.startEphemeralThread(
            workingDirectory: URL(fileURLWithPath: "/private/tmp/fire-ocr-test"),
            purpose: .assetRecognition
        )
        let response = try await client.recognizeAssets(
            threadID: threadID,
            requestJSON: #"{"imageCount":1,"lines":[]}"#
        )
        try await client.unsubscribeThread(threadID: threadID)

        XCTAssertEqual(response, expected)
        let messages = await connection.sentMessages()
        let threadStart = messages.first {
            $0["method"]?.stringValue == "thread/start"
        }
        XCTAssertEqual(threadStart?["params"]?["ephemeral"], .bool(true))
        XCTAssertEqual(
            threadStart?["params"]?["sandbox"],
            .string("read-only")
        )
        XCTAssertEqual(
            threadStart?["params"]?["developerInstructions"],
            .string(CodexRequestBuilder.assetRecognitionDeveloperInstructions)
        )
        XCTAssertTrue(messages.contains {
            $0["method"]?.stringValue == "thread/unsubscribe"
                && $0["params"]?["threadId"] == .string(threadID)
        })
        let turnStart = messages.first {
            $0["method"]?.stringValue == "turn/start"
        }
        XCTAssertEqual(turnStart?["params"]?["effort"], .string("low"))
        let prompt = turnStart?["params"]?["input"]?.arrayValue?
            .first?["text"]?.stringValue
        XCTAssertTrue(prompt?.contains("不能因为产品代码缺失而省略") == true)
        let outputSchema = turnStart?["params"]?["outputSchema"]
        let positionsSchema = outputSchema?["properties"]?["positions"]
        let itemSchema = positionsSchema?["items"]
        let kindValues = itemSchema?["properties"]?["kind"]?["enum"]
        XCTAssertEqual(
            kindValues,
            .array(["fund", "stock", "cash"].map(JSONValue.string))
        )
        await client.disconnect()
    }
}

private func waitForSentMethod(
    _ method: String,
    connection: FakeAppServerConnection
) async throws {
    for _ in 0..<100 {
        if await connection.sentMessages().contains(where: {
            $0["method"]?.stringValue == method
        }) {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("未发送预期 App Server 请求：\(method)")
}

private func makeClientTestReport() -> AnalysisReportV1 {
    AnalysisReportV1(
        coreConclusion: "仍需积累资产。",
        dataConfidence: AnalysisConfidenceV1(
            level: .low,
            explanation: "只有四个完整月。",
            evidenceRefs: ["e1"]
        ),
        spendingFindings: [],
        assetStructureRisks: [],
        fireDrivers: [],
        actions: [
            AnalysisActionV1(
                title: "行动一",
                rationale: "理由一",
                evidenceRefs: ["e1"]
            ),
            AnalysisActionV1(
                title: "行动二",
                rationale: "理由二",
                evidenceRefs: ["e1"]
            ),
            AnalysisActionV1(
                title: "行动三",
                rationale: "理由三",
                evidenceRefs: ["e1"]
            ),
        ],
        evidence: [
            AnalysisEvidenceV1(id: "e1", label: "完整月份", value: "4"),
        ],
        limitations: ["历史不足十二个月。"]
    )
}

private actor FakeAppServerConnection: AppServerConnection {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let finalMessage: String
    private let interruptsTurn: Bool
    private let emitsUnsupportedServerRequest: Bool
    private let neverRespondsToThreadStart: Bool
    private let neverCompletesTurn: Bool
    private var sent: [JSONValue] = []

    init(
        finalMessage: String,
        interruptsTurn: Bool = false,
        emitsUnsupportedServerRequest: Bool = false,
        neverRespondsToThreadStart: Bool = false,
        neverCompletesTurn: Bool = false
    ) {
        self.finalMessage = finalMessage
        self.interruptsTurn = interruptsTurn
        self.emitsUnsupportedServerRequest = emitsUnsupportedServerRequest
        self.neverRespondsToThreadStart = neverRespondsToThreadStart
        self.neverCompletesTurn = neverCompletesTurn
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.stream = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func start() {}

    func send(_ line: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        sent.append(value)
        guard let method = value["method"]?.stringValue,
              let idValue = value["id"],
              case let .number(idNumber) = idValue else {
            return
        }
        let id = Int(idNumber)

        switch method {
        case "initialize":
            yield(.object([
                "id": .number(Double(id)),
                "result": .object([:]),
            ]))
        case "thread/start":
            guard !neverRespondsToThreadStart else { return }
            yield(.object([
                "id": .number(Double(id)),
                "result": .object([
                    "thread": .object(["id": .string("thread-test")]),
                ]),
            ]))
        case "thread/unsubscribe":
            yield(.object([
                "id": .number(Double(id)),
                "result": .object([
                    "status": .string("unsubscribed"),
                ]),
            ]))
        case "turn/start":
            if emitsUnsupportedServerRequest {
                yield(.object([
                    "id": .string("server-request-test"),
                    "method": .string("unsupported/test"),
                    "params": .object([:]),
                ]))
            }
            yield(.object([
                "id": .number(Double(id)),
                "result": .object([
                    "turn": .object(["id": .string("turn-test")]),
                ]),
            ]))
            guard !neverCompletesTurn else { return }
            if interruptsTurn {
                yield(.object([
                    "method": .string("turn/completed"),
                    "params": .object([
                        "threadId": .string("thread-test"),
                        "turn": .object([
                            "id": .string("turn-test"),
                            "status": .string("interrupted"),
                        ]),
                    ]),
                ]))
                return
            }
            yield(.object([
                "method": .string("item/completed"),
                "params": .object([
                    "threadId": .string("thread-test"),
                    "turnId": .string("turn-test"),
                    "item": .object([
                        "id": .string("item-test"),
                        "type": .string("agentMessage"),
                        "text": .string(finalMessage),
                    ]),
                ]),
            ]))
            yield(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-test"),
                    "turn": .object([
                        "id": .string("turn-test"),
                        "status": .string("completed"),
                    ]),
                ]),
            ]))
        case "turn/interrupt":
            yield(.object([
                "id": .number(Double(id)),
                "result": .object([:]),
            ]))
        default:
            break
        }
    }

    func messages() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func stop() {
        continuation.finish()
    }

    func sentMessages() -> [JSONValue] {
        sent
    }

    private func yield(_ value: JSONValue) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        continuation.yield(data)
    }
}
