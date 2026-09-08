import FIREBridgeKit
import MultipeerConnectivity
import XCTest
@testable import FIRE

final class BridgeConnectionControllerTests: XCTestCase {
    func testBridgeIndicatorIsGreenWhenConnected() {
        XCTAssertEqual(
            BridgeConnectionIndicatorState.resolve(
                isConnected: true,
                hasActiveConnectionAttempt: false
            ),
            .connected
        )
    }

    func testBridgeIndicatorIsConnectingDuringHandshake() {
        XCTAssertEqual(
            BridgeConnectionIndicatorState.resolve(
                isConnected: false,
                hasActiveConnectionAttempt: true
            ),
            .connecting
        )
    }

    func testBridgeIndicatorIsRedWhenDisconnected() {
        XCTAssertEqual(
            BridgeConnectionIndicatorState.resolve(
                isConnected: false,
                hasActiveConnectionAttempt: false
            ),
            .disconnected
        )
    }

    func testReplacesStalePeerAfterMacRestarts() {
        let existing = MCPeerID(displayName: "Mac")
        let incoming = MCPeerID(displayName: "Mac")

        XCTAssertNotEqual(existing, incoming)
        XCTAssertTrue(
            BridgePeerReplacementPolicy.shouldReplace(
                existing: existing,
                incoming: incoming,
                hasActiveConnectionAttempt: false
            )
        )
    }

    func testKeepsPeerWhileConnectionAttemptIsActive() {
        let existing = MCPeerID(displayName: "Mac")
        let incoming = MCPeerID(displayName: "Mac")

        XCTAssertFalse(
            BridgePeerReplacementPolicy.shouldReplace(
                existing: existing,
                incoming: incoming,
                hasActiveConnectionAttempt: true
            )
        )
    }

    func testDoesNotReplaceSamePeer() {
        let peer = MCPeerID(displayName: "Mac")

        XCTAssertFalse(
            BridgePeerReplacementPolicy.shouldReplace(
                existing: peer,
                incoming: peer,
                hasActiveConnectionAttempt: false
            )
        )
    }

    func testMultipeerReconnectOnlyRunsWhenTCPIsIdle() {
        XCTAssertTrue(
            BridgeTransportSelectionPolicy
                .shouldAttemptMultipeerConnection(
                    isUserInitiated: true,
                    tcpIsAuthenticated: false,
                    tcpIsConnecting: false
                )
        )
        XCTAssertFalse(
            BridgeTransportSelectionPolicy
                .shouldAttemptMultipeerConnection(
                    isUserInitiated: true,
                    tcpIsAuthenticated: true,
                    tcpIsConnecting: false
                )
        )
        XCTAssertFalse(
            BridgeTransportSelectionPolicy
                .shouldAttemptMultipeerConnection(
                    isUserInitiated: true,
                    tcpIsAuthenticated: false,
                    tcpIsConnecting: true
                )
        )
        XCTAssertFalse(
            BridgeTransportSelectionPolicy
                .shouldAttemptMultipeerConnection(
                    isUserInitiated: false,
                    tcpIsAuthenticated: false,
                    tcpIsConnecting: false
                )
        )
    }

    func testMultipeerConnectionWaitsForPendingRequestBeforeRetiring() {
        XCTAssertFalse(
            BridgeTransportSelectionPolicy
                .shouldRetireMultipeerConnection(
                    tcpIsAuthenticated: true,
                    hasAuthenticatedMultipeerConnection: true,
                    pendingRequestCount: 1
                )
        )
        XCTAssertTrue(
            BridgeTransportSelectionPolicy
                .shouldRetireMultipeerConnection(
                    tcpIsAuthenticated: true,
                    hasAuthenticatedMultipeerConnection: true,
                    pendingRequestCount: 0
                )
        )
        XCTAssertFalse(
            BridgeTransportSelectionPolicy
                .shouldRetireMultipeerConnection(
                    tcpIsAuthenticated: false,
                    hasAuthenticatedMultipeerConnection: true,
                    pendingRequestCount: 0
                )
        )
    }

    func testDurableAssetRecognitionCapabilityIsRequired() {
        XCTAssertThrowsError(
            try BridgeCapabilityPolicy.requireDurableAssetRecognition(nil)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Mac 桥接版本较旧，请更新后再识别资产。"
            )
        }
        XCTAssertNoThrow(
            try BridgeCapabilityPolicy.requireDurableAssetRecognition([
                BridgeWire.durableAssetRecognitionCapability,
            ])
        )
    }

    func testLongRunningCodexOperationsOutliveObservedReportDuration() {
        XCTAssertEqual(
            BridgeRequestTimeoutPolicy.seconds(for: .generateReport),
            600
        )
        XCTAssertEqual(
            BridgeRequestTimeoutPolicy.seconds(for: .followUp),
            600
        )
        XCTAssertEqual(
            BridgeRequestTimeoutPolicy.seconds(for: .recognizeAssets),
            300
        )
        XCTAssertEqual(
            BridgeRequestTimeoutPolicy.seconds(for: .fetchExchangeRates),
            20
        )
    }

    func testReportRecoveryTreatsConnectionRaceAsResumable() {
        XCTAssertTrue(
            BridgeOperationRecoveryPolicy.isRecoverable(
                BridgeConnectionError.authenticationRequired
            )
        )
        XCTAssertTrue(
            BridgeOperationRecoveryPolicy.isRecoverable(
                TCPReconnectError.transportUnavailable("连接已中断。")
            )
        )
        XCTAssertTrue(
            BridgeOperationRecoveryPolicy.isRecoverable(
                TCPReconnectError.requestTimedOut
            )
        )
        XCTAssertTrue(
            BridgeOperationRecoveryPolicy.isRecoverable(
                BridgeConnectionError.remote(
                    BridgeErrorResponseV1(
                        code: "codex_unavailable",
                        message: "稍后重试",
                        retryable: true
                    )
                )
            )
        )
    }

    func testReportRecoveryKeepsTerminalFailuresVisible() {
        XCTAssertFalse(
            BridgeOperationRecoveryPolicy.isRecoverable(
                TCPReconnectError.authenticationFailed
            )
        )
        XCTAssertFalse(
            BridgeOperationRecoveryPolicy.isRecoverable(
                BridgeConnectionError.invalidResponse
            )
        )
        XCTAssertFalse(
            BridgeOperationRecoveryPolicy.isRecoverable(
                BridgeConnectionError.remote(
                    BridgeErrorResponseV1(
                        code: "invalid_codex_output",
                        message: "格式错误",
                        retryable: false
                    )
                )
            )
        )
    }
}
