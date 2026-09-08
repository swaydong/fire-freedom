#if os(macOS)
import FIRECore
import Foundation

public protocol CodexAppServerServing: Sendable {
    func connect() async throws
    func disconnect() async
    func startThread(workingDirectory: URL) async throws -> String
    func startEphemeralThread(
        workingDirectory: URL,
        purpose: CodexEphemeralThreadPurpose
    ) async throws -> String
    func resumeThread(threadID: String, workingDirectory: URL) async throws
    func deleteThread(threadID: String) async throws
    func unsubscribeThread(threadID: String) async throws
    func generateReport(
        threadID: String,
        packetJSON: String
    ) async throws -> AnalysisReportV1
    func answer(
        threadID: String,
        question: String,
        contextJSON: String?
    ) async throws -> AnalysisAnswerV1
    func recognizeAssets(
        threadID: String,
        requestJSON: String
    ) async throws -> RecognizeAssetsResponseV1
}

public actor CodexAppServerClient {
    private struct CompletedTurn: Sendable {
        let output: String?
        let error: FIREBridgeError?
    }

    private struct ServerErrorResponse: Encodable, Sendable {
        struct ErrorBody: Encodable, Sendable {
            let code: Int
            let message: String
        }

        let id: JSONValue
        let error: ErrorBody
    }

    private let connection: any AppServerConnection
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var nextRequestID = 1
    private var pendingRequests: [
        Int: CheckedContinuation<JSONValue, Error>
    ] = [:]
    private var pendingTurns: [
        String: CheckedContinuation<String, Error>
    ] = [:]
    private var completedTurns: [String: CompletedTurn] = [:]
    private var agentMessagesByTurn: [String: [String]] = [:]
    private var cancelledTurnIDs: Set<String> = []
    private var readerTask: Task<Void, Never>?
    private var isConnected = false

    public init(connection: any AppServerConnection) {
        self.connection = connection
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func connect() async throws {
        guard !isConnected else { return }
        try await connection.start()
        let stream = await connection.messages()
        readerTask = Task { [weak self] in
            do {
                for try await line in stream {
                    await self?.receive(line)
                }
                await self?.connectionEnded(
                    FIREBridgeError.appServerDisconnected("标准输出已关闭。")
                )
            } catch {
                await self?.connectionEnded(error)
            }
        }

        let requestID = takeRequestID()
        _ = try await request(CodexRequestBuilder.initialize(id: requestID))
        try await send(CodexRequestBuilder.initialized())
        isConnected = true
    }

    public func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        await connection.stop()
        connectionEnded(FIREBridgeError.appServerDisconnected("连接已关闭。"))
        isConnected = false
    }

    public func startThread(workingDirectory: URL) async throws -> String {
        try requireConnection()
        let result = try await request(
            CodexRequestBuilder.startThread(
                id: takeRequestID(),
                cwd: workingDirectory
            )
        )
        return try parseThreadID(result)
    }

    public func startEphemeralThread(
        workingDirectory: URL,
        purpose: CodexEphemeralThreadPurpose
    ) async throws -> String {
        try requireConnection()
        let result = try await request(
            CodexRequestBuilder.startEphemeralThread(
                id: takeRequestID(),
                cwd: workingDirectory,
                purpose: purpose
            )
        )
        return try parseThreadID(result)
    }

    public func resumeThread(
        threadID: String,
        workingDirectory: URL
    ) async throws {
        try requireConnection()
        _ = try await request(
            CodexRequestBuilder.resumeThread(
                id: takeRequestID(),
                threadID: threadID,
                cwd: workingDirectory
            )
        )
    }

    public func deleteThread(threadID: String) async throws {
        try requireConnection()
        _ = try await request(
            CodexRequestBuilder.deleteThread(
                id: takeRequestID(),
                threadID: threadID
            )
        )
    }

    public func unsubscribeThread(threadID: String) async throws {
        try requireConnection()
        _ = try await request(
            CodexRequestBuilder.unsubscribeThread(
                id: takeRequestID(),
                threadID: threadID
            )
        )
    }

    public func generateReport(
        threadID: String,
        packetJSON: String
    ) async throws -> AnalysisReportV1 {
        let text = try await runTurn(
            CodexRequestBuilder.reportTurn(
                id: takeRequestID(),
                threadID: threadID,
                packetJSON: packetJSON
            )
        )
        do {
            return try decoder.decode(
                AnalysisReportV1.self,
                from: Data(text.utf8)
            )
        } catch let error as FIREBridgeError {
            throw error
        } catch {
            throw FIREBridgeError.invalidStructuredOutput(
                Self.describeDecoding(error)
            )
        }
    }

    public func answer(
        threadID: String,
        question: String,
        contextJSON: String? = nil
    ) async throws -> AnalysisAnswerV1 {
        let text = try await runTurn(
            CodexRequestBuilder.answerTurn(
                id: takeRequestID(),
                threadID: threadID,
                question: question,
                contextJSON: contextJSON
            )
        )
        do {
            let answer = try decoder.decode(AnalysisAnswerV1.self, from: Data(text.utf8))
            try answer.validateBridgeContract()
            return answer
        } catch let error as FIREBridgeError {
            throw error
        } catch {
            throw FIREBridgeError.invalidStructuredOutput(
                Self.describeDecoding(error)
            )
        }
    }

    public func recognizeAssets(
        threadID: String,
        requestJSON: String
    ) async throws -> RecognizeAssetsResponseV1 {
        let text = try await runTurn(
            CodexRequestBuilder.recognizeAssetsTurn(
                id: takeRequestID(),
                threadID: threadID,
                requestJSON: requestJSON
            )
        )
        do {
            return try decoder.decode(
                RecognizeAssetsResponseV1.self,
                from: Data(text.utf8)
            )
        } catch {
            throw FIREBridgeError.invalidStructuredOutput(
                Self.describeDecoding(error)
            )
        }
    }

    private func runTurn(_ request: JSONRPCRequest) async throws -> String {
        try requireConnection()
        let result = try await self.request(request)
        guard let turnID = result["turn"]?["id"]?.stringValue else {
            throw FIREBridgeError.appServerProtocolError("turn/start 缺少 turn.id。")
        }
        guard let threadID = request.params["threadId"]?.stringValue else {
            throw FIREBridgeError.appServerProtocolError(
                "turn/start 缺少 threadId。"
            )
        }
        return try await waitForTurn(turnID, threadID: threadID)
    }

    private func request(_ message: JSONRPCRequest) async throws -> JSONValue {
        let data = try encoder.encode(message)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[message.id] = continuation
                Task {
                    do {
                        try await connection.send(data)
                    } catch {
                        self.failRequest(id: message.id, error: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelRequest(id: message.id)
            }
        }
    }

    private func send(_ notification: JSONRPCNotification) async throws {
        try await connection.send(encoder.encode(notification))
    }

    private func waitForTurn(
        _ turnID: String,
        threadID: String
    ) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let completed = completedTurns.removeValue(forKey: turnID) {
                if let error = completed.error {
                    throw error
                }
                guard let output = completed.output else {
                    throw FIREBridgeError.invalidStructuredOutput(
                        "回合没有最终消息。"
                    )
                }
                return output
            }

            let output: String = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingTurns[turnID] = continuation
            }
            try Task.checkCancellation()
            return output
        } onCancel: {
            Task {
                await self.cancelTurnWait(
                    turnID: turnID,
                    threadID: threadID
                )
            }
        }
    }

    private func receive(_ line: Data) {
        let inbound: JSONRPCInbound
        do {
            inbound = try decoder.decode(JSONRPCInbound.self, from: line)
        } catch {
            return
        }

        if let method = inbound.method, let id = inbound.id {
            Task { [weak self] in
                await self?.rejectUnsupportedServerRequest(
                    id: id,
                    method: method
                )
            }
            return
        }

        if let id = inbound.id {
            guard case let .number(number) = id,
                  number.isFinite,
                  number.rounded() == number,
                  number >= Double(Int.min),
                  number <= Double(Int.max) else {
                return
            }
            let requestID = Int(number)
            guard let continuation = pendingRequests.removeValue(
                forKey: requestID
            ) else {
                return
            }
            if let error = inbound.error {
                continuation.resume(
                    throwing: FIREBridgeError.appServerRejected(
                        code: error.code,
                        message: error.message
                    )
                )
            } else if let result = inbound.result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(
                    throwing: FIREBridgeError.appServerProtocolError(
                        "请求 \(requestID) 没有 result 或 error。"
                    )
                )
            }
            return
        }

        guard let method = inbound.method, let params = inbound.params else {
            return
        }
        switch method {
        case "item/completed":
            captureAgentMessage(params)
        case "turn/completed":
            completeTurn(params)
        default:
            break
        }
    }

    private func rejectUnsupportedServerRequest(
        id: JSONValue,
        method: String
    ) async {
        let response = ServerErrorResponse(
            id: id,
            error: .init(
                code: -32601,
                message: "FIRE Bridge 不支持 App Server 请求 \(method)。"
            )
        )
        guard let data = try? encoder.encode(response) else { return }
        try? await connection.send(data)
    }

    private func captureAgentMessage(_ params: JSONValue) {
        guard let turnID = params["turnId"]?.stringValue,
              !cancelledTurnIDs.contains(turnID),
              let item = params["item"],
              item["type"]?.stringValue == "agentMessage",
              let text = item["text"]?.stringValue else {
            return
        }
        agentMessagesByTurn[turnID, default: []].append(text)
    }

    private func completeTurn(_ params: JSONValue) {
        guard let turn = params["turn"],
              let turnID = turn["id"]?.stringValue else {
            return
        }
        if cancelledTurnIDs.remove(turnID) != nil {
            agentMessagesByTurn.removeValue(forKey: turnID)
            completedTurns.removeValue(forKey: turnID)
            return
        }
        let status = turn["status"]?.stringValue
        let capturedOutput = agentMessagesByTurn.removeValue(forKey: turnID)?.last
        let outputFromTurn: String?
        if let items = turn["items"]?.arrayValue {
            outputFromTurn = items
                .reversed()
                .first(where: {
                    $0["type"]?.stringValue == "agentMessage"
                })?["text"]?.stringValue
        } else {
            outputFromTurn = nil
        }
        let output = capturedOutput ?? outputFromTurn
        let error: FIREBridgeError?
        if status == "failed" {
            let message = turn["error"]?["message"]?.stringValue ?? "Codex 回合失败。"
            error = FIREBridgeError.appServerRejected(code: nil, message: message)
        } else if status == "interrupted" {
            error = FIREBridgeError.appServerDisconnected("Codex 回合被中断。")
        } else {
            error = nil
        }

        if let continuation = pendingTurns.removeValue(forKey: turnID) {
            if let error {
                continuation.resume(throwing: error)
            } else if let output {
                continuation.resume(returning: output)
            } else {
                continuation.resume(
                    throwing: FIREBridgeError.invalidStructuredOutput(
                        "Codex 没有返回最终结构化消息。"
                    )
                )
            }
        } else {
            completedTurns[turnID] = CompletedTurn(output: output, error: error)
        }
    }

    private func failRequest(id: Int, error: Error) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func cancelRequest(id: Int) {
        pendingRequests.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func cancelTurnWait(turnID: String, threadID: String) {
        cancelledTurnIDs.insert(turnID)
        completedTurns.removeValue(forKey: turnID)
        agentMessagesByTurn.removeValue(forKey: turnID)
        pendingTurns.removeValue(forKey: turnID)?.resume(
            throwing: CancellationError()
        )

        let interrupt = CodexRequestBuilder.interruptTurn(
            id: takeRequestID(),
            threadID: threadID,
            turnID: turnID
        )
        guard let data = try? encoder.encode(interrupt) else { return }
        Task {
            try? await connection.send(data)
        }
    }

    private func connectionEnded(_ error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        requests.forEach { $0.resume(throwing: error) }

        let turns = pendingTurns.values
        pendingTurns.removeAll()
        turns.forEach { $0.resume(throwing: error) }
        completedTurns.removeAll()
        agentMessagesByTurn.removeAll()
        cancelledTurnIDs.removeAll()
        isConnected = false
    }

    private func parseThreadID(_ result: JSONValue) throws -> String {
        guard let threadID = result["thread"]?["id"]?.stringValue else {
            throw FIREBridgeError.appServerProtocolError("响应缺少 thread.id。")
        }
        return threadID
    }

    private func requireConnection() throws {
        guard isConnected else {
            throw FIREBridgeError.appServerDisconnected("尚未初始化。")
        }
    }

    private func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private static func describe(_ error: AnalysisSchemaError) -> String {
        switch error {
        case let .unsupportedVersion(version):
            return "不支持报告版本 \(version)。"
        case let .invalidActionCount(count):
            return "行动建议必须为一到三条，实际为 \(count) 条。"
        case .missingEvidence:
            return "报告至少需要一条证据。"
        case let .duplicateEvidenceIDs(identifiers):
            return "证据 ID 重复：\(identifiers.joined(separator: "、"))"
        case let .emptyEvidenceReferences(fields):
            return "以下字段必须引用至少一条证据：\(fields.joined(separator: "、"))"
        case let .missingEvidenceReferences(references):
            return "证据引用不存在：\(references.joined(separator: "、"))"
        }
    }

    private static func describeDecoding(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "缺少字段 \(key.stringValue)：\(context.debugDescription)"
        case let DecodingError.typeMismatch(_, context):
            return "字段类型错误：\(context.debugDescription)"
        case let DecodingError.valueNotFound(_, context):
            return "字段值缺失：\(context.debugDescription)"
        case let DecodingError.dataCorrupted(context):
            return "JSON 数据无效：\(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}

extension CodexAppServerClient: CodexAppServerServing {}
#endif
