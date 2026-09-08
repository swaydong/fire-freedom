#if os(macOS)
@preconcurrency import MultipeerConnectivity
import CryptoKit
import Foundation

public struct SecurePeerHostState: Equatable, Sendable {
    public let isAdvertising: Bool
    public let isPairingOpen: Bool
    public let pairingSAS: String?
    public let connectedPeerNames: [String]
    public let lastError: String?

    public init(
        isAdvertising: Bool,
        isPairingOpen: Bool,
        pairingSAS: String?,
        connectedPeerNames: [String],
        lastError: String?
    ) {
        self.isAdvertising = isAdvertising
        self.isPairingOpen = isPairingOpen
        self.pairingSAS = pairingSAS
        self.connectedPeerNames = connectedPeerNames
        self.lastError = lastError
    }
}

private struct InitialHostHandshake {
    let clientID: UUID
    let transcript: InitialPairingTranscriptV1
    let sessionKey: SymmetricKey
}

private struct InitialHostCredential {
    let handshake: InitialHostHandshake
    let secret: Data
}

private struct ReconnectHostHandshake {
    let clientID: UUID
    let transcript: ReconnectTranscriptV1
    let secret: Data
}

private enum HostHandshake {
    case initialAwaitingConfirmation(InitialHostHandshake)
    case initialAwaitingReceipt(InitialHostCredential)
    case reconnectAwaitingConnection(ReconnectHostHandshake)
    case reconnectAwaitingResponse(ReconnectHostHandshake)
}

private struct AuthenticatedHostPeer {
    let clientID: UUID
    let channel: SecureBridgeChannel
}

public final class SecurePeerHost: NSObject, @unchecked Sendable {
    public typealias EnvelopeHandler = @Sendable (
        BridgeEnvelopeV1
    ) async -> BridgeEnvelopeV1?
    public typealias StateHandler = @Sendable (SecurePeerHostState) -> Void

    private let lock = NSLock()
    private let encoder = BridgeWire.makeEncoder()
    private let decoder = BridgeWire.makeDecoder()
    private let credentialStore: PairingCredentialStore
    private let hostID: UUID
    private let localPeerID: MCPeerID
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var currentHostNonce = Data()
    private var pairingPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var currentPairingSAS: String?
    private var handshakes: [MCPeerID: HostHandshake] = [:]
    private var authenticatedPeers: [MCPeerID: AuthenticatedHostPeer] = [:]
    private var envelopeHandler: EnvelopeHandler?
    private var stateHandler: StateHandler?
    private var lastError: String?

    public init(
        displayName: String = ProcessInfo.processInfo.hostName,
        credentialStore: PairingCredentialStore = PairingCredentialStore()
    ) throws {
        self.credentialStore = credentialStore
        self.hostID = try credentialStore.stableIdentity()
        self.localPeerID = MCPeerID(displayName: String(displayName.prefix(63)))
        super.init()
        self.session = MCSession(
            peer: localPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        self.session.delegate = self
    }

    deinit {
        advertiser?.stopAdvertisingPeer()
        session.disconnect()
    }

    public func setEnvelopeHandler(_ handler: EnvelopeHandler?) {
        lock.fireWithLock { envelopeHandler = handler }
    }

    public func setStateHandler(_ handler: StateHandler?) {
        lock.fireWithLock { stateHandler = handler }
        publishState()
    }

    @discardableResult
    public func startAdvertising(allowNewPairing: Bool = false) throws -> String? {
        if allowNewPairing {
            cancelPendingInitialPairing()
        }
        try restartAdvertising(
            allowNewPairing: allowNewPairing,
            clearPairingSAS: true
        )
        return nil
    }

    public func closeNewPairingWindow() {
        cancelPendingInitialPairing()
        do {
            try restartAdvertising(
                allowNewPairing: false,
                clearPairingSAS: true
            )
        } catch {
            record(error)
        }
    }

    public func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        lock.fireWithLock {
            pairingPrivateKey = nil
            currentPairingSAS = nil
        }
        publishState()
    }

    public func disconnectAll() {
        session.disconnect()
        lock.fireWithLock {
            handshakes.removeAll()
            authenticatedPeers.removeAll()
            currentPairingSAS = nil
        }
        publishState()
    }

    public func stateSnapshot() -> SecurePeerHostState {
        lock.fireWithLock {
            SecurePeerHostState(
                isAdvertising: advertiser != nil,
                isPairingOpen: pairingPrivateKey != nil,
                pairingSAS: currentPairingSAS,
                connectedPeerNames: authenticatedPeers.keys
                    .map(\.displayName)
                    .sorted(),
                lastError: lastError
            )
        }
    }

    private func validateInvitation(
        peerID: MCPeerID,
        context: Data?
    ) throws {
        guard let context else {
            throw FIREBridgeError.pairingRejected("邀请没有认证信息。")
        }
        let invitation = try decoder.decode(PairingInvitationV1.self, from: context)
        let discoveryState = lock.fireWithLock {
            (currentHostNonce, pairingPrivateKey)
        }
        guard invitation.version == BridgeWire.protocolVersion,
              invitation.hostID == hostID,
              invitation.hostNonce == discoveryState.0,
              invitation.hostNonce.count >= 16,
              invitation.clientNonce.count >= 16 else {
            throw FIREBridgeError.pairingRejected("邀请已过期或目标设备不匹配。")
        }
        let duplicateClient = lock.fireWithLock {
            authenticatedPeers.values.contains {
                $0.clientID == invitation.clientID
            } || handshakes.contains {
                $0.key != peerID && $0.value.clientID == invitation.clientID
            }
        }
        guard !duplicateClient else {
            throw FIREBridgeError.pairingRejected("该 iPhone 已有连接正在认证。")
        }

        switch invitation.mode {
        case .initial:
            guard let privateKey = discoveryState.1,
                  let clientPublicKey = invitation.clientPublicKey,
                  invitation.clientProof == nil else {
                throw FIREBridgeError.pairingRejected("Mac 未开启首次配对。")
            }
            let hasAnotherInitial = lock.fireWithLock {
                handshakes.values.contains { $0.isInitial }
            }
            guard !hasAnotherInitial else {
                throw FIREBridgeError.pairingRejected("已有 iPhone 正在核对短码。")
            }
            let transcript = InitialPairingTranscriptV1(
                clientID: invitation.clientID,
                hostID: hostID,
                hostNonce: invitation.hostNonce,
                clientNonce: invitation.clientNonce,
                hostPublicKey: privateKey.publicKey.rawRepresentation,
                clientPublicKey: clientPublicKey
            )
            let sessionKey = try PairingAuthenticator.deriveInitialSessionKey(
                privateKey: privateKey,
                peerPublicKey: clientPublicKey,
                transcript: transcript
            )
            let sas = PairingAuthenticator.shortAuthenticationString(
                sessionKey: sessionKey,
                transcript: transcript
            )
            lock.fireWithLock {
                pairingPrivateKey = nil
                currentPairingSAS = sas
                handshakes[peerID] = .initialAwaitingConfirmation(
                    InitialHostHandshake(
                        clientID: invitation.clientID,
                        transcript: transcript,
                        sessionKey: sessionKey
                    )
                )
            }
        case .reconnect:
            guard invitation.clientPublicKey == nil,
                  let proof = invitation.clientProof,
                  let secret = try credentialStore.load(
                    peerID: invitation.clientID
                  ) else {
                throw FIREBridgeError.pairingRejected("找不到已配对凭据。")
            }
            let transcript = ReconnectTranscriptV1(
                clientID: invitation.clientID,
                hostID: hostID,
                hostNonce: invitation.hostNonce,
                clientNonce: invitation.clientNonce
            )
            guard PairingAuthenticator.constantTimeVerify(
                proof,
                expected: PairingAuthenticator.reconnectClientInvitationProof(
                    secret: secret,
                    transcript: transcript
                )
            ) else {
                throw FIREBridgeError.pairingRejected("iPhone 重连证明无效。")
            }
            lock.fireWithLock {
                handshakes[peerID] = .reconnectAwaitingConnection(
                    ReconnectHostHandshake(
                        clientID: invitation.clientID,
                        transcript: transcript,
                        secret: secret
                    )
                )
            }
        }
    }

    private func restartAdvertising(
        allowNewPairing: Bool,
        clearPairingSAS: Bool
    ) throws {
        let nonce = try PairingAuthenticator.randomSecret(byteCount: 24)
        let privateKey = allowNewPairing
            ? Curve25519.KeyAgreement.PrivateKey()
            : nil
        let replacement = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: PairingDiscoveryInfo.encode(
                hostID: hostID,
                nonce: nonce,
                pairingPublicKey: privateKey?.publicKey.rawRepresentation
            ),
            serviceType: BridgeWire.serviceType
        )
        replacement.delegate = self

        advertiser?.stopAdvertisingPeer()
        advertiser = replacement
        lock.fireWithLock {
            currentHostNonce = nonce
            pairingPrivateKey = privateKey
            if clearPairingSAS {
                currentPairingSAS = nil
            }
            lastError = nil
        }
        replacement.startAdvertisingPeer()
        publishState()
    }

    private func cancelPendingInitialPairing() {
        let peers = lock.fireWithLock {
            let peers = handshakes.compactMap { peer, handshake in
                handshake.isInitial ? peer : nil
            }
            for peer in peers {
                handshakes.removeValue(forKey: peer)
            }
            currentPairingSAS = nil
            return peers
        }
        peers.forEach(session.cancelConnectPeer)
    }

    private func beginHandshake(for peerID: MCPeerID) {
        do {
            guard let handshake = lock.fireWithLock({
                handshakes[peerID]
            }) else {
                throw FIREBridgeError.pairingRejected("没有待处理的认证会话。")
            }
            switch handshake {
            case .initialAwaitingConfirmation(let initial):
                try sendRaw(
                    BridgeEnvelopeV1(
                        type: .pairingChallenge,
                        payload: PairingChallengeV1(
                            transcript: initial.transcript
                        ),
                        encoder: encoder
                    ),
                    to: peerID
                )
            case .reconnectAwaitingConnection(let reconnect):
                let challenge = ReconnectChallengeV1(
                    transcript: reconnect.transcript,
                    hostProof: PairingAuthenticator.reconnectHostChallengeProof(
                        secret: reconnect.secret,
                        transcript: reconnect.transcript
                    )
                )
                lock.fireWithLock {
                    handshakes[peerID] = .reconnectAwaitingResponse(reconnect)
                }
                try sendRaw(
                    BridgeEnvelopeV1(
                        type: .reconnectChallenge,
                        payload: challenge,
                        encoder: encoder
                    ),
                    to: peerID
                )
            case .initialAwaitingReceipt, .reconnectAwaitingResponse:
                throw FIREBridgeError.pairingRejected("认证状态无效。")
            }
        } catch {
            reject(peerID, error: error)
        }
    }

    private func handleUnauthenticated(
        _ envelope: BridgeEnvelopeV1,
        from peerID: MCPeerID
    ) throws {
        guard BridgeSecurityPolicy.isHandshake(envelope.type),
              let handshake = lock.fireWithLock({
                  handshakes[peerID]
              }) else {
            throw FIREBridgeError.pairingRejected("未认证设备不能发送业务数据。")
        }
        switch (handshake, envelope.type) {
        case (.initialAwaitingConfirmation(let initial), .pairingConfirmation):
            let confirmation = try envelope.decodePayload(
                PairingConfirmationV1.self,
                decoder: decoder
            )
            guard confirmation.hostID == hostID,
                  confirmation.clientID == initial.clientID,
                  PairingAuthenticator.verifyInitialClientConfirmation(
                    confirmation.clientProof,
                    sessionKey: initial.sessionKey,
                    transcript: initial.transcript
                  ) else {
                throw FIREBridgeError.pairingRejected("iPhone 短码确认无效。")
            }
            let secret = try PairingAuthenticator.randomSecret()
            let provision = try PairingAuthenticator.sealCredential(
                secret,
                sessionKey: initial.sessionKey,
                transcript: initial.transcript
            )
            lock.fireWithLock {
                handshakes[peerID] = .initialAwaitingReceipt(
                    InitialHostCredential(
                        handshake: initial,
                        secret: secret
                    )
                )
            }
            try sendRaw(
                BridgeEnvelopeV1(
                    type: .credentialProvision,
                    payload: provision,
                    encoder: encoder
                ),
                to: peerID
            )
        case (.initialAwaitingReceipt(let credential), .credentialReceipt):
            let receipt = try envelope.decodePayload(
                PairingCredentialReceiptV1.self,
                decoder: decoder
            )
            let initial = credential.handshake
            guard receipt.hostID == hostID,
                  receipt.clientID == initial.clientID,
                  PairingAuthenticator.verifyInitialCredentialReceipt(
                    receipt.clientProof,
                    secret: credential.secret,
                    transcript: initial.transcript
                  ) else {
                throw FIREBridgeError.pairingRejected("iPhone 凭据回执无效。")
            }
            try credentialStore.save(
                secret: credential.secret,
                peerID: initial.clientID
            )
            authenticate(
                peerID: peerID,
                clientID: initial.clientID,
                secret: credential.secret,
                context: PairingAuthenticator.initialAuthenticationContext(
                    initial.transcript
                )
            )
        case (.reconnectAwaitingResponse(let reconnect), .reconnectResponse):
            let response = try envelope.decodePayload(
                ReconnectResponseV1.self,
                decoder: decoder
            )
            guard response.hostID == hostID,
                  response.clientID == reconnect.clientID,
                  PairingAuthenticator.constantTimeVerify(
                    response.clientProof,
                    expected: PairingAuthenticator.reconnectClientResponseProof(
                        secret: reconnect.secret,
                        transcript: reconnect.transcript
                    )
                  ) else {
                throw FIREBridgeError.pairingRejected("iPhone 重连响应无效。")
            }
            authenticate(
                peerID: peerID,
                clientID: reconnect.clientID,
                secret: reconnect.secret,
                context: PairingAuthenticator.reconnectAuthenticationContext(
                    reconnect.transcript
                )
            )
        default:
            throw FIREBridgeError.pairingRejected("认证消息顺序无效。")
        }
    }

    private func authenticate(
        peerID: MCPeerID,
        clientID: UUID,
        secret: Data,
        context: Data
    ) {
        do {
            let channel = SecureBridgeChannel(
                key: PairingAuthenticator.deriveChannelKey(
                    secret: secret,
                    context: context
                ),
                localID: hostID,
                remoteID: clientID
            )
            let completion = AuthenticationCompleteV1(
                hostID: hostID,
                clientID: clientID,
                hostProof: PairingAuthenticator.authenticationCompleteProof(
                    secret: secret,
                    context: context
                )
            )
            lock.fireWithLock {
                handshakes.removeValue(forKey: peerID)
                authenticatedPeers[peerID] = AuthenticatedHostPeer(
                    clientID: clientID,
                    channel: channel
                )
                currentPairingSAS = nil
            }
            try sendRaw(
                BridgeEnvelopeV1(
                    type: .authenticationComplete,
                    payload: completion,
                    encoder: encoder
                ),
                to: peerID
            )
            publishState()
        } catch {
            reject(peerID, error: error)
        }
    }

    private func handle(_ data: Data, from peerID: MCPeerID) {
        do {
            guard data.count <= BridgeWire.maximumMessageBytes else {
                throw FIREBridgeError.invalidMessage("消息超过 8 MB 上限。")
            }
            let outer = try decoder.decode(BridgeEnvelopeV1.self, from: data)
            guard outer.version == BridgeWire.protocolVersion else {
                throw FIREBridgeError.invalidMessage(
                    "不支持协议版本 \(outer.version)。"
                )
            }
            if let authenticated = lock.fireWithLock({
                authenticatedPeers[peerID]
            }) {
                let envelope = try authenticated.channel.open(outer)
                let handler = lock.fireWithLock { envelopeHandler }
                guard let handler else { return }
                Task { [weak self] in
                    guard let response = await handler(envelope) else { return }
                    do {
                        try self?.sendBusiness(response, to: peerID)
                    } catch {
                        self?.reject(peerID, error: error)
                    }
                }
            } else {
                try handleUnauthenticated(outer, from: peerID)
            }
        } catch {
            reject(peerID, error: error)
        }
    }

    private func sendBusiness(
        _ envelope: BridgeEnvelopeV1,
        to peerID: MCPeerID
    ) throws {
        let authenticated = lock.fireWithLock {
            authenticatedPeers[peerID]
        }
        guard let authenticated else {
            throw FIREBridgeError.pairingRejected("iPhone 尚未完成双向认证。")
        }
        try sendRaw(
            authenticated.channel.seal(envelope),
            to: peerID
        )
    }

    private func sendRaw(
        _ envelope: BridgeEnvelopeV1,
        to peerID: MCPeerID
    ) throws {
        guard BridgeSecurityPolicy.isHandshake(envelope.type)
                || envelope.type == .secureMessage else {
            throw FIREBridgeError.pairingRejected("业务消息必须使用安全通道。")
        }
        guard session.connectedPeers.contains(peerID) else {
            throw FIREBridgeError.appServerDisconnected("手机已断开。")
        }
        try session.send(
            encoder.encode(envelope),
            toPeers: [peerID],
            with: .reliable
        )
    }

    private func reject(_ peerID: MCPeerID, error: Error) {
        lock.fireWithLock {
            lastError = error.localizedDescription
            let removed = handshakes.removeValue(forKey: peerID)
            authenticatedPeers.removeValue(forKey: peerID)
            if removed?.isInitial == true {
                currentPairingSAS = nil
            }
        }
        session.cancelConnectPeer(peerID)
        publishState()
    }

    private func record(_ error: Error) {
        lock.fireWithLock { lastError = error.localizedDescription }
        publishState()
    }

    private func publishState() {
        let state = stateSnapshot()
        let handler = lock.fireWithLock { stateHandler }
        handler?(state)
    }
}

extension SecurePeerHost: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        do {
            try validateInvitation(peerID: peerID, context: context)
            invitationHandler(true, session)
            try restartAdvertising(
                allowNewPairing: false,
                clearPairingSAS: false
            )
        } catch {
            record(error)
            invitationHandler(false, nil)
        }
    }

    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        record(error)
    }
}

extension SecurePeerHost: MCSessionDelegate {
    public func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        if state == .connected {
            beginHandshake(for: peerID)
        } else if state == .notConnected {
            lock.fireWithLock {
                let removed = handshakes.removeValue(forKey: peerID)
                authenticatedPeers.removeValue(forKey: peerID)
                if removed?.isInitial == true {
                    currentPairingSAS = nil
                }
            }
        }
        publishState()
    }

    public func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        handle(data, from: peerID)
    }

    public func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        reject(
            peerID,
            error: FIREBridgeError.invalidMessage("不接受流式传输。")
        )
    }

    public func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        reject(
            peerID,
            error: FIREBridgeError.invalidMessage("不接受资源传输。")
        )
    }

    public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        if let error {
            reject(peerID, error: error)
        }
    }
}

private extension HostHandshake {
    var clientID: UUID {
        switch self {
        case .initialAwaitingConfirmation(let value):
            value.clientID
        case .initialAwaitingReceipt(let value):
            value.handshake.clientID
        case .reconnectAwaitingConnection(let value),
             .reconnectAwaitingResponse(let value):
            value.clientID
        }
    }

    var isInitial: Bool {
        switch self {
        case .initialAwaitingConfirmation, .initialAwaitingReceipt:
            true
        case .reconnectAwaitingConnection, .reconnectAwaitingResponse:
            false
        }
    }
}

private extension NSLock {
    func fireWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
