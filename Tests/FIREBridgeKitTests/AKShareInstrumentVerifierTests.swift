#if os(macOS)
import Foundation
import XCTest
@testable import FIREBridgeKit

// Product names, identifiers, API responses, and amounts are synthetic test fixtures.
final class AKShareInstrumentVerifierTests: XCTestCase {
    func testMissingConfigurationDoesNotLaunchOrChangeCandidate()
        async throws {
        let runner = RecordingAKShareRunner(
            response: Data(#"{"results":[]}"#.utf8)
        )
        let verifier = AKShareInstrumentVerifier(
            pythonExecutablePath: nil,
            helperURL: URL(fileURLWithPath: "/tmp/unused-helper.py"),
            runner: runner
        )
        let input = position(code: "09876")

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertFalse(runner.wasInvoked)
        XCTAssertEqual(output.productName, input.productName)
        XCTAssertEqual(output.productCode, input.productCode)
        XCTAssertEqual(output.originalMarketValue, input.originalMarketValue)
        XCTAssertEqual(output.evidence, input.evidence)
        XCTAssertEqual(output.verification?.status, .unavailable)
    }

    func testMissingAKShareDependencyPreservesCandidate() async throws {
        let runner = RecordingAKShareRunner(
            response: Data(#"{"error":"akshare_unavailable"}"#.utf8)
        )
        let verifier = makeVerifier(runner: runner)
        let input = position(code: "09876")

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertTrue(runner.wasInvoked)
        XCTAssertEqual(output.productName, input.productName)
        XCTAssertEqual(output.productCode, input.productCode)
        XCTAssertEqual(output.originalMarketValue, input.originalMarketValue)
        XCTAssertEqual(output.evidence, input.evidence)
        XCTAssertEqual(output.verification?.status, .unavailable)
    }

    func testHongKongCodeIsCanonicalAndPayloadContainsOnlyAllowedFields()
        async throws {
        let runner = RecordingAKShareRunner(
            response: Data(
                """
                {"results":[{
                  "status":"verified",
                  "matchedName":"示例科技ETF",
                  "matchedCode":"09876",
                  "currency":"HKD",
                  "kind":"fund"
                }]}
                """.utf8
            )
        )
        let verifier = makeVerifier(runner: runner)
        let input = position(code: "9876.HK")

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)
        let payload = try XCTUnwrap(runner.lastStandardInput)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload)
                as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["positions"])
        let positions = try XCTUnwrap(object["positions"] as? [[String: Any]])
        let sent = try XCTUnwrap(positions.first)

        XCTAssertEqual(
            Set(sent.keys),
            ["productName", "productCode", "currency", "kind"]
        )
        XCTAssertEqual(sent["productCode"] as? String, "09876")
        XCTAssertNil(sent["originalMarketValue"])
        XCTAssertNil(sent["evidence"])
        XCTAssertNil(sent["imageIndex"])
        XCTAssertNil(sent["confidence"])
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("987654"))
        XCTAssertFalse(
            String(decoding: payload, as: UTF8.self)
                .contains("PRIVATE_SCREENSHOT_TEXT")
        )

        XCTAssertEqual(output.productName, "示例科技ETF")
        XCTAssertEqual(output.productCode, "09876")
        XCTAssertEqual(output.currency, .HKD)
        XCTAssertEqual(output.verification?.status, .verified)
    }

    func testSuppliedCodeIsNeverReplacedByNameMatch() async throws {
        let runner = RecordingAKShareRunner(
            response: Data(
                """
                {"results":[{
                  "status":"verified",
                  "matchedName":"示例科技ETF甲类",
                  "matchedCode":"991004",
                  "currency":"CNY",
                  "kind":"fund"
                }]}
                """.utf8
            )
        )
        let verifier = makeVerifier(runner: runner)
        let input = position(code: "09876")

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertEqual(output.productName, input.productName)
        XCTAssertEqual(output.productCode, "09876")
        XCTAssertEqual(output.verification?.status, .notFound)
    }

    func testNameOnlyUniqueResponseRemainsAmbiguousAndDoesNotWriteCode()
        async throws {
        let runner = RecordingAKShareRunner(
            response: Data(
                """
                {"results":[{
                  "status":"verified",
                  "matchedName":"示例科技ETF",
                  "matchedCode":"09876",
                  "currency":"HKD",
                  "kind":"fund"
                }]}
                """.utf8
            )
        )
        let verifier = makeVerifier(runner: runner)
        let input = position(code: nil)

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertNil(output.productCode)
        XCTAssertEqual(output.verification?.status, .ambiguous)
        XCTAssertEqual(output.verification?.matchedCode, "09876")
    }

    func testProcessEnvironmentRemovesPlatformAPIKeys() {
        let environment = FoundationAKShareProcessRunner.sanitizedEnvironment([
            "PATH": "/usr/bin",
            "OPENAI_API_KEY": "secret",
            "CODEX_API_KEY": "secret",
        ])

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["CODEX_API_KEY"])
    }

    func testProcessRunnerTimesOutInsteadOfBlockingForever() {
        let runner = FoundationAKShareProcessRunner(timeout: 0.05)

        XCTAssertThrowsError(
            try runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 2"],
                standardInput: Data()
            )
        )
    }

    private func makeVerifier(
        runner: RecordingAKShareRunner
    ) -> AKShareInstrumentVerifier {
        AKShareInstrumentVerifier(
            pythonExecutablePath: "/usr/bin/python3",
            helperURL: URL(fileURLWithPath: "/tmp/test-helper.py"),
            runner: runner
        )
    }

    private func position(code: String?) -> RecognizedAssetPositionV1 {
        RecognizedAssetPositionV1(
            imageIndex: 4,
            productName: "示例科技ETF",
            productCode: code,
            kind: .fund,
            currency: .HKD,
            originalMarketValue: 987_654,
            confidence: 0.83,
            evidence: "PRIVATE_SCREENSHOT_TEXT"
        )
    }
}

private final class RecordingAKShareRunner:
    AKShareProcessRunning,
    @unchecked Sendable {
    private let lock = NSLock()
    private let response: Data
    private var invocationCount = 0
    private var capturedStandardInput: Data?

    init(response: Data) {
        self.response = response
    }

    var wasInvoked: Bool {
        lock.withLock { invocationCount > 0 }
    }

    var lastStandardInput: Data? {
        lock.withLock { capturedStandardInput }
    }

    func run(
        executableURL _: URL,
        arguments _: [String],
        standardInput: Data
    ) throws -> Data {
        lock.withLock {
            invocationCount += 1
            capturedStandardInput = standardInput
        }
        return response
    }
}
#endif
