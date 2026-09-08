import CryptoKit
import XCTest
@testable import FIREBridgeKit

final class CodexSecurityTests: XCTestCase {
    func testResolverFindsCodexOnPATH() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let resolver = CodexCLIResolver(
            environment: ["PATH": directory.path]
        )

        XCTAssertEqual(try resolver.resolve().standardizedFileURL, executable.standardizedFileURL)
    }

    func testEnvironmentRemovesAPIKeysWithoutTouchingOtherValues() {
        let environment = [
            "PATH": "/usr/bin",
            "OPENAI_API_KEY": "must-not-leak",
            "CODEX_API_KEY": "must-not-leak-either",
            "COMPANY_SESSION_JWT": "must-not-leak-too",
            "LANG": "zh_CN.UTF-8",
        ]

        let sanitized = CodexEnvironment.sanitized(environment)

        XCTAssertNil(sanitized["OPENAI_API_KEY"])
        XCTAssertNil(sanitized["CODEX_API_KEY"])
        XCTAssertNil(sanitized["COMPANY_SESSION_JWT"])
        XCTAssertEqual(sanitized["PATH"], "/usr/bin")
        XCTAssertEqual(sanitized["LANG"], "zh_CN.UTF-8")
    }

    func testAppServerLaunchIsStrictAndDisablesExternalTools() {
        let arguments = CodexEnvironment.appServerArguments

        XCTAssertTrue(arguments.contains("--strict-config"))
        XCTAssertTrue(arguments.contains("features.shell_tool=false"))
        XCTAssertTrue(arguments.contains("mcp_servers={}"))
        for feature in [
            "apps", "browser_use", "computer_use", "image_generation",
            "plugins", "remote_plugin", "skill_search", "multi_agent",
        ] {
            XCTAssertTrue(arguments.contains(feature), "missing \(feature)")
        }
    }

    func testOnlyExplicitChatGPTLoginIsAccepted() throws {
        XCTAssertNoThrow(
            try CodexAuthentication.validateLoginStatus(
                standardOutput: "Logged in using ChatGPT",
                standardError: "",
                terminationStatus: 0
            )
        )

        XCTAssertThrowsError(
            try CodexAuthentication.validateLoginStatus(
                standardOutput: "Logged in using API key",
                standardError: "",
                terminationStatus: 0
            )
        )
        XCTAssertThrowsError(
            try CodexAuthentication.validateLoginStatus(
                standardOutput: "",
                standardError: "Not logged in",
                terminationStatus: 1
            )
        )
    }

    func testRequestHardeningIsPresentAtThreadAndTurnLevel() {
        let start = CodexRequestBuilder.startThread(
            id: 7,
            cwd: URL(fileURLWithPath: "/private/tmp/fire-isolated")
        )
        XCTAssertEqual(start.method, "thread/start")
        XCTAssertEqual(start.params["approvalPolicy"], .string("never"))
        XCTAssertEqual(start.params["sandbox"], .string("read-only"))
        XCTAssertEqual(
            start.params["config"]?["features"]?["shell_tool"],
            .bool(false)
        )
        XCTAssertEqual(
            start.params["config"]?["mcp_servers"],
            .object([:])
        )
        let hiddenAnalysis = CodexRequestBuilder.startEphemeralThread(
            id: 8,
            cwd: URL(fileURLWithPath: "/private/tmp/fire-hidden-analysis"),
            purpose: .financialAnalysis
        )
        XCTAssertEqual(hiddenAnalysis.params["ephemeral"], .bool(true))
        XCTAssertEqual(
            hiddenAnalysis.params["developerInstructions"],
            .string(CodexRequestBuilder.developerInstructions)
        )

        let turn = CodexRequestBuilder.reportTurn(
            id: 9,
            threadID: "thread-1",
            packetJSON: "{}"
        )
        XCTAssertEqual(turn.params["approvalPolicy"], .string("never"))
        XCTAssertEqual(
            turn.params["sandboxPolicy"]?["type"],
            .string("readOnly")
        )
        XCTAssertEqual(
            turn.params["sandboxPolicy"]?["networkAccess"],
            .bool(false)
        )
        XCTAssertNotNil(turn.params["outputSchema"])
        let reportPrompt = turn.params["input"]?
            .arrayValue?
            .first?["text"]?
            .stringValue
        XCTAssertTrue(reportPrompt?.contains("coreConclusion 只写 1 句") == true)
        XCTAssertTrue(reportPrompt?.contains("各 0–1 条") == true)
        XCTAssertTrue(reportPrompt?.contains("1–2 条") == true)
        XCTAssertTrue(reportPrompt?.contains("正文总计不超过 350 字") == true)
        XCTAssertTrue(reportPrompt?.contains("不得为了凑数") == true)
        XCTAssertTrue(
            reportPrompt?.contains("选择 1–3 笔最能解释结余或支出结构") == true
        )
        XCTAssertTrue(
            reportPrompt?.contains("不低于 2,000 元且不低于本月生活支出 10%") == true
        )
        XCTAssertTrue(
            reportPrompt?.contains("evidence.transactionFingerprints") == true
        )
        XCTAssertTrue(
            reportPrompt?.contains("转账、投资买卖、贷款本金、重复流水") == true
        )
        XCTAssertTrue(
            CodexRequestBuilder.developerInstructions.contains(
                "不得编造日期、商户、分类或金额"
            )
        )
    }

    func testOutputSchemasMatchFIRECoreContracts() {
        let reportKeys = Set(
            AnalysisOutputSchema.reportV1["properties"]?
                .objectValue?
                .keys
                .map { $0 } ?? []
        )
        XCTAssertEqual(
            reportKeys,
            Set([
                "schemaVersion", "coreConclusion", "dataConfidence",
                "spendingFindings", "assetStructureRisks", "fireDrivers",
                "actions", "evidence", "limitations",
            ])
        )
        let reportProperties = AnalysisOutputSchema.reportV1["properties"]
        XCTAssertEqual(
            reportProperties?["evidence"]?["minItems"],
            .number(1)
        )
        XCTAssertEqual(
            reportProperties?["evidence"]?["maxItems"],
            .number(6)
        )
        XCTAssertEqual(
            reportProperties?["coreConclusion"]?["maxLength"],
            .number(60)
        )
        XCTAssertEqual(
            reportProperties?["limitations"]?["maxItems"],
            .number(1)
        )
        let confidenceProperties = reportProperties?["dataConfidence"]?["properties"]
        XCTAssertEqual(
            confidenceProperties?["evidenceRefs"]?["minItems"],
            .number(1)
        )
        let findingSchema = reportProperties?["spendingFindings"]
        let findingProperties = findingSchema?["items"]?["properties"]
        XCTAssertEqual(
            findingProperties?["evidenceRefs"]?["minItems"],
            .number(1)
        )
        XCTAssertEqual(findingSchema?["maxItems"], .number(3))
        XCTAssertEqual(
            reportProperties?["assetStructureRisks"]?["maxItems"],
            .number(1)
        )
        XCTAssertEqual(
            reportProperties?["actions"]?["minItems"],
            .number(1)
        )
        XCTAssertEqual(
            reportProperties?["actions"]?["maxItems"],
            .number(2)
        )
        let actionProperties = reportProperties?["actions"]?["items"]?["properties"]
        XCTAssertEqual(
            actionProperties?["evidenceRefs"]?["minItems"],
            .number(1)
        )

        let answerKeys = Set(
            AnalysisOutputSchema.answerV1["properties"]?
                .objectValue?
                .keys
                .map { $0 } ?? []
        )
        XCTAssertEqual(
            answerKeys,
            Set([
                "schemaVersion", "answer", "evidenceRefs", "limitations",
                "refusedInvestmentInstruction",
            ])
        )
    }

    func testInitialPairingDerivesSameSASAndVerifiesClientConfirmation() throws {
        let clientID = UUID()
        let hostID = UUID()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let hostKey = Curve25519.KeyAgreement.PrivateKey()
        let transcript = InitialPairingTranscriptV1(
            clientID: clientID,
            hostID: hostID,
            hostNonce: Data(repeating: 0x19, count: 24),
            clientNonce: Data(repeating: 0x20, count: 24),
            hostPublicKey: hostKey.publicKey.rawRepresentation,
            clientPublicKey: clientKey.publicKey.rawRepresentation
        )
        let hostSessionKey = try PairingAuthenticator.deriveInitialSessionKey(
            privateKey: hostKey,
            peerPublicKey: clientKey.publicKey.rawRepresentation,
            transcript: transcript
        )
        let clientSessionKey = try PairingAuthenticator.deriveInitialSessionKey(
            privateKey: clientKey,
            peerPublicKey: hostKey.publicKey.rawRepresentation,
            transcript: transcript
        )
        XCTAssertEqual(
            PairingAuthenticator.shortAuthenticationString(
                sessionKey: hostSessionKey,
                transcript: transcript
            ),
            PairingAuthenticator.shortAuthenticationString(
                sessionKey: clientSessionKey,
                transcript: transcript
            )
        )
        let sas = PairingAuthenticator.shortAuthenticationString(
            sessionKey: hostSessionKey,
            transcript: transcript
        )
        XCTAssertEqual(sas.count, 6)
        XCTAssertNotNil(Int(sas))
        let proof = PairingAuthenticator.initialClientConfirmationProof(
            sessionKey: clientSessionKey,
            transcript: transcript
        )
        XCTAssertTrue(
            PairingAuthenticator.verifyInitialClientConfirmation(
                proof,
                sessionKey: hostSessionKey,
                transcript: transcript
            )
        )

        let wrongNonceTranscript = InitialPairingTranscriptV1(
            clientID: clientID,
            hostID: hostID,
            hostNonce: Data(repeating: 0x21, count: 24),
            clientNonce: transcript.clientNonce,
            hostPublicKey: transcript.hostPublicKey,
            clientPublicKey: transcript.clientPublicKey
        )
        XCTAssertFalse(
            PairingAuthenticator.verifyInitialClientConfirmation(
                proof,
                sessionKey: hostSessionKey,
                transcript: wrongNonceTranscript
            )
        )
    }

    func testInitialInvitationContainsNoCodeProofOrLongTermSecret() throws {
        let invitation = PairingInvitationV1(
            mode: .initial,
            clientID: UUID(),
            hostID: UUID(),
            hostNonce: Data(repeating: 0x01, count: 24),
            clientNonce: Data(repeating: 0x02, count: 24),
            clientPublicKey: Data(repeating: 0x03, count: 32)
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(invitation)
            ) as? [String: Any]
        )

        XCTAssertNil(object["pairingCode"])
        XCTAssertNil(object["secret"])
        XCTAssertNil(object["credentialProof"])
        XCTAssertNil(object["clientProof"])
    }

    func testCredentialIsEncryptedAndHostProofBindsPeer() throws {
        let clientID = UUID()
        let hostID = UUID()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let hostKey = Curve25519.KeyAgreement.PrivateKey()
        let transcript = InitialPairingTranscriptV1(
            clientID: clientID,
            hostID: hostID,
            hostNonce: Data(repeating: 0x10, count: 24),
            clientNonce: Data(repeating: 0x11, count: 24),
            hostPublicKey: hostKey.publicKey.rawRepresentation,
            clientPublicKey: clientKey.publicKey.rawRepresentation
        )
        let sessionKey = try PairingAuthenticator.deriveInitialSessionKey(
            privateKey: hostKey,
            peerPublicKey: clientKey.publicKey.rawRepresentation,
            transcript: transcript
        )
        let secret = Data(repeating: 0x42, count: 32)

        let provision = try PairingAuthenticator.sealCredential(
            secret,
            sessionKey: sessionKey,
            transcript: transcript
        )

        XCTAssertNil(provision.sealedCredential.range(of: secret))
        XCTAssertEqual(
            try PairingAuthenticator.openCredential(
                provision,
                sessionKey: sessionKey,
                transcript: transcript
            ),
            secret
        )
        let wrongPeerTranscript = InitialPairingTranscriptV1(
            clientID: UUID(),
            hostID: hostID,
            hostNonce: transcript.hostNonce,
            clientNonce: transcript.clientNonce,
            hostPublicKey: transcript.hostPublicKey,
            clientPublicKey: transcript.clientPublicKey
        )
        XCTAssertThrowsError(
            try PairingAuthenticator.openCredential(
                provision,
                sessionKey: sessionKey,
                transcript: wrongPeerTranscript
            )
        )
    }

    func testReconnectRequiresBothDirectionsAndBindsNoncesAndPeers() {
        let secret = Data(repeating: 0x71, count: 32)
        let transcript = ReconnectTranscriptV1(
            clientID: UUID(),
            hostID: UUID(),
            hostNonce: Data(repeating: 0x31, count: 24),
            clientNonce: Data(repeating: 0x32, count: 24)
        )
        let clientInvitation = PairingAuthenticator
            .reconnectClientInvitationProof(
                secret: secret,
                transcript: transcript
            )
        let hostChallenge = PairingAuthenticator.reconnectHostChallengeProof(
            secret: secret,
            transcript: transcript
        )
        let clientResponse = PairingAuthenticator.reconnectClientResponseProof(
            secret: secret,
            transcript: transcript
        )

        XCTAssertNotEqual(clientInvitation, hostChallenge)
        XCTAssertNotEqual(hostChallenge, clientResponse)
        XCTAssertTrue(
            PairingAuthenticator.constantTimeVerify(
                hostChallenge,
                expected: PairingAuthenticator.reconnectHostChallengeProof(
                    secret: secret,
                    transcript: transcript
                )
            )
        )
        let wrongNonce = ReconnectTranscriptV1(
            clientID: transcript.clientID,
            hostID: transcript.hostID,
            hostNonce: transcript.hostNonce,
            clientNonce: Data(repeating: 0x33, count: 24)
        )
        XCTAssertFalse(
            PairingAuthenticator.constantTimeVerify(
                hostChallenge,
                expected: PairingAuthenticator.reconnectHostChallengeProof(
                    secret: secret,
                    transcript: wrongNonce
                )
            )
        )
        let wrongPeer = ReconnectTranscriptV1(
            clientID: UUID(),
            hostID: transcript.hostID,
            hostNonce: transcript.hostNonce,
            clientNonce: transcript.clientNonce
        )
        XCTAssertFalse(
            PairingAuthenticator.constantTimeVerify(
                clientResponse,
                expected: PairingAuthenticator.reconnectClientResponseProof(
                    secret: secret,
                    transcript: wrongPeer
                )
            )
        )
    }

    func testUnauthenticatedStateCannotUseBusinessChannel() {
        XCTAssertThrowsError(
            try BridgeSecurityPolicy.requireBusinessAccess(
                phase: .unauthenticated
            )
        )
        XCTAssertThrowsError(
            try BridgeSecurityPolicy.requireBusinessAccess(
                phase: .authenticating
            )
        )
        XCTAssertNoThrow(
            try BridgeSecurityPolicy.requireBusinessAccess(
                phase: .authenticated
            )
        )
    }

    func testSecureBusinessChannelRejectsReplayAndWrongPeer() throws {
        let clientID = UUID()
        let hostID = UUID()
        let key = SymmetricKey(data: Data(repeating: 0xA5, count: 32))
        let client = SecureBridgeChannel(
            key: key,
            localID: clientID,
            remoteID: hostID
        )
        let host = SecureBridgeChannel(
            key: key,
            localID: hostID,
            remoteID: clientID
        )
        let inner = try BridgeEnvelopeV1(
            type: .ping,
            payload: PingPayloadV1(
                sentAt: Date(timeIntervalSince1970: 123)
            )
        )
        let protected = try client.seal(inner)

        XCTAssertEqual(try host.open(protected), inner)
        XCTAssertThrowsError(try host.open(protected))

        let freshClient = SecureBridgeChannel(
            key: key,
            localID: clientID,
            remoteID: hostID
        )
        let wrongHost = SecureBridgeChannel(
            key: key,
            localID: UUID(),
            remoteID: clientID
        )
        XCTAssertThrowsError(try wrongHost.open(freshClient.seal(inner)))
    }

    func testPairingDiscoveryRoundTrip() throws {
        let hostID = UUID()
        let nonce = Data(repeating: 0xAB, count: 24)
        let publicKey = Data(repeating: 0xCD, count: 32)

        let decoded = try PairingDiscoveryInfo.decode(
            PairingDiscoveryInfo.encode(
                hostID: hostID,
                nonce: nonce,
                pairingPublicKey: publicKey
            )
        )

        XCTAssertEqual(decoded.hostID, hostID)
        XCTAssertEqual(decoded.nonce, nonce)
        XCTAssertEqual(decoded.pairingPublicKey, publicKey)
    }

    func testWireEnvelopeRoundTrip() throws {
        let payload = PingPayloadV1(sentAt: Date(timeIntervalSince1970: 123))
        let envelope = try BridgeEnvelopeV1(type: .ping, payload: payload)
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(BridgeEnvelopeV1.self, from: encoded)

        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(try decoded.decodePayload(PingPayloadV1.self), payload)
        XCTAssertEqual(BridgeWire.serviceType, "fire-freedom")
    }

    func testDurableAssetRecognitionCapabilityRoundTripsInPong() throws {
        let expected = PongPayloadV1(
            sentAt: Date(timeIntervalSince1970: 123),
            codexReady: true,
            capabilities: [
                BridgeWire.durableAssetRecognitionCapability,
            ]
        )

        let data = try BridgeWire.makeEncoder().encode(expected)
        let decoded = try BridgeWire.makeDecoder().decode(
            PongPayloadV1.self,
            from: data
        )

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(
            BridgeWire.durableAssetRecognitionCapability,
            "asset-recognition-durable-v1"
        )
    }
}
