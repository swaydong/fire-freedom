import CryptoKit
import XCTest
@testable import FIREBridgeKit

final class TCPBridgeProtocolTests: XCTestCase {
    func testTCPRequestHonorsCancellationBeforeSending() async throws {
        let store = PairingCredentialStore(
            service: "com.openai.fire-freedom.test.cancel.\(UUID().uuidString)"
        )
        let client = SecureTCPReconnectClient(
            clientID: UUID(),
            credentialStore: store
        )
        let request = try BridgeEnvelopeV1(
            type: .ping,
            payload: PingPayloadV1()
        )
        let task = Task {
            try await client.request(request, timeout: 30)
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("已取消的请求不应继续等待桥接响应。")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testFrameDecoderAcceptsFragmentedFrame() throws {
        let payload = Data("fragmented payload".utf8)
        let framed = try TCPFrameDecoder.frame(payload)
        var decoder = TCPFrameDecoder()
        var decoded: [Data] = []

        for byte in framed {
            decoded.append(contentsOf: try decoder.append(Data([byte])))
        }

        XCTAssertEqual(decoded, [payload])
        XCTAssertNoThrow(try decoder.finish())
    }

    func testFrameDecoderSeparatesCoalescedFrames() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        var input = try TCPFrameDecoder.frame(first)
        input.append(try TCPFrameDecoder.frame(second))
        var decoder = TCPFrameDecoder()

        XCTAssertEqual(try decoder.append(input), [first, second])
        XCTAssertNoThrow(try decoder.finish())
    }

    func testFrameCodecRejectsZeroAndOversizedFrames() throws {
        var zeroDecoder = TCPFrameDecoder()
        XCTAssertThrowsError(
            try zeroDecoder.append(Data(repeating: 0, count: 4))
        )
        XCTAssertThrowsError(try TCPFrameDecoder.frame(Data()))

        var oversizedDecoder = TCPFrameDecoder(maximumFrameBytes: 3)
        XCTAssertThrowsError(
            try oversizedDecoder.append(Data([0, 0, 0, 4]))
        )
        XCTAssertThrowsError(
            try TCPFrameDecoder.frame(
                Data(repeating: 0xA5, count: BridgeWire.maximumMessageBytes + 1)
            )
        )
    }

    func testFrameDecoderRejectsTruncatedEOF() throws {
        var partialHeader = TCPFrameDecoder()
        _ = try partialHeader.append(Data([0, 0, 0]))
        XCTAssertThrowsError(try partialHeader.finish())

        var partialPayload = TCPFrameDecoder()
        _ = try partialPayload.append(Data([0, 0, 0, 3, 0x01, 0x02]))
        XCTAssertThrowsError(try partialPayload.finish())
    }

    func testTCPDiscoveryInfoIsStrict() throws {
        let hostID = UUID()
        let encoded = TCPDiscoveryInfo.encode(hostID: hostID)

        XCTAssertEqual(Set(encoded.keys), Set(["v", "host"]))
        XCTAssertEqual(try TCPDiscoveryInfo.decode(encoded), hostID)

        var extraField = encoded
        extraField["nonce"] = "not-advertised"
        XCTAssertThrowsError(try TCPDiscoveryInfo.decode(extraField))

        var wrongVersion = encoded
        wrongVersion["v"] = "2"
        XCTAssertThrowsError(try TCPDiscoveryInfo.decode(wrongVersion))
    }

    func testTCPProofsAreSeparatedFromMultipeerProofDomain() {
        let secret = Data(repeating: 0x42, count: 32)
        let clientID = UUID()
        let hostID = UUID()
        let hostNonce = Data(repeating: 0x11, count: 24)
        let clientNonce = Data(repeating: 0x22, count: 24)
        let multipeer = ReconnectTranscriptV1(
            clientID: clientID,
            hostID: hostID,
            hostNonce: hostNonce,
            clientNonce: clientNonce
        )
        let tcp = TCPReconnectTranscriptV1(
            clientID: clientID,
            hostID: hostID,
            hostNonce: hostNonce,
            clientNonce: clientNonce
        )

        XCTAssertNotEqual(
            PairingAuthenticator.reconnectClientInvitationProof(
                secret: secret,
                transcript: multipeer
            ),
            PairingAuthenticator.tcpClientInvitationProof(
                secret: secret,
                transcript: tcp
            )
        )
        XCTAssertNotEqual(
            PairingAuthenticator.reconnectHostChallengeProof(
                secret: secret,
                transcript: multipeer
            ),
            PairingAuthenticator.tcpHostChallengeProof(
                secret: secret,
                transcript: tcp
            )
        )
        XCTAssertNotEqual(
            PairingAuthenticator.reconnectClientResponseProof(
                secret: secret,
                transcript: multipeer
            ),
            PairingAuthenticator.tcpClientResponseProof(
                secret: secret,
                transcript: tcp
            )
        )

        let multipeerComplete = PairingAuthenticator.authenticationCompleteProof(
            secret: secret,
            context: PairingAuthenticator.reconnectAuthenticationContext(multipeer)
        )
        XCTAssertFalse(
            PairingAuthenticator.verifyTCPAuthenticationComplete(
                multipeerComplete,
                secret: secret,
                transcript: tcp
            )
        )
    }

    func testTCPNonceChangesChannelKeyAndRejectsPreviousCiphertext() throws {
        let secret = Data(repeating: 0x71, count: 32)
        let clientID = UUID()
        let hostID = UUID()
        let firstTranscript = TCPReconnectTranscriptV1(
            clientID: clientID,
            hostID: hostID,
            hostNonce: Data(repeating: 0x31, count: 24),
            clientNonce: Data(repeating: 0x32, count: 24)
        )
        let secondTranscript = TCPReconnectTranscriptV1(
            clientID: clientID,
            hostID: hostID,
            hostNonce: firstTranscript.hostNonce,
            clientNonce: Data(repeating: 0x33, count: 24)
        )
        let firstKey = PairingAuthenticator.deriveChannelKey(
            secret: secret,
            context: PairingAuthenticator.tcpAuthenticationContext(
                firstTranscript
            )
        )
        let secondKey = PairingAuthenticator.deriveChannelKey(
            secret: secret,
            context: PairingAuthenticator.tcpAuthenticationContext(
                secondTranscript
            )
        )

        XCTAssertNotEqual(keyData(firstKey), keyData(secondKey))

        let firstClient = SecureBridgeChannel(
            key: firstKey,
            localID: clientID,
            remoteID: hostID
        )
        let secondHost = SecureBridgeChannel(
            key: secondKey,
            localID: hostID,
            remoteID: clientID
        )
        let ping = try BridgeEnvelopeV1(
            type: .ping,
            payload: PingPayloadV1(
                sentAt: Date(timeIntervalSince1970: 123)
            )
        )

        XCTAssertThrowsError(try secondHost.open(firstClient.seal(ping)))
    }

    func testTCPEnvelopeTypesAreHandshakeOnly() {
        let types: [BridgeEnvelopeTypeV1] = [
            .tcpReconnectHello,
            .tcpReconnectInvitation,
            .tcpReconnectChallenge,
            .tcpReconnectResponse,
            .tcpAuthenticationComplete,
        ]

        XCTAssertTrue(types.allSatisfy(BridgeSecurityPolicy.isHandshake))
    }

    #if os(macOS)
    func testTCPHostAndClientCompleteSecurePing() async throws {
        let serviceSuffix = UUID().uuidString.lowercased()
        let hostStore = PairingCredentialStore(
            service: "com.openai.fire-freedom.test.host.\(serviceSuffix)"
        )
        let clientStore = PairingCredentialStore(
            service: "com.openai.fire-freedom.test.client.\(serviceSuffix)"
        )
        let hostID = try hostStore.stableIdentity()
        let clientID = try clientStore.stableIdentity()
        let identityKey = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let secret = try PairingAuthenticator.randomSecret()
        try hostStore.save(secret: secret, peerID: clientID)
        try clientStore.save(secret: secret, peerID: hostID)

        let host = try SecureTCPPeerHost(
            credentialStore: hostStore,
            displayName: "FIRE TCP Test"
        )
        let client = SecureTCPReconnectClient(
            clientID: clientID,
            credentialStore: clientStore,
            heartbeatInterval: 0.1
        )
        defer {
            client.stop()
            host.stop()
            try? hostStore.delete(peerID: clientID)
            try? clientStore.delete(peerID: hostID)
            try? hostStore.delete(peerID: identityKey)
            try? clientStore.delete(peerID: identityKey)
        }

        let heartbeatReceived = expectation(
            description: "authenticated TCP connection sends heartbeat"
        )
        heartbeatReceived.assertForOverFulfill = false
        host.setEnvelopeHandler { envelope in
            guard envelope.type == .ping else { return nil }
            heartbeatReceived.fulfill()
            return try? BridgeEnvelopeV1(
                id: envelope.id,
                type: .pong,
                payload: PongPayloadV1(codexReady: true)
            )
        }
        let authenticated = expectation(description: "TCP reconnect authenticated")
        client.setStateHandler { state in
            if state.isAuthenticated {
                authenticated.fulfill()
            }
        }

        try host.start()
        client.start()
        await fulfillment(of: [authenticated], timeout: 12)
        await fulfillment(of: [heartbeatReceived], timeout: 1)

        let request = try BridgeEnvelopeV1(
            type: .ping,
            payload: PingPayloadV1()
        )
        let response = try await client.request(request, timeout: 5)
        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.type, .pong)
        XCTAssertTrue(
            try response.decodePayload(PongPayloadV1.self).codexReady
        )

        let resumedBrowsing = expectation(
            description: "foreground restart returns to browsing"
        )
        let reauthenticated = expectation(
            description: "foreground restart reauthenticates"
        )
        let tracker = TCPReconnectStateTracker()
        client.setStateHandler { state in
            tracker.observe(
                state,
                browsing: resumedBrowsing,
                authenticated: reauthenticated
            )
        }
        client.restartAfterForeground()

        await fulfillment(
            of: [resumedBrowsing, reauthenticated],
            timeout: 12,
            enforceOrder: true
        )

        let resumedRequest = try BridgeEnvelopeV1(
            type: .ping,
            payload: PingPayloadV1()
        )
        let resumedResponse = try await client.request(
            resumedRequest,
            timeout: 5
        )
        XCTAssertEqual(resumedResponse.id, resumedRequest.id)
        XCTAssertEqual(resumedResponse.type, .pong)
    }
    #endif

    private func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

private final class TCPReconnectStateTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var sawBrowsing = false
    private var sawAuthentication = false

    func observe(
        _ state: TCPReconnectClientState,
        browsing: XCTestExpectation,
        authenticated: XCTestExpectation
    ) {
        lock.lock()
        defer { lock.unlock() }

        if state.status == .browsing, !sawBrowsing {
            sawBrowsing = true
            browsing.fulfill()
        } else if state.isAuthenticated,
                  sawBrowsing,
                  !sawAuthentication {
            sawAuthentication = true
            authenticated.fulfill()
        }
    }
}
