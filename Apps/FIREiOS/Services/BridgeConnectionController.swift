import CryptoKit
import FIREBridgeKit
import FIRECore
import Foundation
import Observation
import OSLog
@preconcurrency import MultipeerConnectivity
import UIKit

enum BridgeConnectionError: LocalizedError {
    case notConnected
    case authenticationRequired
    case featureUnavailable
    case invalidResponse
    case remote(BridgeErrorResponseV1)
    case timedOut
    case sendFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Mac 桥接程序尚未连接。"
        case .authenticationRequired: "请先完成双端短码核对。"
        case .featureUnavailable: "Mac 桥接版本较旧，暂不支持自动获取汇率。"
        case .invalidResponse: "Mac 返回了无法识别的响应。"
        case .remote(let error): error.message
        case .timedOut: "Mac 响应超时，请确认它仍在线且 Codex 可用。"
        case .sendFailed(let error): "发送失败：\(error.localizedDescription)"
        }
    }
}

enum BridgeCapabilityError: LocalizedError, Equatable {
    case durableAssetRecognitionRequiresUpdate

    var errorDescription: String? {
        switch self {
        case .durableAssetRecognitionRequiresUpdate:
            "Mac 桥接版本较旧，请更新后再识别资产。"
        }
    }
}

enum BridgeCapabilityPolicy {
    static func requireDurableAssetRecognition(
        _ capabilities: [String]?
    ) throws {
        guard capabilities?.contains(
            BridgeWire.durableAssetRecognitionCapability
        ) == true else {
            throw BridgeCapabilityError
                .durableAssetRecognitionRequiresUpdate
        }
    }
}

enum BridgeRequestTimeoutPolicy {
    static func seconds(for type: BridgeEnvelopeTypeV1) -> Double {
        switch type {
        case .generateReport, .followUp:
            600
        case .recognizeAssets:
            300
        case .fetchExchangeRates:
            20
        default:
            45
        }
    }
}

enum BridgeOperationRecoveryPolicy {
    static func isRecoverable(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let bridgeError = error as? BridgeConnectionError {
            switch bridgeError {
            case .notConnected, .authenticationRequired, .timedOut,
                 .sendFailed:
                return true
            case .remote(let response):
                return response.retryable
            case .featureUnavailable, .invalidResponse:
                return false
            }
        }
        if let tcpError = error as? TCPReconnectError {
            switch tcpError {
            case .stopped, .notAuthenticated, .requestTimedOut,
                 .handshakeTimedOut, .transportUnavailable, .sendFailed:
                return true
            case .invalidRequest, .duplicateRequest, .authenticationFailed,
                 .invalidProtocol:
                return false
            }
        }
        return false
    }
}

struct DiscoveredBridgeDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
}

private struct DiscoveredBridgePeer {
    let peerID: MCPeerID
    let hostID: UUID
    let hostNonce: Data
    let pairingPublicKey: Data?
}

enum BridgePeerReplacementPolicy {
    static func shouldReplace(
        existing: MCPeerID,
        incoming: MCPeerID,
        hasActiveConnectionAttempt: Bool
    ) -> Bool {
        existing != incoming && !hasActiveConnectionAttempt
    }
}

enum BridgeTransportSelectionPolicy {
    static func shouldAttemptMultipeerConnection(
        isUserInitiated: Bool,
        tcpIsAuthenticated: Bool,
        tcpIsConnecting: Bool
    ) -> Bool {
        isUserInitiated && !tcpIsAuthenticated && !tcpIsConnecting
    }

    static func shouldRetireMultipeerConnection(
        tcpIsAuthenticated: Bool,
        hasAuthenticatedMultipeerConnection: Bool,
        pendingRequestCount: Int
    ) -> Bool {
        tcpIsAuthenticated
            && hasAuthenticatedMultipeerConnection
            && pendingRequestCount == 0
    }
}

enum BridgeConnectionIndicatorState: Equatable {
    case connected
    case connecting
    case disconnected

    static func resolve(
        isConnected: Bool,
        hasActiveConnectionAttempt: Bool
    ) -> BridgeConnectionIndicatorState {
        if isConnected {
            return .connected
        }
        if hasActiveConnectionAttempt {
            return .connecting
        }
        return .disconnected
    }
}

private struct InitialClientHandshake {
    let peerID: MCPeerID
    let peerName: String
    let transcript: InitialPairingTranscriptV1
    let sessionKey: SymmetricKey
}

private struct ReconnectClientHandshake {
    let peerID: MCPeerID
    let peerName: String
    let transcript: ReconnectTranscriptV1
    let secret: Data
}

private enum ClientHandshake {
    case initialAwaitingChallenge(InitialClientHandshake)
    case initialAwaitingConfirmation(InitialClientHandshake)
    case initialAwaitingProvision(InitialClientHandshake)
    case initialAwaitingCompletion(InitialClientHandshake, secret: Data)
    case reconnectAwaitingChallenge(ReconnectClientHandshake)
    case reconnectAwaitingCompletion(ReconnectClientHandshake)

    var peerID: MCPeerID {
        switch self {
        case .initialAwaitingChallenge(let value),
             .initialAwaitingConfirmation(let value),
             .initialAwaitingProvision(let value),
             .initialAwaitingCompletion(let value, _):
            value.peerID
        case .reconnectAwaitingChallenge(let value),
             .reconnectAwaitingCompletion(let value):
            value.peerID
        }
    }

    var debugStage: String {
        switch self {
        case .initialAwaitingChallenge:
            "initialAwaitingChallenge"
        case .initialAwaitingConfirmation:
            "initialAwaitingConfirmation"
        case .initialAwaitingProvision:
            "initialAwaitingProvision"
        case .initialAwaitingCompletion:
            "initialAwaitingCompletion"
        case .reconnectAwaitingChallenge:
            "reconnectAwaitingChallenge"
        case .reconnectAwaitingCompletion:
            "reconnectAwaitingCompletion"
        }
    }
}

@MainActor
@Observable
final class BridgeConnectionController: NSObject {
    private let credentialStore: PairingCredentialStore
    private let clientID: UUID
    private let localPeer: MCPeerID
    @ObservationIgnored
    private let tcpClient: SecureTCPReconnectClient
    @ObservationIgnored private lazy var session = MCSession(
        peer: localPeer,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    @ObservationIgnored private lazy var browser = MCNearbyServiceBrowser(
        peer: localPeer,
        serviceType: BridgeWire.serviceType
    )
    @ObservationIgnored
    private var pending: [UUID: CheckedContinuation<BridgeEnvelopeV1, Error>] = [:]
    @ObservationIgnored private var cancelledRequestIDs: Set<UUID> = []
    @ObservationIgnored
    private var discoveredPeersByHostID: [UUID: DiscoveredBridgePeer] = [:]
    @ObservationIgnored private var handshake: ClientHandshake?
    @ObservationIgnored private var authenticatedPeerID: MCPeerID?
    @ObservationIgnored private var authenticatedHostID: UUID?
    @ObservationIgnored private var secureChannel: SecureBridgeChannel?
    @ObservationIgnored private var isBrowsing = false
    @ObservationIgnored
    private var connectionAttemptTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var tcpIsAuthenticated = false
    @ObservationIgnored private var tcpIsConnecting = false
    @ObservationIgnored private var tcpPeerName: String?
    @ObservationIgnored private var tcpHostID: UUID?
    @ObservationIgnored private var needsTCPRestartAfterForeground = false

    var discoveredPeers: [DiscoveredBridgeDevice] = []
    var connectedPeerName: String?
    var connectionStatus = "未连接"
    var pairingSAS: String?
    var isAwaitingPairingConfirmation = false
    private(set) var advertisedCapabilities: Set<String> = []

    var indicatorState: BridgeConnectionIndicatorState {
        BridgeConnectionIndicatorState.resolve(
            isConnected: connectedPeerName != nil,
            hasActiveConnectionAttempt: handshake != nil
                || isAwaitingPairingConfirmation
                || tcpIsConnecting
        )
    }

    override init() {
        let store = PairingCredentialStore()
        credentialStore = store
        clientID = (try? store.stableIdentity()) ?? UUID()
        localPeer = MCPeerID(displayName: String(UIDevice.current.name.prefix(63)))
        tcpClient = SecureTCPReconnectClient(
            clientID: clientID,
            credentialStore: store
        )
        super.init()
        session.delegate = self
        browser.delegate = self
        tcpClient.setStateHandler { [weak self] state in
            Task { @MainActor in
                self?.handleTCPState(state)
            }
        }
    }

    func startBrowsing() {
        if needsTCPRestartAfterForeground {
            needsTCPRestartAfterForeground = false
            clearTCPConnectionState()
            tcpClient.restartAfterForeground()
        } else {
            tcpClient.start()
        }
        guard connectedPeerName == nil, !isBrowsing else { return }
        discoveredPeersByHostID.removeAll()
        refreshDiscoveredPeers()
        connectionStatus = "正在寻找 Mac…"
        browser.startBrowsingForPeers()
        isBrowsing = true
    }

    func didEnterBackground() {
        needsTCPRestartAfterForeground = true
        stopBrowsing()
    }

    func stopBrowsing() {
        guard isBrowsing else { return }
        browser.stopBrowsingForPeers()
        isBrowsing = false
    }

    func connect(to hostID: UUID) throws {
        guard authenticatedPeerID == nil,
              handshake == nil,
              BridgeTransportSelectionPolicy
                .shouldAttemptMultipeerConnection(
                    isUserInitiated: true,
                    tcpIsAuthenticated: tcpIsAuthenticated,
                    tcpIsConnecting: tcpIsConnecting
                ),
              let peer = discoveredPeersByHostID[hostID] else {
            throw BridgeConnectionError.notConnected
        }

        let clientNonce = try PairingAuthenticator.randomSecret(byteCount: 24)
        let credential = try credentialStore.load(peerID: peer.hostID)
        let invitation: PairingInvitationV1
        if let credential {
            let transcript = ReconnectTranscriptV1(
                clientID: clientID,
                hostID: peer.hostID,
                hostNonce: peer.hostNonce,
                clientNonce: clientNonce
            )
            invitation = PairingInvitationV1(
                mode: .reconnect,
                clientID: clientID,
                hostID: peer.hostID,
                hostNonce: peer.hostNonce,
                clientNonce: clientNonce,
                clientProof: PairingAuthenticator.reconnectClientInvitationProof(
                    secret: credential,
                    transcript: transcript
                )
            )
            handshake = .reconnectAwaitingChallenge(
                ReconnectClientHandshake(
                    peerID: peer.peerID,
                    peerName: peer.peerID.displayName,
                    transcript: transcript,
                    secret: credential
                )
            )
            connectionStatus = "正在安全重连…"
        } else {
            guard let hostPublicKey = peer.pairingPublicKey else {
                throw FIREBridgeError.pairingRejected(
                    "请先在 Mac 上点击“配对新 iPhone”。"
                )
            }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let clientPublicKey = privateKey.publicKey.rawRepresentation
            let transcript = InitialPairingTranscriptV1(
                clientID: clientID,
                hostID: peer.hostID,
                hostNonce: peer.hostNonce,
                clientNonce: clientNonce,
                hostPublicKey: hostPublicKey,
                clientPublicKey: clientPublicKey
            )
            let sessionKey = try PairingAuthenticator.deriveInitialSessionKey(
                privateKey: privateKey,
                peerPublicKey: hostPublicKey,
                transcript: transcript
            )
            invitation = PairingInvitationV1(
                mode: .initial,
                clientID: clientID,
                hostID: peer.hostID,
                hostNonce: peer.hostNonce,
                clientNonce: clientNonce,
                clientPublicKey: clientPublicKey
            )
            handshake = .initialAwaitingChallenge(
                InitialClientHandshake(
                    peerID: peer.peerID,
                    peerName: peer.peerID.displayName,
                    transcript: transcript,
                    sessionKey: sessionKey
                )
            )
            connectionStatus = "正在建立首次配对…"
        }

        do {
            debugLog(
                "invite peer=\(peer.peerID.displayName) "
                    + "stage=\(handshake?.debugStage ?? "none")"
            )
            browser.invitePeer(
                peer.peerID,
                to: session,
                withContext: try BridgeWire.makeEncoder().encode(invitation),
                timeout: 30
            )
            scheduleConnectionAttemptTimeout(for: peer.peerID)
        } catch {
            clearConnectionState()
            throw error
        }
    }

    func confirmPairingSAS() throws {
        guard case .initialAwaitingConfirmation(let initial) = handshake else {
            throw BridgeConnectionError.authenticationRequired
        }
        let confirmation = PairingConfirmationV1(
            hostID: initial.transcript.hostID,
            clientID: clientID,
            clientProof: PairingAuthenticator.initialClientConfirmationProof(
                sessionKey: initial.sessionKey,
                transcript: initial.transcript
            )
        )
        try sendRaw(
            BridgeEnvelopeV1(
                type: .pairingConfirmation,
                payload: confirmation,
                encoder: BridgeWire.makeEncoder()
            ),
            to: initial.peerID
        )
        handshake = .initialAwaitingProvision(initial)
        isAwaitingPairingConfirmation = false
        connectionStatus = "短码已确认，正在保存安全凭据…"
    }

    func rejectPairing() {
        disconnect()
        connectionStatus = "已取消配对，请确认两边短码后重试"
    }

    func disconnect() {
        tcpClient.stop()
        tcpIsAuthenticated = false
        tcpIsConnecting = false
        tcpPeerName = nil
        tcpHostID = nil
        session.disconnect()
        failPendingRequests(with: BridgeConnectionError.notConnected)
        clearConnectionState()
        connectionStatus = "未连接"
    }

    func refreshBrowsing() {
        guard connectedPeerName == nil else { return }
        tcpClient.stop()
        tcpClient.start()
        if let peerID = handshake?.peerID {
            session.cancelConnectPeer(peerID)
        }
        failPendingRequests(with: BridgeConnectionError.notConnected)
        clearConnectionState()
        restartBrowsingAfterConnectionLoss(
            status: "正在重新寻找 Mac…"
        )
    }

    func ping() async throws -> PongPayloadV1 {
        let envelope = try BridgeEnvelopeV1(
            type: .ping,
            payload: PingPayloadV1(),
            encoder: BridgeWire.makeEncoder()
        )
        let response = try await send(envelope)
        let pong = try decode(
            response,
            expected: .pong,
            as: PongPayloadV1.self
        )
        advertisedCapabilities = Set(pong.capabilities ?? [])
        return pong
    }

    func generateReport(
        reportID: UUID,
        packet: FIRECore.AnalysisPacketV1
    ) async throws -> ReportGeneratedResponseV1 {
        let envelope = try BridgeEnvelopeV1(
            type: .generateReport,
            payload: GenerateReportRequestV1(reportID: reportID, packet: packet),
            encoder: BridgeWire.makeEncoder()
        )
        let response = try await send(envelope)
        return try decode(
            response,
            expected: .reportGenerated,
            as: ReportGeneratedResponseV1.self
        )
    }

    func recognizeAssets(
        operationID: UUID,
        imageCount: Int,
        lines: [AssetOCRLineV1]
    ) async throws -> RecognizeAssetsResponseV1 {
        let status = try await ping()
        try BridgeCapabilityPolicy.requireDurableAssetRecognition(
            status.capabilities
        )
        let envelope = try BridgeEnvelopeV1(
            type: .recognizeAssets,
            payload: RecognizeAssetsRequestV1(
                operationID: operationID,
                imageCount: imageCount,
                lines: lines
            ),
            encoder: BridgeWire.makeEncoder()
        )
        let response = try await send(envelope)
        return try decode(
            response,
            expected: .assetsRecognized,
            as: RecognizeAssetsResponseV1.self
        )
    }

    func fetchExchangeRates(
        snapshotDate: Date,
        currencies: Set<String>
    ) async throws -> ExchangeRatesFetchedResponseV1 {
        let status = try await ping()
        guard status.capabilities?.contains(
            BridgeWire.exchangeRatesCapability
        ) == true else {
            throw BridgeConnectionError.featureUnavailable
        }
        let envelope = try BridgeEnvelopeV1(
            type: .fetchExchangeRates,
            payload: FetchExchangeRatesRequestV1(
                snapshotDate: snapshotDate,
                currencies: Array(currencies)
            ),
            encoder: BridgeWire.makeEncoder()
        )
        let response = try await send(envelope)
        return try decode(
            response,
            expected: .exchangeRatesFetched,
            as: ExchangeRatesFetchedResponseV1.self
        )
    }

    func followUp(
        operationID: UUID,
        reportID: UUID,
        question: String
    ) async throws -> AnswerGeneratedResponseV1 {
        guard (1...BridgeWire.maximumQuestionCharacters).contains(question.count) else {
            throw FIREBridgeError.invalidMessage("追问长度必须为 1–4000 字。")
        }
        let envelope = try BridgeEnvelopeV1(
            type: .followUp,
            payload: FollowUpRequestV1(
                operationID: operationID,
                reportID: reportID,
                question: question
            ),
            encoder: BridgeWire.makeEncoder()
        )
        let response = try await send(envelope)
        return try decode(
            response,
            expected: .answerGenerated,
            as: AnswerGeneratedResponseV1.self
        )
    }

    func deleteReport(reportID: UUID) async throws {
        let envelope = try BridgeEnvelopeV1(
            type: .deleteReport,
            payload: DeleteReportRequestV1(reportID: reportID),
            encoder: BridgeWire.makeEncoder()
        )
        do {
            let response = try await send(envelope)
            _ = try decode(
                response,
                expected: .reportDeleted,
                as: ReportDeletedResponseV1.self
            )
        } catch BridgeConnectionError.remote(let error)
            where error.code == "thread_not_found" {
            return
        }
    }

    private func send(_ envelope: BridgeEnvelopeV1) async throws -> BridgeEnvelopeV1 {
        try Task.checkCancellation()
        let timeoutSeconds = BridgeRequestTimeoutPolicy.seconds(
            for: envelope.type
        )

        if tcpIsAuthenticated {
            return try await tcpClient.request(
                envelope,
                timeout: timeoutSeconds
            )
        }

        guard let peerID = authenticatedPeerID,
              let secureChannel else {
            throw BridgeConnectionError.notConnected
        }
        guard session.connectedPeers.contains(peerID) else {
            let failure = BridgeConnectionError.notConnected
            recoverFromTransportFailure(failure)
            throw failure
        }
        let protectedEnvelope = try secureChannel.seal(envelope)
        let data = try BridgeWire.makeEncoder().encode(protectedEnvelope)
        guard data.count <= BridgeWire.maximumMessageBytes else {
            throw FIREBridgeError.invalidMessage("消息超过 8 MB 上限。")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledRequestIDs.remove(envelope.id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[envelope.id] = continuation
                do {
                    try session.send(data, toPeers: [peerID], with: .reliable)
                } catch {
                    pending.removeValue(forKey: envelope.id)
                    let failure = BridgeConnectionError.sendFailed(error)
                    recoverFromTransportFailure(failure)
                    continuation.resume(
                        throwing: failure
                    )
                    return
                }

                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard let self,
                          let continuation = self.pending.removeValue(
                              forKey: envelope.id
                          ) else {
                        return
                    }
                    continuation.resume(
                        throwing: BridgeConnectionError.timedOut
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id: envelope.id)
            }
        }
    }

    private func cancelPendingRequest(id: UUID) {
        guard let continuation = pending.removeValue(forKey: id) else {
            cancelledRequestIDs.insert(id)
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    private func decode<Value: Decodable>(
        _ envelope: BridgeEnvelopeV1,
        expected: BridgeEnvelopeTypeV1,
        as type: Value.Type
    ) throws -> Value {
        guard envelope.type == expected else {
            try throwRemoteErrorIfPresent(envelope)
            throw BridgeConnectionError.invalidResponse
        }
        return try envelope.decodePayload(
            type,
            decoder: BridgeWire.makeDecoder()
        )
    }

    private func throwRemoteErrorIfPresent(_ envelope: BridgeEnvelopeV1) throws {
        if envelope.type == .error,
           let value = try? envelope.decodePayload(
               BridgeErrorResponseV1.self,
               decoder: BridgeWire.makeDecoder()
           ) {
            throw BridgeConnectionError.remote(value)
        }
    }

    private func receive(_ data: Data, from peerID: MCPeerID) {
        do {
            guard data.count <= BridgeWire.maximumMessageBytes else {
                throw FIREBridgeError.invalidMessage("消息超过 8 MB 上限。")
            }
            let outer = try BridgeWire.makeDecoder().decode(
                BridgeEnvelopeV1.self,
                from: data
            )
            debugLog(
                "receive type=\(outer.type.rawValue) "
                    + "peer=\(peerID.displayName) "
                    + "stage=\(handshake?.debugStage ?? "none")"
            )
            if peerID == authenticatedPeerID {
                guard let secureChannel else {
                    throw BridgeConnectionError.authenticationRequired
                }
                let envelope = try secureChannel.open(outer)
                guard let continuation = pending.removeValue(
                    forKey: envelope.id
                ) else {
                    return
                }
                retireMultipeerIfTCPPreferred()
                continuation.resume(returning: envelope)
            } else {
                try receiveHandshake(outer, from: peerID)
            }
        } catch {
            debugLog(
                "receive failed peer=\(peerID.displayName) "
                    + "stage=\(handshake?.debugStage ?? "none") "
                    + "error=\(error.localizedDescription)"
            )
            connectionStatus = "安全连接失败：\(error.localizedDescription)"
            session.cancelConnectPeer(peerID)
            if handshake?.peerID == peerID {
                handshake = nil
                pairingSAS = nil
                isAwaitingPairingConfirmation = false
            }
        }
    }

    private func receiveHandshake(
        _ envelope: BridgeEnvelopeV1,
        from peerID: MCPeerID
    ) throws {
        guard BridgeSecurityPolicy.isHandshake(envelope.type),
              handshake?.peerID == peerID else {
            throw FIREBridgeError.pairingRejected("未认证设备不能发送业务数据。")
        }
        switch (handshake, envelope.type) {
        case (.initialAwaitingChallenge(let initial), .pairingChallenge):
            let challenge = try envelope.decodePayload(
                PairingChallengeV1.self,
                decoder: BridgeWire.makeDecoder()
            )
            guard challenge.transcript == initial.transcript else {
                throw FIREBridgeError.pairingRejected("Mac 配对参数与发现信息不一致。")
            }
            pairingSAS = PairingAuthenticator.shortAuthenticationString(
                sessionKey: initial.sessionKey,
                transcript: initial.transcript
            )
            isAwaitingPairingConfirmation = true
            handshake = .initialAwaitingConfirmation(initial)
            connectionStatus = "请核对两边显示的短码"
        case (.initialAwaitingProvision(let initial), .credentialProvision):
            let provision = try envelope.decodePayload(
                PairingCredentialProvisionV1.self,
                decoder: BridgeWire.makeDecoder()
            )
            let secret = try PairingAuthenticator.openCredential(
                provision,
                sessionKey: initial.sessionKey,
                transcript: initial.transcript
            )
            guard secret.count >= 32 else {
                throw FIREBridgeError.pairingRejected("Mac 下发的配对凭据无效。")
            }
            try credentialStore.save(
                secret: secret,
                peerID: initial.transcript.hostID
            )
            let receipt = PairingCredentialReceiptV1(
                hostID: initial.transcript.hostID,
                clientID: clientID,
                clientProof: PairingAuthenticator.initialCredentialReceiptProof(
                    secret: secret,
                    transcript: initial.transcript
                )
            )
            do {
                try sendRaw(
                    BridgeEnvelopeV1(
                        type: .credentialReceipt,
                        payload: receipt,
                        encoder: BridgeWire.makeEncoder()
                    ),
                    to: peerID
                )
            } catch {
                try? credentialStore.delete(
                    peerID: initial.transcript.hostID
                )
                throw error
            }
            handshake = .initialAwaitingCompletion(initial, secret: secret)
            connectionStatus = "正在完成双向认证…"
        case (
            .initialAwaitingCompletion(let initial, let secret),
            .authenticationComplete
        ):
            let context = PairingAuthenticator.initialAuthenticationContext(
                initial.transcript
            )
            try completeAuthentication(
                envelope,
                peerID: peerID,
                peerName: initial.peerName,
                hostID: initial.transcript.hostID,
                secret: secret,
                context: context
            )
        case (.reconnectAwaitingChallenge(let reconnect), .reconnectChallenge):
            let challenge = try envelope.decodePayload(
                ReconnectChallengeV1.self,
                decoder: BridgeWire.makeDecoder()
            )
            guard challenge.transcript == reconnect.transcript,
                  PairingAuthenticator.constantTimeVerify(
                      challenge.hostProof,
                      expected: PairingAuthenticator.reconnectHostChallengeProof(
                          secret: reconnect.secret,
                          transcript: reconnect.transcript
                      )
                  ) else {
                throw FIREBridgeError.pairingRejected("Mac 身份证明无效。")
            }
            let response = ReconnectResponseV1(
                hostID: reconnect.transcript.hostID,
                clientID: clientID,
                clientProof: PairingAuthenticator.reconnectClientResponseProof(
                    secret: reconnect.secret,
                    transcript: reconnect.transcript
                )
            )
            try sendRaw(
                BridgeEnvelopeV1(
                    type: .reconnectResponse,
                    payload: response,
                    encoder: BridgeWire.makeEncoder()
                ),
                to: peerID
            )
            handshake = .reconnectAwaitingCompletion(reconnect)
            connectionStatus = "Mac 身份已验证，正在完成连接…"
        case (
            .reconnectAwaitingCompletion(let reconnect),
            .authenticationComplete
        ):
            try completeAuthentication(
                envelope,
                peerID: peerID,
                peerName: reconnect.peerName,
                hostID: reconnect.transcript.hostID,
                secret: reconnect.secret,
                context: PairingAuthenticator.reconnectAuthenticationContext(
                    reconnect.transcript
                )
            )
        default:
            throw FIREBridgeError.pairingRejected("认证消息顺序无效。")
        }
    }

    private func completeAuthentication(
        _ envelope: BridgeEnvelopeV1,
        peerID: MCPeerID,
        peerName: String,
        hostID: UUID,
        secret: Data,
        context: Data
    ) throws {
        let completion = try envelope.decodePayload(
            AuthenticationCompleteV1.self,
            decoder: BridgeWire.makeDecoder()
        )
        guard completion.hostID == hostID,
              completion.clientID == clientID,
              PairingAuthenticator.verifyAuthenticationComplete(
                  completion.hostProof,
                  secret: secret,
                  context: context
              ) else {
            throw FIREBridgeError.pairingRejected("Mac 最终认证证明无效。")
        }
        secureChannel = SecureBridgeChannel(
            key: PairingAuthenticator.deriveChannelKey(
                secret: secret,
                context: context
            ),
            localID: clientID,
            remoteID: hostID
        )
        authenticatedPeerID = peerID
        authenticatedHostID = hostID
        connectedPeerName = peerName
        cancelConnectionAttemptTimeout()
        handshake = nil
        pairingSAS = nil
        isAwaitingPairingConfirmation = false
        stopBrowsing()
        connectionStatus = "已安全连接 \(peerName)"
        debugLog("authentication complete peer=\(peerName)")
    }

    private func sendRaw(
        _ envelope: BridgeEnvelopeV1,
        to peerID: MCPeerID
    ) throws {
        guard BridgeSecurityPolicy.isHandshake(envelope.type),
              session.connectedPeers.contains(peerID) else {
            throw BridgeConnectionError.authenticationRequired
        }
        try session.send(
            BridgeWire.makeEncoder().encode(envelope),
            toPeers: [peerID],
            with: .reliable
        )
    }

    private func setConnectionState(_ state: MCSessionState, peer: MCPeerID) {
        debugLog(
            "session state=\(state.rawValue) "
                + "peer=\(peer.displayName) "
                + "stage=\(handshake?.debugStage ?? "none")"
        )
        switch state {
        case .connected:
            guard handshake?.peerID == peer else {
                session.cancelConnectPeer(peer)
                return
            }
            connectionStatus = "正在验证 \(peer.displayName)…"
        case .connecting:
            if handshake?.peerID == peer {
                connectionStatus = "正在连接 \(peer.displayName)…"
            }
        case .notConnected:
            let lostAuthenticatedConnection = peer == authenticatedPeerID
            let lostConnectionAttempt = handshake?.peerID == peer
            if lostAuthenticatedConnection || lostConnectionAttempt {
                failPendingRequests(with: BridgeConnectionError.notConnected)
                clearConnectionState()
                if !tcpIsAuthenticated {
                    restartBrowsingAfterConnectionLoss()
                }
            }
        @unknown default:
            connectionStatus = "连接状态未知"
        }
    }

    private func clearConnectionState() {
        cancelConnectionAttemptTimeout()
        handshake = nil
        authenticatedPeerID = nil
        authenticatedHostID = nil
        secureChannel = nil
        connectedPeerName = tcpIsAuthenticated ? tcpPeerName : nil
        pairingSAS = nil
        isAwaitingPairingConfirmation = false
        advertisedCapabilities.removeAll()
    }

    private func handleTCPState(_ state: TCPReconnectClientState) {
        debugLog(
            "TCP state=\(String(describing: state.status)) "
                + "message=\(state.message)"
        )
        switch state.status {
        case .authenticated:
            tcpIsAuthenticated = true
            tcpIsConnecting = false
            tcpPeerName = state.peerName ?? "Mac"
            tcpHostID = state.hostID
            connectedPeerName = tcpPeerName
            connectionStatus = state.message
            cancelConnectionAttemptTimeout()
            cancelMultipeerHandshakeForTCP()
            retireMultipeerIfTCPPreferred()
            stopBrowsing()
            debugLog("TCP authentication complete peer=\(tcpPeerName ?? "Mac")")
        case .connecting:
            clearTCPConnectionState()
            tcpIsConnecting = true
            cancelMultipeerHandshakeForTCP()
            if authenticatedPeerID == nil {
                connectionStatus = state.message
            }
        case .browsing:
            clearTCPConnectionState()
            if authenticatedPeerID == nil {
                connectionStatus = state.message
            }
        case .failed:
            let lostTCPConnection = tcpIsAuthenticated
            clearTCPConnectionState()
            if authenticatedPeerID == nil {
                connectionStatus = state.message
                if lostTCPConnection {
                    startBrowsing()
                }
            }
        case .stopped:
            clearTCPConnectionState()
        }
    }

    private func clearTCPConnectionState() {
        tcpIsAuthenticated = false
        tcpIsConnecting = false
        tcpPeerName = nil
        tcpHostID = nil
        if authenticatedPeerID == nil {
            connectedPeerName = nil
            advertisedCapabilities.removeAll()
        }
    }

    private func cancelMultipeerHandshakeForTCP() {
        guard authenticatedPeerID == nil,
              let peerID = handshake?.peerID else {
            return
        }
        cancelConnectionAttemptTimeout()
        handshake = nil
        pairingSAS = nil
        isAwaitingPairingConfirmation = false
        session.cancelConnectPeer(peerID)
    }

    private func retireMultipeerIfTCPPreferred() {
        guard BridgeTransportSelectionPolicy
            .shouldRetireMultipeerConnection(
                tcpIsAuthenticated: tcpIsAuthenticated,
                hasAuthenticatedMultipeerConnection:
                    authenticatedPeerID != nil,
                pendingRequestCount: pending.count
            ) else {
            return
        }
        session.disconnect()
        clearConnectionState()
    }

    private func failPendingRequests(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func recoverFromTransportFailure(_ error: Error) {
        session.disconnect()
        failPendingRequests(with: error)
        clearConnectionState()
        restartBrowsingAfterConnectionLoss()
    }

    private func restartBrowsingAfterConnectionLoss(
        status: String = "连接中断，正在自动重连…"
    ) {
        stopBrowsing()
        discoveredPeersByHostID.removeAll()
        refreshDiscoveredPeers()
        startBrowsing()
        connectionStatus = status
    }

    private func scheduleConnectionAttemptTimeout(for peerID: MCPeerID) {
        cancelConnectionAttemptTimeout()
        connectionAttemptTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled,
                  let self,
                  self.authenticatedPeerID == nil,
                  self.handshake?.peerID == peerID else {
                return
            }
            self.debugLog(
                "connection timeout peer=\(peerID.displayName) "
                    + "stage=\(self.handshake?.debugStage ?? "none")"
            )
            self.session.cancelConnectPeer(peerID)
            self.failPendingRequests(with: BridgeConnectionError.timedOut)
            self.clearConnectionState()
            self.restartBrowsingAfterConnectionLoss(
                status: "连接超时，正在自动重试…"
            )
        }
    }

    private func cancelConnectionAttemptTimeout() {
        connectionAttemptTimeoutTask?.cancel()
        connectionAttemptTimeoutTask = nil
    }

    private func refreshDiscoveredPeers() {
        discoveredPeers = discoveredPeersByHostID.values
            .map {
                DiscoveredBridgeDevice(
                    id: $0.hostID,
                    name: $0.peerID.displayName
                )
            }
            .sorted {
                if $0.name == $1.name {
                    $0.id.uuidString < $1.id.uuidString
                } else {
                    $0.name < $1.name
                }
            }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        Logger(subsystem: "com.local.firefreedom", category: "BridgeConnection")
            .debug("\(message, privacy: .private)")
        #endif
    }
}

extension BridgeConnectionController: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        guard let info,
              let discovery = try? PairingDiscoveryInfo.decode(info) else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.isBrowsing else { return }
            if let existing = self.discoveredPeersByHostID[discovery.hostID],
               !BridgePeerReplacementPolicy.shouldReplace(
                existing: existing.peerID,
                incoming: peerID,
                hasActiveConnectionAttempt: self.authenticatedPeerID != nil
                    || self.handshake != nil
               ),
               existing.peerID != peerID {
                return
            }
            self.discoveredPeersByHostID[discovery.hostID] = DiscoveredBridgePeer(
                peerID: peerID,
                hostID: discovery.hostID,
                hostNonce: discovery.nonce,
                pairingPublicKey: discovery.pairingPublicKey
            )
            self.refreshDiscoveredPeers()
            // Paired devices reconnect automatically over TCP. Multipeer is
            // retained for first pairing and explicit fallback from Settings.
            if self.connectionStatus == "正在寻找 Mac…"
                || self.connectionStatus == "连接中断，正在自动重连…" {
                self.connectionStatus = "找到 \(self.discoveredPeers.count) 台 Mac"
            }
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let matchingHostIDs = self.discoveredPeersByHostID.compactMap {
                $0.value.peerID == peerID ? $0.key : nil
            }
            matchingHostIDs.forEach {
                self.discoveredPeersByHostID.removeValue(forKey: $0)
            }
            self.refreshDiscoveredPeers()
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.isBrowsing = false
            self?.connectionStatus = "无法搜索：\(error.localizedDescription)"
        }
    }
}

extension BridgeConnectionController: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        Task { @MainActor [weak self] in
            self?.setConnectionState(state, peer: peerID)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        Task { @MainActor [weak self] in
            self?.receive(data, from: peerID)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        session.cancelConnectPeer(peerID)
    }

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        session.cancelConnectPeer(peerID)
    }

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}

    #if os(iOS)
    nonisolated func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
    #endif
}
