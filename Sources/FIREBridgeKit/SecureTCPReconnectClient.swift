import Foundation
@preconcurrency import Network

public struct TCPReconnectClientState: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case browsing
        case connecting
        case authenticated
        case stopped
        case failed
    }

    public let status: Status
    public let hostID: UUID?
    public let peerName: String?
    public let message: String

    public var isAuthenticated: Bool {
        status == .authenticated
    }

    public init(
        status: Status,
        hostID: UUID? = nil,
        peerName: String? = nil,
        message: String
    ) {
        self.status = status
        self.hostID = hostID
        self.peerName = peerName
        self.message = message
    }
}

public enum TCPReconnectError: LocalizedError, Sendable {
    case stopped
    case notAuthenticated
    case invalidRequest
    case duplicateRequest
    case requestTimedOut
    case handshakeTimedOut
    case authenticationFailed
    case invalidProtocol(String)
    case transportUnavailable(String)
    case sendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .stopped:
            "TCP 桥接已停止。"
        case .notAuthenticated:
            "TCP 桥接尚未完成安全认证。"
        case .invalidRequest:
            "TCP 桥接请求无效。"
        case .duplicateRequest:
            "同一请求正在处理中。"
        case .requestTimedOut:
            "Mac 响应超时。"
        case .handshakeTimedOut:
            "TCP 安全认证超时。"
        case .authenticationFailed:
            "Mac TCP 身份认证失败。"
        case .invalidProtocol(let message):
            "TCP 桥接协议无效：\(message)"
        case .transportUnavailable(let message):
            "TCP 连接不可用：\(message)"
        case .sendFailed(let message):
            "TCP 发送失败：\(message)"
        }
    }
}

public final class SecureTCPReconnectClient: @unchecked Sendable {
    private struct Candidate {
        let hostID: UUID
        let peerName: String
        let endpoint: NWEndpoint
    }

    private enum ConnectionPhase {
        case awaitingHello
        case awaitingChallenge(
            transcript: TCPReconnectTranscriptV1,
            secret: Data
        )
        case awaitingAuthentication(
            transcript: TCPReconnectTranscriptV1,
            secret: Data
        )
        case authenticated
    }

    private struct PendingRequest {
        let generation: UInt64
        let continuation: CheckedContinuation<BridgeEnvelopeV1, Error>
        let timeout: DispatchWorkItem
    }

    private let clientID: UUID
    private let credentialStore: PairingCredentialStore
    private let heartbeatInterval: TimeInterval
    private let queue = DispatchQueue(
        label: "com.openai.fire-freedom.tcp-reconnect-client"
    )
    private let encoder = BridgeWire.makeEncoder()
    private let decoder = BridgeWire.makeDecoder()

    private var stateHandler: (@Sendable (TCPReconnectClientState) -> Void)?
    private var currentState = TCPReconnectClientState(
        status: .stopped,
        message: "TCP 桥接未启动"
    )
    private var isStarted = false
    private var browser: NWBrowser?
    private var browserRetry: DispatchWorkItem?
    private var candidates: [UUID: Candidate] = [:]
    private var blockedHostIDs: Set<UUID> = []

    private var connection: NWConnection?
    private var connectionGeneration: UInt64 = 0
    private var connectionHostID: UUID?
    private var connectionPeerName: String?
    private var connectionPhase: ConnectionPhase?
    private var frameDecoder = TCPFrameDecoder()
    private var secureChannel: SecureBridgeChannel?
    private var handshakeTimeout: DispatchWorkItem?
    private var heartbeat: DispatchWorkItem?
    private var reconnectRetry: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var pending: [UUID: PendingRequest] = [:]
    private var cancelledRequestIDs: Set<UUID> = []

    public convenience init(
        clientID: UUID,
        credentialStore: PairingCredentialStore
    ) {
        self.init(
            clientID: clientID,
            credentialStore: credentialStore,
            heartbeatInterval: 5
        )
    }

    init(
        clientID: UUID,
        credentialStore: PairingCredentialStore,
        heartbeatInterval: TimeInterval
    ) {
        self.clientID = clientID
        self.credentialStore = credentialStore
        self.heartbeatInterval = heartbeatInterval
    }

    public func setStateHandler(
        _ handler: (@Sendable (TCPReconnectClientState) -> Void)?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateHandler = handler
            handler?(self.currentState)
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            self.isStarted = true
            self.reconnectAttempt = 0
            self.blockedHostIDs.removeAll()
            self.publish(
                status: .browsing,
                message: "正在寻找已配对的 Mac…"
            )
            self.startBrowser()
        }
    }

    public func restartAfterForeground() {
        queue.async { [weak self] in
            guard let self else { return }

            self.isStarted = true
            self.browserRetry?.cancel()
            self.browserRetry = nil
            self.reconnectRetry?.cancel()
            self.reconnectRetry = nil

            let previousBrowser = self.browser
            self.browser = nil
            previousBrowser?.cancel()
            self.candidates.removeAll()
            self.blockedHostIDs.removeAll()
            self.reconnectAttempt = 0

            self.invalidateConnection(
                error: TCPReconnectError.transportUnavailable(
                    "App 已返回前台，正在重新连接。"
                ),
                retry: false,
                publishFailure: false
            )
            self.publish(
                status: .browsing,
                message: "正在寻找已配对的 Mac…"
            )
            self.startBrowser()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.isStarted = false
            self.browserRetry?.cancel()
            self.browserRetry = nil
            self.reconnectRetry?.cancel()
            self.reconnectRetry = nil
            self.browser?.cancel()
            self.browser = nil
            self.candidates.removeAll()
            self.blockedHostIDs.removeAll()
            self.invalidateConnection(
                error: TCPReconnectError.stopped,
                retry: false,
                publishFailure: false
            )
            self.publish(status: .stopped, message: "TCP 桥接已停止")
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.invalidateConnection(
                error: TCPReconnectError.transportUnavailable("已主动断开。"),
                retry: true,
                publishFailure: false
            )
        }
    }

    public func request(
        _ envelope: BridgeEnvelopeV1,
        timeout: TimeInterval
    ) async throws -> BridgeEnvelopeV1 {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(
                            throwing: TCPReconnectError.stopped
                        )
                        return
                    }
                    self.beginRequest(
                        envelope,
                        timeout: timeout,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            queue.async { [weak self] in
                self?.cancelRequest(id: envelope.id)
            }
        }
    }

    private func startBrowser() {
        guard isStarted, browser == nil else { return }

        let parameters = makeTCPParameters()
        let newBrowser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: "_\(BridgeWire.tcpServiceType)._tcp",
                domain: nil
            ),
            using: parameters
        )
        browser = newBrowser
        newBrowser.stateUpdateHandler = { [weak self, weak newBrowser] state in
            guard let self, let newBrowser else { return }
            self.queue.async {
                self.handleBrowserState(state, browser: newBrowser)
            }
        }
        newBrowser.browseResultsChangedHandler = {
            [weak self, weak newBrowser] results, _ in
            guard let self, let newBrowser else { return }
            self.queue.async {
                guard self.browser === newBrowser else { return }
                self.updateCandidates(from: results)
            }
        }
        newBrowser.start(queue: queue)
    }

    private func handleBrowserState(
        _ state: NWBrowser.State,
        browser reportedBrowser: NWBrowser
    ) {
        guard browser === reportedBrowser else { return }
        switch state {
        case .ready:
            browserRetry?.cancel()
            browserRetry = nil
            if connection == nil {
                publish(
                    status: .browsing,
                    message: "正在寻找已配对的 Mac…"
                )
                attemptConnectionIfPossible()
            }
        case .waiting(let error):
            if connection == nil {
                publish(
                    status: .failed,
                    message: "暂时无法发现 Mac：\(error.localizedDescription)"
                )
            }
        case .failed(let error):
            self.browser = nil
            reportedBrowser.cancel()
            candidates.removeAll()
            publish(
                status: .failed,
                message: "查找 Mac 失败：\(error.localizedDescription)"
            )
            scheduleBrowserRestart()
        case .cancelled:
            if isStarted, self.browser === reportedBrowser {
                self.browser = nil
                scheduleBrowserRestart()
            }
        case .setup:
            break
        @unknown default:
            publish(status: .failed, message: "Mac 发现状态未知")
        }
    }

    private func scheduleBrowserRestart() {
        guard isStarted, browserRetry == nil else { return }
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.browserRetry = nil
            self.startBrowser()
        }
        browserRetry = retry
        queue.asyncAfter(deadline: .now() + 2, execute: retry)
    }

    private func updateCandidates(from results: Set<NWBrowser.Result>) {
        let previousHostIDs = Set(candidates.keys)
        var updated: [UUID: Candidate] = [:]

        for result in results {
            guard case .bonjour(let txtRecord) = result.metadata,
                  let hostID = try? TCPDiscoveryInfo.decode(
                      txtRecord.dictionary
                  ),
                  (try? credentialStore.load(peerID: hostID)) != nil else {
                continue
            }
            updated[hostID] = Candidate(
                hostID: hostID,
                peerName: Self.peerName(
                    endpoint: result.endpoint,
                    hostID: hostID
                ),
                endpoint: result.endpoint
            )
        }

        candidates = updated
        let removedHostIDs = previousHostIDs.subtracting(updated.keys)
        blockedHostIDs.subtract(removedHostIDs)

        if connection == nil, reconnectRetry == nil {
            attemptConnectionIfPossible()
        }
    }

    private func attemptConnectionIfPossible() {
        guard isStarted, connection == nil else { return }

        let available = candidates.values
            .filter { !blockedHostIDs.contains($0.hostID) }
            .sorted {
                if $0.peerName == $1.peerName {
                    return $0.hostID.uuidString < $1.hostID.uuidString
                }
                return $0.peerName < $1.peerName
            }
        guard let candidate = available.first else {
            publish(
                status: candidates.isEmpty ? .browsing : .failed,
                message: candidates.isEmpty
                    ? "正在寻找已配对的 Mac…"
                    : "TCP 安全认证失败，请刷新后重试"
            )
            return
        }

        do {
            guard try credentialStore.load(peerID: candidate.hostID) != nil else {
                candidates.removeValue(forKey: candidate.hostID)
                attemptConnectionIfPossible()
                return
            }
        } catch {
            blockedHostIDs.insert(candidate.hostID)
            publish(
                status: .failed,
                hostID: candidate.hostID,
                peerName: candidate.peerName,
                message: "无法读取已配对凭据：\(error.localizedDescription)"
            )
            return
        }

        connectionGeneration &+= 1
        let generation = connectionGeneration
        let newConnection = NWConnection(
            to: candidate.endpoint,
            using: makeTCPParameters()
        )
        connection = newConnection
        connectionHostID = candidate.hostID
        connectionPeerName = candidate.peerName
        connectionPhase = .awaitingHello
        secureChannel = nil
        frameDecoder = TCPFrameDecoder()
        publish(
            status: .connecting,
            hostID: candidate.hostID,
            peerName: candidate.peerName,
            message: "正在连接 \(candidate.peerName)…"
        )

        newConnection.stateUpdateHandler = {
            [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            self.queue.async {
                self.handleConnectionState(
                    state,
                    connection: newConnection,
                    generation: generation
                )
            }
        }
        newConnection.start(queue: queue)
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        connection reportedConnection: NWConnection,
        generation: UInt64
    ) {
        guard generation == connectionGeneration,
              connection === reportedConnection else {
            return
        }
        switch state {
        case .ready:
            scheduleHandshakeTimeout(generation: generation)
            publish(
                status: .connecting,
                hostID: connectionHostID,
                peerName: connectionPeerName,
                message: "正在验证 Mac 身份…"
            )
            receiveNext(
                connection: reportedConnection,
                generation: generation
            )
        case .waiting(let error):
            publish(
                status: .connecting,
                hostID: connectionHostID,
                peerName: connectionPeerName,
                message: "等待局域网可用：\(error.localizedDescription)"
            )
        case .failed(let error):
            invalidateConnection(
                error: TCPReconnectError.transportUnavailable(
                    error.localizedDescription
                ),
                retry: true,
                publishFailure: true
            )
        case .cancelled:
            if isStarted {
                invalidateConnection(
                    error: TCPReconnectError.transportUnavailable("连接已中断。"),
                    retry: true,
                    publishFailure: true
                )
            }
        case .setup, .preparing:
            break
        @unknown default:
            invalidateConnection(
                error: TCPReconnectError.transportUnavailable("连接状态未知。"),
                retry: true,
                publishFailure: true
            )
        }
    }

    private func scheduleHandshakeTimeout(generation: UInt64) {
        handshakeTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectionGeneration == generation,
                  !self.isAuthenticated else {
                return
            }
            self.failProtocol(
                TCPReconnectError.handshakeTimedOut,
                blockCurrentHost: false
            )
        }
        handshakeTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func receiveNext(
        connection reportedConnection: NWConnection,
        generation: UInt64
    ) {
        guard generation == connectionGeneration,
              connection === reportedConnection else {
            return
        }
        reportedConnection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self, weak reportedConnection] content, _, isComplete, error in
            guard let self, let reportedConnection else { return }
            self.queue.async {
                self.handleReceive(
                    content: content,
                    isComplete: isComplete,
                    error: error,
                    connection: reportedConnection,
                    generation: generation
                )
            }
        }
    }

    private func handleReceive(
        content: Data?,
        isComplete: Bool,
        error: NWError?,
        connection reportedConnection: NWConnection,
        generation: UInt64
    ) {
        guard generation == connectionGeneration,
              connection === reportedConnection else {
            return
        }

        do {
            if let content, !content.isEmpty {
                for frame in try frameDecoder.append(content) {
                    try handleFrame(frame, generation: generation)
                }
            }
        } catch let error as TCPReconnectError {
            failProtocol(error, blockCurrentHost: true)
            return
        } catch {
            failProtocol(
                TCPReconnectError.invalidProtocol(error.localizedDescription),
                blockCurrentHost: true
            )
            return
        }

        if let error {
            invalidateConnection(
                error: TCPReconnectError.transportUnavailable(
                    error.localizedDescription
                ),
                retry: true,
                publishFailure: true
            )
            return
        }
        if isComplete {
            do {
                try frameDecoder.finish()
            } catch {
                failProtocol(
                    TCPReconnectError.invalidProtocol(
                        error.localizedDescription
                    ),
                    blockCurrentHost: true
                )
                return
            }
            invalidateConnection(
                error: TCPReconnectError.transportUnavailable(
                    "Mac 已关闭连接。"
                ),
                retry: true,
                publishFailure: true
            )
            return
        }

        receiveNext(
            connection: reportedConnection,
            generation: generation
        )
    }

    private func handleFrame(
        _ frame: Data,
        generation: UInt64
    ) throws {
        guard generation == connectionGeneration else { return }
        let envelope = try decoder.decode(BridgeEnvelopeV1.self, from: frame)
        guard envelope.version == BridgeWire.protocolVersion else {
            throw TCPReconnectError.invalidProtocol("协议版本不受支持。")
        }

        guard let phase = connectionPhase else {
            throw TCPReconnectError.invalidProtocol("连接没有认证状态。")
        }
        switch phase {
        case .awaitingHello:
            try handleHello(envelope)
        case .awaitingChallenge(let transcript, let secret):
            try handleChallenge(
                envelope,
                transcript: transcript,
                secret: secret
            )
        case .awaitingAuthentication(let transcript, let secret):
            try handleAuthenticationComplete(
                envelope,
                transcript: transcript,
                secret: secret
            )
        case .authenticated:
            try handleSecureResponse(envelope, generation: generation)
        }
    }

    private func handleHello(_ envelope: BridgeEnvelopeV1) throws {
        guard envelope.type == .tcpReconnectHello,
              let expectedHostID = connectionHostID else {
            throw TCPReconnectError.invalidProtocol(
                "认证前未收到 Mac 新鲜握手参数。"
            )
        }
        let hello = try envelope.decodePayload(
            TCPReconnectHelloV1.self,
            decoder: decoder
        )
        guard hello.version == BridgeWire.protocolVersion,
              hello.hostID == expectedHostID,
              hello.hostNonce.count >= 16,
              let secret = try credentialStore.load(peerID: expectedHostID) else {
            throw TCPReconnectError.authenticationFailed
        }

        let clientNonce = try PairingAuthenticator.randomSecret(byteCount: 24)
        let transcript = TCPReconnectTranscriptV1(
            clientID: clientID,
            hostID: expectedHostID,
            hostNonce: hello.hostNonce,
            clientNonce: clientNonce
        )
        let invitation = TCPReconnectInvitationV1(
            transcript: transcript,
            clientProof: PairingAuthenticator.tcpClientInvitationProof(
                secret: secret,
                transcript: transcript
            )
        )
        connectionPhase = .awaitingChallenge(
            transcript: transcript,
            secret: secret
        )
        try sendHandshake(
            BridgeEnvelopeV1(
                type: .tcpReconnectInvitation,
                payload: invitation,
                encoder: encoder
            )
        )
    }

    private func handleChallenge(
        _ envelope: BridgeEnvelopeV1,
        transcript: TCPReconnectTranscriptV1,
        secret: Data
    ) throws {
        guard envelope.type == .tcpReconnectChallenge else {
            throw TCPReconnectError.invalidProtocol(
                "Mac TCP 认证消息顺序无效。"
            )
        }
        let challenge = try envelope.decodePayload(
            TCPReconnectChallengeV1.self,
            decoder: decoder
        )
        guard challenge.transcript == transcript,
              PairingAuthenticator.constantTimeVerify(
                  challenge.hostProof,
                  expected: PairingAuthenticator.tcpHostChallengeProof(
                      secret: secret,
                      transcript: transcript
                  )
              ) else {
            throw TCPReconnectError.authenticationFailed
        }

        let response = TCPReconnectResponseV1(
            hostID: transcript.hostID,
            clientID: clientID,
            clientProof: PairingAuthenticator.tcpClientResponseProof(
                secret: secret,
                transcript: transcript
            )
        )
        connectionPhase = .awaitingAuthentication(
            transcript: transcript,
            secret: secret
        )
        try sendHandshake(
            BridgeEnvelopeV1(
                type: .tcpReconnectResponse,
                payload: response,
                encoder: encoder
            )
        )
    }

    private func handleAuthenticationComplete(
        _ envelope: BridgeEnvelopeV1,
        transcript: TCPReconnectTranscriptV1,
        secret: Data
    ) throws {
        guard envelope.type == .tcpAuthenticationComplete else {
            throw TCPReconnectError.invalidProtocol(
                "Mac TCP 最终认证消息无效。"
            )
        }
        let completion = try envelope.decodePayload(
            AuthenticationCompleteV1.self,
            decoder: decoder
        )
        guard completion.hostID == transcript.hostID,
              completion.clientID == clientID,
              PairingAuthenticator.verifyTCPAuthenticationComplete(
                  completion.hostProof,
                  secret: secret,
                  transcript: transcript
              ) else {
            throw TCPReconnectError.authenticationFailed
        }

        let context = PairingAuthenticator.tcpAuthenticationContext(transcript)
        secureChannel = SecureBridgeChannel(
            key: PairingAuthenticator.deriveChannelKey(
                secret: secret,
                context: context
            ),
            localID: clientID,
            remoteID: transcript.hostID
        )
        connectionPhase = .authenticated
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        reconnectRetry?.cancel()
        reconnectRetry = nil
        reconnectAttempt = 0
        scheduleHeartbeat(generation: connectionGeneration)
        publish(
            status: .authenticated,
            hostID: transcript.hostID,
            peerName: connectionPeerName,
            message: "已通过 TCP 安全连接 \(connectionPeerName ?? "Mac")"
        )
    }

    private func handleSecureResponse(
        _ envelope: BridgeEnvelopeV1,
        generation: UInt64
    ) throws {
        guard envelope.type == .secureMessage,
              let secureChannel else {
            throw TCPReconnectError.invalidProtocol(
                "认证后只接受加密业务消息。"
            )
        }
        let response = try secureChannel.open(envelope)
        guard let request = pending[response.id],
              request.generation == generation else {
            return
        }
        pending.removeValue(forKey: response.id)
        request.timeout.cancel()
        request.continuation.resume(returning: response)
    }

    private func scheduleHeartbeat(generation: UInt64) {
        // Managed network filters can reset a fully idle LAN stream after
        // about 15 seconds, including while a long Codex request is running.
        heartbeat?.cancel()
        guard heartbeatInterval.isFinite, heartbeatInterval > 0 else {
            heartbeat = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.heartbeat = nil
            self.sendHeartbeat(generation: generation)
        }
        heartbeat = work
        queue.asyncAfter(
            deadline: .now() + heartbeatInterval,
            execute: work
        )
    }

    private func sendHeartbeat(generation: UInt64) {
        guard isStarted,
              connectionGeneration == generation,
              isAuthenticated,
              let secureChannel else {
            return
        }

        do {
            let ping = try BridgeEnvelopeV1(
                type: .ping,
                payload: PingPayloadV1(),
                encoder: encoder
            )
            let protected = try secureChannel.seal(ping)
            try sendFrame(protected) { [weak self] error in
                guard let self, let error else { return }
                self.queue.async {
                    guard self.connectionGeneration == generation else {
                        return
                    }
                    self.invalidateConnection(
                        error: TCPReconnectError.sendFailed(
                            error.localizedDescription
                        ),
                        retry: true,
                        publishFailure: true
                    )
                }
            }
            scheduleHeartbeat(generation: generation)
        } catch {
            invalidateConnection(
                error: TCPReconnectError.sendFailed(
                    error.localizedDescription
                ),
                retry: true,
                publishFailure: true
            )
        }
    }

    private func sendHandshake(_ envelope: BridgeEnvelopeV1) throws {
        guard BridgeSecurityPolicy.isHandshake(envelope.type),
              envelope.type != .secureMessage else {
            throw TCPReconnectError.invalidProtocol("握手消息类型无效。")
        }
        let generation = connectionGeneration
        try sendFrame(envelope) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                guard self.connectionGeneration == generation else { return }
                self.invalidateConnection(
                    error: TCPReconnectError.sendFailed(
                        error.localizedDescription
                    ),
                    retry: true,
                    publishFailure: true
                )
            }
        }
    }

    private func beginRequest(
        _ envelope: BridgeEnvelopeV1,
        timeout: TimeInterval,
        continuation: CheckedContinuation<BridgeEnvelopeV1, Error>
    ) {
        if cancelledRequestIDs.remove(envelope.id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard isStarted else {
            continuation.resume(throwing: TCPReconnectError.stopped)
            return
        }
        guard isAuthenticated,
              let secureChannel,
              connection != nil else {
            continuation.resume(
                throwing: TCPReconnectError.notAuthenticated
            )
            return
        }
        guard envelope.version == BridgeWire.protocolVersion,
              !BridgeSecurityPolicy.isHandshake(envelope.type),
              envelope.type != .secureMessage,
              timeout.isFinite,
              timeout > 0 else {
            continuation.resume(throwing: TCPReconnectError.invalidRequest)
            return
        }
        guard pending[envelope.id] == nil else {
            continuation.resume(throwing: TCPReconnectError.duplicateRequest)
            return
        }

        let generation = connectionGeneration
        do {
            let protected = try secureChannel.seal(envelope)
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self,
                      let request = self.pending[envelope.id],
                      request.generation == generation else {
                    return
                }
                self.pending.removeValue(forKey: envelope.id)
                request.continuation.resume(
                    throwing: TCPReconnectError.requestTimedOut
                )
            }
            pending[envelope.id] = PendingRequest(
                generation: generation,
                continuation: continuation,
                timeout: timeoutWork
            )
            try sendFrame(protected) { [weak self] error in
                guard let self, let error else { return }
                self.queue.async {
                    guard self.connectionGeneration == generation,
                          self.pending[envelope.id] != nil else {
                        return
                    }
                    self.invalidateConnection(
                        error: TCPReconnectError.sendFailed(
                            error.localizedDescription
                        ),
                        retry: true,
                        publishFailure: true
                    )
                }
            }
            queue.asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWork
            )
        } catch {
            pending.removeValue(forKey: envelope.id)?.timeout.cancel()
            continuation.resume(throwing: error)
        }
    }

    private func cancelRequest(id: UUID) {
        guard let request = pending.removeValue(forKey: id) else {
            cancelledRequestIDs.insert(id)
            return
        }
        request.timeout.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func sendFrame(
        _ envelope: BridgeEnvelopeV1,
        completion: (@Sendable (NWError?) -> Void)? = nil
    ) throws {
        guard let connection else {
            throw TCPReconnectError.notAuthenticated
        }
        let payload = try encoder.encode(envelope)
        let frame = try TCPFrameDecoder.frame(payload)
        connection.send(
            content: frame,
            contentContext: .defaultStream,
            isComplete: false,
            completion: .contentProcessed { error in
                completion?(error)
            }
        )
    }

    private var isAuthenticated: Bool {
        guard case .authenticated = connectionPhase else { return false }
        return secureChannel != nil
    }

    private func failProtocol(
        _ error: TCPReconnectError,
        blockCurrentHost: Bool
    ) {
        if blockCurrentHost, let connectionHostID {
            blockedHostIDs.insert(connectionHostID)
        }
        invalidateConnection(
            error: error,
            retry: !blockCurrentHost,
            publishFailure: true
        )
    }

    private func invalidateConnection(
        error: Error,
        retry: Bool,
        publishFailure: Bool
    ) {
        let failedHostID = connectionHostID
        let failedPeerName = connectionPeerName

        connectionGeneration &+= 1
        let oldConnection = connection
        connection = nil
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.cancel()
        connectionHostID = nil
        connectionPeerName = nil
        connectionPhase = nil
        secureChannel = nil
        frameDecoder = TCPFrameDecoder()
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        heartbeat?.cancel()
        heartbeat = nil
        failPending(with: error)

        if publishFailure {
            publish(
                status: .failed,
                hostID: failedHostID,
                peerName: failedPeerName,
                message: error.localizedDescription
            )
        }
        if retry, isStarted {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard reconnectRetry == nil else { return }
        let delays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt = min(reconnectAttempt + 1, delays.count - 1)
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.reconnectRetry = nil
            self.publish(
                status: .browsing,
                message: "连接中断，正在自动重连…"
            )
            self.attemptConnectionIfPossible()
        }
        reconnectRetry = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func failPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func publish(
        status: TCPReconnectClientState.Status,
        hostID: UUID? = nil,
        peerName: String? = nil,
        message: String
    ) {
        let state = TCPReconnectClientState(
            status: status,
            hostID: hostID,
            peerName: peerName,
            message: message
        )
        guard state != currentState else { return }
        currentState = state
        stateHandler?(state)
    }

    private func makeTCPParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        if let options = parameters.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options {
            options.noDelay = true
            options.enableKeepalive = true
            options.keepaliveIdle = 15
            options.keepaliveInterval = 5
            options.keepaliveCount = 3
            options.connectionTimeout = 10
        }
        parameters.includePeerToPeer = true
        parameters.preferNoProxies = true
        return parameters
    }

    private static func peerName(
        endpoint: NWEndpoint,
        hostID: UUID
    ) -> String {
        if case .service(let name, _, _, _) = endpoint,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "Mac \(hostID.uuidString.prefix(8))"
    }
}
