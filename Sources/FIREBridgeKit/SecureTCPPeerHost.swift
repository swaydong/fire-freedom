#if os(macOS)
@preconcurrency import Network
import Foundation

public struct SecureTCPPeerHostState: Equatable, Sendable {
    public let isListening: Bool
    public let connectedPeerNames: [String]
    public let lastError: String?

    public init(
        isListening: Bool,
        connectedPeerNames: [String],
        lastError: String?
    ) {
        self.isListening = isListening
        self.connectedPeerNames = connectedPeerNames
        self.lastError = lastError
    }
}

private struct TCPHostHandshake {
    let transcript: TCPReconnectTranscriptV1
    let secret: Data
}

private enum TCPHostConnectionPhase {
    case waitingForConnection
    case waitingForInvitation
    case waitingForResponse(TCPHostHandshake)
    case authenticated(clientID: UUID, channel: SecureBridgeChannel)

    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
}

private final class TCPHostConnectionContext: @unchecked Sendable {
    let id = UUID()
    let generation: UInt64
    let connection: NWConnection
    let hostNonce: Data
    var frameDecoder = TCPFrameDecoder()
    var phase: TCPHostConnectionPhase = .waitingForConnection
    var handshakeTimeout: DispatchWorkItem?

    init(generation: UInt64, connection: NWConnection, hostNonce: Data) {
        self.generation = generation
        self.connection = connection
        self.hostNonce = hostNonce
    }
}

public final class SecureTCPPeerHost: @unchecked Sendable {
    public typealias EnvelopeHandler = @Sendable (
        BridgeEnvelopeV1
    ) async -> BridgeEnvelopeV1?
    public typealias StateHandler = @Sendable (SecureTCPPeerHostState) -> Void

    private static let maximumUnauthenticatedConnections = 8
    private static let handshakeTimeout: TimeInterval = 10
    private static let receiveChunkBytes = 64 * 1_024

    private let queue = DispatchQueue(
        label: "com.openai.fire-freedom.tcp-host"
    )
    private let observerLock = NSLock()
    private let encoder = BridgeWire.makeEncoder()
    private let decoder = BridgeWire.makeDecoder()
    private let credentialStore: PairingCredentialStore
    private let hostID: UUID
    private let displayName: String

    private var listener: NWListener?
    private var isListening = false
    private var nextGeneration: UInt64 = 0
    private var connections: [UUID: TCPHostConnectionContext] = [:]
    private var authenticatedConnections: [UUID: UUID] = [:]
    private var envelopeHandler: EnvelopeHandler?
    private var lastError: String?

    private var observedState = SecureTCPPeerHostState(
        isListening: false,
        connectedPeerNames: [],
        lastError: nil
    )
    private var stateHandler: StateHandler?

    public init(
        credentialStore: PairingCredentialStore = PairingCredentialStore(),
        displayName: String = ProcessInfo.processInfo.hostName
    ) throws {
        self.credentialStore = credentialStore
        self.hostID = try credentialStore.stableIdentity()
        let normalizedName = displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.displayName = String(
            (normalizedName.isEmpty ? "FIRE Bridge" : normalizedName).prefix(48)
        )
    }

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.connection.cancel() }
    }

    public func setEnvelopeHandler(_ handler: EnvelopeHandler?) {
        queue.async { [weak self] in
            self?.envelopeHandler = handler
        }
    }

    public func setStateHandler(_ handler: StateHandler?) {
        observerLock.lock()
        stateHandler = handler
        let state = observedState
        observerLock.unlock()
        handler?(state)
    }

    public func stateSnapshot() -> SecureTCPPeerHostState {
        observerLock.lock()
        defer { observerLock.unlock() }
        return observedState
    }

    public func start() throws {
        let parameters = Self.makeParameters()
        let replacement = try NWListener(using: parameters, on: .any)
        replacement.service = NWListener.Service(
            name: displayName,
            type: "_\(BridgeWire.tcpServiceType)._tcp",
            domain: nil,
            txtRecord: NWTXTRecord(TCPDiscoveryInfo.encode(hostID: hostID))
        )
        replacement.stateUpdateHandler = { [weak self, weak replacement] state in
            guard let self, let replacement else { return }
            self.handleListenerState(state, listener: replacement)
        }
        replacement.newConnectionHandler = { [weak self, weak replacement] connection in
            guard let self, let replacement else {
                connection.cancel()
                return
            }
            self.accept(connection, from: replacement)
        }

        queue.async { [weak self] in
            guard let self else {
                replacement.cancel()
                return
            }
            guard self.listener == nil else {
                replacement.cancel()
                return
            }
            self.listener = replacement
            replacement.start(queue: self.queue)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            let activeListener = self.listener
            self.listener = nil
            self.isListening = false
            activeListener?.stateUpdateHandler = nil
            activeListener?.newConnectionHandler = nil
            activeListener?.cancel()

            let activeConnections = Array(self.connections.values)
            self.connections.removeAll()
            self.authenticatedConnections.removeAll()
            for context in activeConnections {
                context.handshakeTimeout?.cancel()
                context.connection.stateUpdateHandler = nil
                context.connection.cancel()
            }
            self.publishState()
        }
    }

    private static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.preferNoProxies = true
        return parameters
    }

    private func handleListenerState(
        _ state: NWListener.State,
        listener candidate: NWListener
    ) {
        guard listener === candidate else { return }
        switch state {
        case .setup:
            break
        case .ready:
            isListening = true
            lastError = nil
            publishState()
        case .waiting(let error):
            isListening = false
            lastError = error.localizedDescription
            publishState()
        case .failed(let error):
            listener = nil
            isListening = false
            lastError = error.localizedDescription
            candidate.cancel()
            publishState()
        case .cancelled:
            listener = nil
            isListening = false
            publishState()
        @unknown default:
            break
        }
    }

    private func accept(
        _ connection: NWConnection,
        from candidate: NWListener
    ) {
        guard listener === candidate else {
            connection.cancel()
            return
        }
        let unauthenticatedCount = connections.values.reduce(into: 0) {
            if !$1.phase.isAuthenticated {
                $0 += 1
            }
        }
        guard unauthenticatedCount
                < Self.maximumUnauthenticatedConnections else {
            lastError = "TCP 重连请求过多，请稍后重试。"
            connection.cancel()
            publishState()
            return
        }

        do {
            nextGeneration &+= 1
            let context = TCPHostConnectionContext(
                generation: nextGeneration,
                connection: connection,
                hostNonce: try PairingAuthenticator.randomSecret(byteCount: 24)
            )
            connections[context.id] = context
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleConnectionState(
                    state,
                    id: context.id,
                    generation: context.generation
                )
            }
            let timeout = DispatchWorkItem { [weak self] in
                self?.expireHandshake(
                    id: context.id,
                    generation: context.generation
                )
            }
            context.handshakeTimeout = timeout
            queue.asyncAfter(
                deadline: .now() + Self.handshakeTimeout,
                execute: timeout
            )
            connection.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
            connection.cancel()
            publishState()
        }
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        id: UUID,
        generation: UInt64
    ) {
        guard let context = currentContext(id: id, generation: generation) else {
            return
        }
        switch state {
        case .setup, .preparing, .waiting:
            break
        case .ready:
            guard case .waitingForConnection = context.phase else { return }
            do {
                context.phase = .waitingForInvitation
                try sendRaw(
                    BridgeEnvelopeV1(
                        type: .tcpReconnectHello,
                        payload: TCPReconnectHelloV1(
                            hostID: hostID,
                            hostNonce: context.hostNonce
                        ),
                        encoder: encoder
                    ),
                    on: context
                )
                receiveNext(on: context)
            } catch {
                close(context, error: error)
            }
        case .failed(let error):
            close(context, error: error)
        case .cancelled:
            close(context, error: nil, cancelConnection: false)
        @unknown default:
            close(
                context,
                error: FIREBridgeError.appServerDisconnected(
                    "TCP 连接进入未知状态。"
                )
            )
        }
    }

    private func receiveNext(on context: TCPHostConnectionContext) {
        context.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.receiveChunkBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self,
                  let current = self.currentContext(
                    id: context.id,
                    generation: context.generation
                  ) else {
                return
            }
            do {
                if let data, !data.isEmpty {
                    let frames = try current.frameDecoder.append(data)
                    for frame in frames {
                        guard self.currentContext(
                            id: current.id,
                            generation: current.generation
                        ) != nil else {
                            return
                        }
                        try self.handle(frame, on: current)
                    }
                }
                if let error {
                    throw error
                }
                if isComplete {
                    try current.frameDecoder.finish()
                    self.close(current, error: nil)
                } else {
                    self.receiveNext(on: current)
                }
            } catch {
                self.close(current, error: error)
            }
        }
    }

    private func handle(
        _ frame: Data,
        on context: TCPHostConnectionContext
    ) throws {
        let outer = try decoder.decode(BridgeEnvelopeV1.self, from: frame)
        guard outer.version == BridgeWire.protocolVersion else {
            throw FIREBridgeError.invalidMessage(
                "不支持协议版本 \(outer.version)。"
            )
        }

        switch context.phase {
        case .waitingForConnection:
            throw FIREBridgeError.pairingRejected("TCP 连接尚未就绪。")
        case .waitingForInvitation:
            try handleInvitation(outer, on: context)
        case .waitingForResponse(let handshake):
            try handleResponse(outer, handshake: handshake, on: context)
        case .authenticated(_, let channel):
            guard outer.type == .secureMessage else {
                throw FIREBridgeError.pairingRejected(
                    "认证后只接受受保护的业务消息。"
                )
            }
            let envelope = try channel.open(outer)
            guard let handler = envelopeHandler else { return }
            let connectionID = context.id
            let generation = context.generation
            Task { [weak self] in
                guard let response = await handler(envelope) else { return }
                self?.queue.async { [weak self] in
                    self?.sendBusiness(
                        response,
                        connectionID: connectionID,
                        generation: generation
                    )
                }
            }
        }
    }

    private func handleInvitation(
        _ envelope: BridgeEnvelopeV1,
        on context: TCPHostConnectionContext
    ) throws {
        guard envelope.type == .tcpReconnectInvitation else {
            throw FIREBridgeError.pairingRejected("TCP 认证消息顺序无效。")
        }
        let invitation = try envelope.decodePayload(
            TCPReconnectInvitationV1.self,
            decoder: decoder
        )
        let transcript = invitation.transcript
        guard transcript.version == BridgeWire.protocolVersion,
              transcript.hostID == hostID,
              transcript.hostNonce == context.hostNonce,
              transcript.hostNonce.count >= 16,
              transcript.clientNonce.count >= 16,
              let secret = try credentialStore.load(
                peerID: transcript.clientID
              ) else {
            throw FIREBridgeError.pairingRejected("找不到有效的已配对凭据。")
        }
        guard PairingAuthenticator.constantTimeVerify(
            invitation.clientProof,
            expected: PairingAuthenticator.tcpClientInvitationProof(
                secret: secret,
                transcript: transcript
            )
        ) else {
            throw FIREBridgeError.pairingRejected("iPhone TCP 重连证明无效。")
        }

        let handshake = TCPHostHandshake(
            transcript: transcript,
            secret: secret
        )
        context.phase = .waitingForResponse(handshake)
        try sendRaw(
            BridgeEnvelopeV1(
                type: .tcpReconnectChallenge,
                payload: TCPReconnectChallengeV1(
                    transcript: transcript,
                    hostProof: PairingAuthenticator.tcpHostChallengeProof(
                        secret: secret,
                        transcript: transcript
                    )
                ),
                encoder: encoder
            ),
            on: context
        )
    }

    private func handleResponse(
        _ envelope: BridgeEnvelopeV1,
        handshake: TCPHostHandshake,
        on context: TCPHostConnectionContext
    ) throws {
        guard envelope.type == .tcpReconnectResponse else {
            throw FIREBridgeError.pairingRejected("TCP 认证消息顺序无效。")
        }
        let response = try envelope.decodePayload(
            TCPReconnectResponseV1.self,
            decoder: decoder
        )
        let transcript = handshake.transcript
        guard response.hostID == hostID,
              response.clientID == transcript.clientID,
              PairingAuthenticator.constantTimeVerify(
                response.clientProof,
                expected: PairingAuthenticator.tcpClientResponseProof(
                    secret: handshake.secret,
                    transcript: transcript
                )
              ) else {
            throw FIREBridgeError.pairingRejected("iPhone TCP 响应无效。")
        }

        let authenticationContext = PairingAuthenticator
            .tcpAuthenticationContext(transcript)
        let channel = SecureBridgeChannel(
            key: PairingAuthenticator.deriveChannelKey(
                secret: handshake.secret,
                context: authenticationContext
            ),
            localID: hostID,
            remoteID: transcript.clientID
        )
        let completion = try BridgeEnvelopeV1(
            type: .tcpAuthenticationComplete,
            payload: AuthenticationCompleteV1(
                hostID: hostID,
                clientID: transcript.clientID,
                hostProof: PairingAuthenticator.tcpAuthenticationCompleteProof(
                    secret: handshake.secret,
                    transcript: transcript
                )
            ),
            encoder: encoder
        )
        let completionFrame = try encodedFrame(completion)

        context.handshakeTimeout?.cancel()
        context.handshakeTimeout = nil
        context.phase = .authenticated(
            clientID: transcript.clientID,
            channel: channel
        )
        let replacedID = authenticatedConnections.updateValue(
            context.id,
            forKey: transcript.clientID
        )
        if let replacedID,
           replacedID != context.id,
           let replaced = connections[replacedID] {
            close(replaced, error: nil, publish: false)
        }
        lastError = nil
        send(completionFrame, on: context)
        publishState()
    }

    private func sendBusiness(
        _ envelope: BridgeEnvelopeV1,
        connectionID: UUID,
        generation: UInt64
    ) {
        guard let context = currentContext(
            id: connectionID,
            generation: generation
        ), case .authenticated(_, let channel) = context.phase else {
            return
        }
        do {
            try sendRaw(channel.seal(envelope), on: context)
        } catch {
            close(context, error: error)
        }
    }

    private func sendRaw(
        _ envelope: BridgeEnvelopeV1,
        on context: TCPHostConnectionContext
    ) throws {
        guard BridgeSecurityPolicy.isHandshake(envelope.type)
                || envelope.type == .secureMessage else {
            throw FIREBridgeError.pairingRejected(
                "业务消息必须使用安全通道。"
            )
        }
        send(try encodedFrame(envelope), on: context)
    }

    private func encodedFrame(_ envelope: BridgeEnvelopeV1) throws -> Data {
        try TCPFrameDecoder.frame(encoder.encode(envelope))
    }

    private func send(_ data: Data, on context: TCPHostConnectionContext) {
        context.connection.send(
            content: data,
            completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.queue.async { [weak self] in
                    guard let self,
                          let current = self.currentContext(
                            id: context.id,
                            generation: context.generation
                          ) else {
                        return
                    }
                    self.close(current, error: error)
                }
            }
        )
    }

    private func expireHandshake(id: UUID, generation: UInt64) {
        guard let context = currentContext(id: id, generation: generation),
              !context.phase.isAuthenticated else {
            return
        }
        close(
            context,
            error: FIREBridgeError.pairingRejected("TCP 重连握手超时。")
        )
    }

    private func currentContext(
        id: UUID,
        generation: UInt64
    ) -> TCPHostConnectionContext? {
        guard let context = connections[id],
              context.generation == generation else {
            return nil
        }
        return context
    }

    private func close(
        _ context: TCPHostConnectionContext,
        error: Error?,
        cancelConnection: Bool = true,
        publish: Bool = true
    ) {
        guard let current = currentContext(
            id: context.id,
            generation: context.generation
        ) else {
            return
        }
        connections.removeValue(forKey: current.id)
        current.handshakeTimeout?.cancel()
        current.handshakeTimeout = nil
        if case .authenticated(let clientID, _) = current.phase,
           authenticatedConnections[clientID] == current.id {
            authenticatedConnections.removeValue(forKey: clientID)
        }
        current.connection.stateUpdateHandler = nil
        if cancelConnection {
            current.connection.cancel()
        }
        if let error {
            lastError = error.localizedDescription
        }
        if publish {
            publishState()
        }
    }

    private func publishState() {
        let state = SecureTCPPeerHostState(
            isListening: isListening,
            connectedPeerNames: authenticatedConnections.keys
                .map { "iPhone · \($0.uuidString.prefix(4))" }
                .sorted(),
            lastError: lastError
        )
        observerLock.lock()
        observedState = state
        let handler = stateHandler
        observerLock.unlock()
        handler?(state)
    }
}
#endif
