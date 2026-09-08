import CryptoKit
import Foundation
import Security

public enum PairingModeV1: String, Codable, Equatable, Sendable {
    case initial
    case reconnect
}

public struct PairingInvitationV1: Codable, Equatable, Sendable {
    public let version: String
    public let mode: PairingModeV1
    public let clientID: UUID
    public let hostID: UUID
    public let hostNonce: Data
    public let clientNonce: Data
    public let clientPublicKey: Data?
    public let clientProof: Data?

    public init(
        mode: PairingModeV1,
        clientID: UUID,
        hostID: UUID,
        hostNonce: Data,
        clientNonce: Data,
        clientPublicKey: Data? = nil,
        clientProof: Data? = nil,
        version: String = BridgeWire.protocolVersion
    ) {
        self.version = version
        self.mode = mode
        self.clientID = clientID
        self.hostID = hostID
        self.hostNonce = hostNonce
        self.clientNonce = clientNonce
        self.clientPublicKey = clientPublicKey
        self.clientProof = clientProof
    }
}

public struct InitialPairingTranscriptV1: Codable, Equatable, Sendable {
    public let version: String
    public let clientID: UUID
    public let hostID: UUID
    public let hostNonce: Data
    public let clientNonce: Data
    public let hostPublicKey: Data
    public let clientPublicKey: Data

    public init(
        clientID: UUID,
        hostID: UUID,
        hostNonce: Data,
        clientNonce: Data,
        hostPublicKey: Data,
        clientPublicKey: Data,
        version: String = BridgeWire.protocolVersion
    ) {
        self.version = version
        self.clientID = clientID
        self.hostID = hostID
        self.hostNonce = hostNonce
        self.clientNonce = clientNonce
        self.hostPublicKey = hostPublicKey
        self.clientPublicKey = clientPublicKey
    }

    fileprivate var authenticationData: Data {
        PairingAuthenticator.framed([
            Data("initial-pairing".utf8),
            Data(version.utf8),
            Data(BridgeWire.serviceType.utf8),
            Data(clientID.uuidString.lowercased().utf8),
            Data(hostID.uuidString.lowercased().utf8),
            hostNonce,
            clientNonce,
            hostPublicKey,
            clientPublicKey,
        ])
    }
}

public struct ReconnectTranscriptV1: Codable, Equatable, Sendable {
    public let version: String
    public let clientID: UUID
    public let hostID: UUID
    public let hostNonce: Data
    public let clientNonce: Data

    public init(
        clientID: UUID,
        hostID: UUID,
        hostNonce: Data,
        clientNonce: Data,
        version: String = BridgeWire.protocolVersion
    ) {
        self.version = version
        self.clientID = clientID
        self.hostID = hostID
        self.hostNonce = hostNonce
        self.clientNonce = clientNonce
    }

    fileprivate var authenticationData: Data {
        PairingAuthenticator.framed([
            Data("reconnect".utf8),
            Data(version.utf8),
            Data(BridgeWire.serviceType.utf8),
            Data(clientID.uuidString.lowercased().utf8),
            Data(hostID.uuidString.lowercased().utf8),
            hostNonce,
            clientNonce,
        ])
    }
}

public struct TCPReconnectHelloV1: Codable, Equatable, Sendable {
    public let version: String
    public let hostID: UUID
    public let hostNonce: Data

    public init(
        hostID: UUID,
        hostNonce: Data,
        version: String = BridgeWire.protocolVersion
    ) {
        self.version = version
        self.hostID = hostID
        self.hostNonce = hostNonce
    }
}

public struct TCPReconnectTranscriptV1: Codable, Equatable, Sendable {
    public let version: String
    public let clientID: UUID
    public let hostID: UUID
    public let hostNonce: Data
    public let clientNonce: Data

    public init(
        clientID: UUID,
        hostID: UUID,
        hostNonce: Data,
        clientNonce: Data,
        version: String = BridgeWire.protocolVersion
    ) {
        self.version = version
        self.clientID = clientID
        self.hostID = hostID
        self.hostNonce = hostNonce
        self.clientNonce = clientNonce
    }

    fileprivate var authenticationData: Data {
        PairingAuthenticator.framed([
            Data("tcp-reconnect".utf8),
            Data(version.utf8),
            Data(BridgeWire.transportDomain.utf8),
            Data(clientID.uuidString.lowercased().utf8),
            Data(hostID.uuidString.lowercased().utf8),
            hostNonce,
            clientNonce,
        ])
    }
}

public struct TCPReconnectInvitationV1: Codable, Equatable, Sendable {
    public let transcript: TCPReconnectTranscriptV1
    public let clientProof: Data

    public init(transcript: TCPReconnectTranscriptV1, clientProof: Data) {
        self.transcript = transcript
        self.clientProof = clientProof
    }
}

public struct TCPReconnectChallengeV1: Codable, Equatable, Sendable {
    public let transcript: TCPReconnectTranscriptV1
    public let hostProof: Data

    public init(transcript: TCPReconnectTranscriptV1, hostProof: Data) {
        self.transcript = transcript
        self.hostProof = hostProof
    }
}

public struct TCPReconnectResponseV1: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let clientID: UUID
    public let clientProof: Data

    public init(hostID: UUID, clientID: UUID, clientProof: Data) {
        self.hostID = hostID
        self.clientID = clientID
        self.clientProof = clientProof
    }
}

public struct PairingChallengeV1: Codable, Equatable, Sendable {
    public let transcript: InitialPairingTranscriptV1

    public init(transcript: InitialPairingTranscriptV1) {
        self.transcript = transcript
    }
}

public struct PairingConfirmationV1: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let clientID: UUID
    public let clientProof: Data

    public init(hostID: UUID, clientID: UUID, clientProof: Data) {
        self.hostID = hostID
        self.clientID = clientID
        self.clientProof = clientProof
    }
}

public struct PairingCredentialProvisionV1: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let clientID: UUID
    public let sealedCredential: Data
    public let hostProof: Data

    public init(
        hostID: UUID,
        clientID: UUID,
        sealedCredential: Data,
        hostProof: Data
    ) {
        self.hostID = hostID
        self.clientID = clientID
        self.sealedCredential = sealedCredential
        self.hostProof = hostProof
    }
}

public struct PairingCredentialReceiptV1: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let clientID: UUID
    public let clientProof: Data

    public init(hostID: UUID, clientID: UUID, clientProof: Data) {
        self.hostID = hostID
        self.clientID = clientID
        self.clientProof = clientProof
    }
}

public struct ReconnectChallengeV1: Codable, Equatable, Sendable {
    public let transcript: ReconnectTranscriptV1
    public let hostProof: Data

    public init(transcript: ReconnectTranscriptV1, hostProof: Data) {
        self.transcript = transcript
        self.hostProof = hostProof
    }
}

public struct ReconnectResponseV1: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let clientID: UUID
    public let clientProof: Data

    public init(hostID: UUID, clientID: UUID, clientProof: Data) {
        self.hostID = hostID
        self.clientID = clientID
        self.clientProof = clientProof
    }
}

public struct AuthenticationCompleteV1: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let clientID: UUID
    public let hostProof: Data

    public init(hostID: UUID, clientID: UUID, hostProof: Data) {
        self.hostID = hostID
        self.clientID = clientID
        self.hostProof = hostProof
    }
}

public struct SecureBridgePacketV1: Codable, Equatable, Sendable {
    public let senderID: UUID
    public let recipientID: UUID
    public let sequence: UInt64
    public let sealedEnvelope: Data

    public init(
        senderID: UUID,
        recipientID: UUID,
        sequence: UInt64,
        sealedEnvelope: Data
    ) {
        self.senderID = senderID
        self.recipientID = recipientID
        self.sequence = sequence
        self.sealedEnvelope = sealedEnvelope
    }
}

public enum PairingDiscoveryInfo {
    public static let versionKey = "v"
    public static let hostIDKey = "host"
    public static let nonceKey = "nonce"
    public static let publicKeyKey = "key"

    public static func encode(
        hostID: UUID,
        nonce: Data,
        pairingPublicKey: Data? = nil
    ) -> [String: String] {
        var info = [
            versionKey: BridgeWire.protocolVersion,
            hostIDKey: hostID.uuidString,
            nonceKey: nonce.base64EncodedString(),
        ]
        if let pairingPublicKey {
            info[publicKeyKey] = pairingPublicKey.base64EncodedString()
        }
        return info
    }

    public static func decode(
        _ discoveryInfo: [String: String]
    ) throws -> (hostID: UUID, nonce: Data, pairingPublicKey: Data?) {
        guard discoveryInfo[versionKey] == BridgeWire.protocolVersion,
              let hostString = discoveryInfo[hostIDKey],
              let hostID = UUID(uuidString: hostString),
              let nonceString = discoveryInfo[nonceKey],
              let nonce = Data(base64Encoded: nonceString),
              nonce.count >= 16 else {
            throw FIREBridgeError.pairingRejected("发现信息无效。")
        }
        let publicKey: Data?
        if let keyString = discoveryInfo[publicKeyKey] {
            guard let decoded = Data(base64Encoded: keyString),
                  decoded.count == 32 else {
                throw FIREBridgeError.pairingRejected("配对公钥无效。")
            }
            publicKey = decoded
        } else {
            publicKey = nil
        }
        return (hostID, nonce, publicKey)
    }
}

public enum TCPDiscoveryInfo {
    public static let versionKey = "v"
    public static let hostIDKey = "host"

    public static func encode(hostID: UUID) -> [String: String] {
        [
            versionKey: BridgeWire.protocolVersion,
            hostIDKey: hostID.uuidString,
        ]
    }

    public static func decode(_ discoveryInfo: [String: String]) throws -> UUID {
        guard Set(discoveryInfo.keys) == Set([versionKey, hostIDKey]),
              discoveryInfo[versionKey] == BridgeWire.protocolVersion,
              let hostString = discoveryInfo[hostIDKey],
              let hostID = UUID(uuidString: hostString) else {
            throw FIREBridgeError.pairingRejected("TCP 发现信息无效。")
        }
        return hostID
    }
}

public enum BridgeAuthenticationPhase: Equatable, Sendable {
    case unauthenticated
    case authenticating
    case authenticated
}

public enum BridgeSecurityPolicy {
    public static func requireBusinessAccess(
        phase: BridgeAuthenticationPhase
    ) throws {
        guard phase == .authenticated else {
            throw FIREBridgeError.pairingRejected("设备尚未完成双向认证。")
        }
    }

    public static func isHandshake(_ type: BridgeEnvelopeTypeV1) -> Bool {
        switch type {
        case .pairingChallenge, .pairingConfirmation, .credentialProvision,
             .credentialReceipt, .reconnectChallenge, .reconnectResponse,
             .authenticationComplete, .tcpReconnectHello,
             .tcpReconnectInvitation, .tcpReconnectChallenge,
             .tcpReconnectResponse, .tcpAuthenticationComplete:
            true
        default:
            false
        }
    }
}

public enum PairingAuthenticator {
    public static func deriveInitialSessionKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        transcript: InitialPairingTranscriptV1
    ) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerPublicKey
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
            with: publicKey
        )
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: transcript.authenticationData)),
            sharedInfo: Data("fire-initial-session-v1".utf8),
            outputByteCount: 32
        )
    }

    public static func shortAuthenticationString(
        sessionKey: SymmetricKey,
        transcript: InitialPairingTranscriptV1
    ) -> String {
        let code = authenticationCode(
            key: sessionKey,
            label: "sas",
            context: transcript.authenticationData
        )
        let value = code.prefix(4).reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        }
        return String(format: "%06d", value % 1_000_000)
    }

    public static func initialClientConfirmationProof(
        sessionKey: SymmetricKey,
        transcript: InitialPairingTranscriptV1
    ) -> Data {
        authenticationCode(
            key: sessionKey,
            label: "initial-client-confirm",
            context: transcript.authenticationData
        )
    }

    public static func verifyInitialClientConfirmation(
        _ proof: Data,
        sessionKey: SymmetricKey,
        transcript: InitialPairingTranscriptV1
    ) -> Bool {
        constantTimeEqual(
            proof,
            initialClientConfirmationProof(
                sessionKey: sessionKey,
                transcript: transcript
            )
        )
    }

    public static func sealCredential(
        _ secret: Data,
        sessionKey: SymmetricKey,
        transcript: InitialPairingTranscriptV1
    ) throws -> PairingCredentialProvisionV1 {
        let sealed = try AES.GCM.seal(
            secret,
            using: sessionKey,
            authenticating: credentialAssociatedData(transcript)
        )
        guard let combined = sealed.combined else {
            throw FIREBridgeError.pairingRejected("无法保护配对凭据。")
        }
        let proof = authenticationCode(
            key: sessionKey,
            label: "initial-host-provision",
            context: framed([transcript.authenticationData, combined])
        )
        return PairingCredentialProvisionV1(
            hostID: transcript.hostID,
            clientID: transcript.clientID,
            sealedCredential: combined,
            hostProof: proof
        )
    }

    public static func openCredential(
        _ provision: PairingCredentialProvisionV1,
        sessionKey: SymmetricKey,
        transcript: InitialPairingTranscriptV1
    ) throws -> Data {
        guard provision.hostID == transcript.hostID,
              provision.clientID == transcript.clientID,
              constantTimeEqual(
                provision.hostProof,
                authenticationCode(
                    key: sessionKey,
                    label: "initial-host-provision",
                    context: framed([
                        transcript.authenticationData,
                        provision.sealedCredential,
                    ])
                )
              ) else {
            throw FIREBridgeError.pairingRejected("Mac 配对凭据证明无效。")
        }
        let box = try AES.GCM.SealedBox(combined: provision.sealedCredential)
        return try AES.GCM.open(
            box,
            using: sessionKey,
            authenticating: credentialAssociatedData(transcript)
        )
    }

    public static func initialCredentialReceiptProof(
        secret: Data,
        transcript: InitialPairingTranscriptV1
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "initial-client-receipt",
            context: transcript.authenticationData
        )
    }

    public static func verifyInitialCredentialReceipt(
        _ proof: Data,
        secret: Data,
        transcript: InitialPairingTranscriptV1
    ) -> Bool {
        constantTimeEqual(
            proof,
            initialCredentialReceiptProof(secret: secret, transcript: transcript)
        )
    }

    public static func reconnectClientInvitationProof(
        secret: Data,
        transcript: ReconnectTranscriptV1
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "reconnect-client-invitation",
            context: transcript.authenticationData
        )
    }

    public static func reconnectHostChallengeProof(
        secret: Data,
        transcript: ReconnectTranscriptV1
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "reconnect-host-challenge",
            context: transcript.authenticationData
        )
    }

    public static func reconnectClientResponseProof(
        secret: Data,
        transcript: ReconnectTranscriptV1
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "reconnect-client-response",
            context: transcript.authenticationData
        )
    }

    public static func tcpClientInvitationProof(
        secret: Data,
        transcript: TCPReconnectTranscriptV1
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "tcp-reconnect-client-invitation",
            context: transcript.authenticationData
        )
    }

    public static func tcpHostChallengeProof(
        secret: Data,
        transcript: TCPReconnectTranscriptV1
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "tcp-reconnect-host-challenge",
            context: transcript.authenticationData
        )
    }

    public static func tcpClientResponseProof(
        secret: Data,
        transcript: TCPReconnectTranscriptV1
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "tcp-reconnect-client-response",
            context: transcript.authenticationData
        )
    }

    public static func tcpAuthenticationCompleteProof(
        secret: Data,
        transcript: TCPReconnectTranscriptV1
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "tcp-host-authentication-complete",
            context: tcpAuthenticationContext(transcript)
        )
    }

    public static func verifyTCPAuthenticationComplete(
        _ proof: Data,
        secret: Data,
        transcript: TCPReconnectTranscriptV1
    ) -> Bool {
        constantTimeEqual(
            proof,
            tcpAuthenticationCompleteProof(
                secret: secret,
                transcript: transcript
            )
        )
    }

    public static func authenticationCompleteProof(
        secret: Data,
        context: Data
    ) -> Data {
        authenticationCode(
            key: SymmetricKey(data: secret),
            label: "host-authentication-complete",
            context: context
        )
    }

    public static func verifyAuthenticationComplete(
        _ proof: Data,
        secret: Data,
        context: Data
    ) -> Bool {
        constantTimeEqual(
            proof,
            authenticationCompleteProof(secret: secret, context: context)
        )
    }

    public static func constantTimeVerify(
        _ proof: Data,
        expected: Data
    ) -> Bool {
        constantTimeEqual(proof, expected)
    }

    public static func deriveChannelKey(
        secret: Data,
        context: Data
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(SHA256.hash(data: context)),
            info: Data("fire-secure-channel-v1".utf8),
            outputByteCount: 32
        )
    }

    public static func initialAuthenticationContext(
        _ transcript: InitialPairingTranscriptV1
    ) -> Data {
        framed([Data("initial-authenticated".utf8), transcript.authenticationData])
    }

    public static func reconnectAuthenticationContext(
        _ transcript: ReconnectTranscriptV1
    ) -> Data {
        framed([Data("reconnect-authenticated".utf8), transcript.authenticationData])
    }

    public static func tcpAuthenticationContext(
        _ transcript: TCPReconnectTranscriptV1
    ) -> Data {
        framed([
            Data("tcp-reconnect-authenticated".utf8),
            Data(BridgeWire.transportDomain.utf8),
            transcript.authenticationData,
        ])
    }

    public static func randomSecret(byteCount: Int = 32) throws -> Data {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes {
            guard let baseAddress = $0.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        guard status == errSecSuccess else {
            throw FIREBridgeError.keychainFailure(status: status)
        }
        return data
    }

    fileprivate static func framed(_ parts: [Data]) -> Data {
        var result = Data()
        for part in parts {
            var length = UInt64(part.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(part)
        }
        return result
    }

    fileprivate static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func credentialAssociatedData(
        _ transcript: InitialPairingTranscriptV1
    ) -> Data {
        framed([
            Data("credential-provision".utf8),
            transcript.authenticationData,
        ])
    }

    private static func authenticationCode(
        key: SymmetricKey,
        label: String,
        context: Data
    ) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: framed([Data(label.utf8), context]),
                using: key
            )
        )
    }
}

public final class SecureBridgeChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let key: SymmetricKey
    public let localID: UUID
    public let remoteID: UUID
    private var nextSendSequence: UInt64 = 0
    private var nextReceiveSequence: UInt64 = 0

    public init(key: SymmetricKey, localID: UUID, remoteID: UUID) {
        self.key = key
        self.localID = localID
        self.remoteID = remoteID
    }

    public func seal(_ envelope: BridgeEnvelopeV1) throws -> BridgeEnvelopeV1 {
        guard !BridgeSecurityPolicy.isHandshake(envelope.type),
              envelope.type != .secureMessage else {
            throw FIREBridgeError.invalidMessage("握手消息不能放入业务通道。")
        }
        return try lock.withLock {
            let sequence = nextSendSequence
            let plaintext = try BridgeWire.makeEncoder().encode(envelope)
            let sealed = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: associatedData(
                    senderID: localID,
                    recipientID: remoteID,
                    sequence: sequence
                )
            )
            guard let combined = sealed.combined else {
                throw FIREBridgeError.invalidMessage("无法保护桥接消息。")
            }
            nextSendSequence += 1
            return try BridgeEnvelopeV1(
                type: .secureMessage,
                payload: SecureBridgePacketV1(
                    senderID: localID,
                    recipientID: remoteID,
                    sequence: sequence,
                    sealedEnvelope: combined
                )
            )
        }
    }

    public func open(_ envelope: BridgeEnvelopeV1) throws -> BridgeEnvelopeV1 {
        guard envelope.type == .secureMessage else {
            throw FIREBridgeError.pairingRejected("认证后只接受受保护的业务消息。")
        }
        let packet = try envelope.decodePayload(SecureBridgePacketV1.self)
        return try lock.withLock {
            guard packet.senderID == remoteID,
                  packet.recipientID == localID,
                  packet.sequence == nextReceiveSequence else {
                throw FIREBridgeError.pairingRejected("桥接消息来源或顺序无效。")
            }
            let box = try AES.GCM.SealedBox(combined: packet.sealedEnvelope)
            let plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: associatedData(
                    senderID: packet.senderID,
                    recipientID: packet.recipientID,
                    sequence: packet.sequence
                )
            )
            let inner = try BridgeWire.makeDecoder().decode(
                BridgeEnvelopeV1.self,
                from: plaintext
            )
            guard !BridgeSecurityPolicy.isHandshake(inner.type),
                  inner.type != .secureMessage else {
                throw FIREBridgeError.invalidMessage("受保护消息包含无效类型。")
            }
            nextReceiveSequence += 1
            return inner
        }
    }

    private func associatedData(
        senderID: UUID,
        recipientID: UUID,
        sequence: UInt64
    ) -> Data {
        PairingAuthenticator.framed([
            Data(BridgeWire.protocolVersion.utf8),
            Data("secure-envelope".utf8),
            Data(senderID.uuidString.lowercased().utf8),
            Data(recipientID.uuidString.lowercased().utf8),
            withUnsafeBytes(of: sequence.bigEndian) { Data($0) },
        ])
    }
}

public final class PairingCredentialStore: @unchecked Sendable {
    private let service: String

    public init(service: String = "com.openai.fire-freedom.pairing") {
        self.service = service
    }

    public func save(secret: Data, peerID: UUID) throws {
        let query = baseQuery(peerID: peerID)
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw FIREBridgeError.keychainFailure(status: updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw FIREBridgeError.keychainFailure(status: addStatus)
        }
    }

    public func load(peerID: UUID) throws -> Data? {
        var query = baseQuery(peerID: peerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FIREBridgeError.keychainFailure(status: status)
        }
        return data
    }

    public func delete(peerID: UUID) throws {
        let status = SecItemDelete(baseQuery(peerID: peerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FIREBridgeError.keychainFailure(status: status)
        }
    }

    public func stableIdentity() throws -> UUID {
        let identityKey = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        if let data = try load(peerID: identityKey),
           let string = String(data: data, encoding: .utf8),
           let identity = UUID(uuidString: string) {
            return identity
        }
        let identity = UUID()
        try save(secret: Data(identity.uuidString.utf8), peerID: identityKey)
        return identity
    }

    private func baseQuery(peerID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peerID.uuidString.lowercased(),
        ]
    }
}
