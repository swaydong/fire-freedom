#if os(macOS)
import XCTest
@testable import FIREBridgeKit

// Product names, identifiers, API responses, and amounts are synthetic test fixtures.
final class LocalInstrumentVerifierTests: XCTestCase {
    func testInjectedOverlayVerifiesCodeWithoutReplacingScreenshotName()
        async throws {
        let verifier = LocalInstrumentVerifier(directory: try SyntheticInstrumentDirectory.make())
        let input = position(
            name: "示例科技ETF",
            code: "09876",
            currency: .CNY
        )

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertEqual(output.productName, "示例科技ETF")
        XCTAssertEqual(output.productCode, "09876")
        XCTAssertEqual(output.kind, .fund)
        XCTAssertEqual(output.currency, .HKD)
        XCTAssertEqual(output.verification?.status, .verified)
        XCTAssertEqual(output.verification?.sourceName, "官方产品资料（离线）")
        XCTAssertEqual(
            output.verification?.matchedName,
            "Synthetic Technology Index ETF"
        )
    }

    func testNameOnlyCandidateStillRequiresConfirmation() async throws {
        let verifier = LocalInstrumentVerifier(directory: try SyntheticInstrumentDirectory.make())
        let input = position(
            name: "示例科技ETF",
            code: nil,
            currency: .HKD
        )

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertNil(output.productCode)
        XCTAssertEqual(output.verification?.status, .ambiguous)
        XCTAssertEqual(output.verification?.matchedCode, "09876")
    }

    func testSuppliedCodeCannotBecomeMainlandNameOnlyMatch() async throws {
        let verifier = LocalInstrumentVerifier(directory: try SyntheticInstrumentDirectory.make())
        let input = position(
            name: "示例科技ETF甲类",
            code: "09876",
            currency: .CNY
        )

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertEqual(output.productCode, "09876")
        XCTAssertNotEqual(output.productCode, "991004")
        XCTAssertEqual(output.verification?.status, .verified)
    }

    private func position(
        name: String,
        code: String?,
        currency: RecognizedAssetCurrencyV1
    ) -> RecognizedAssetPositionV1 {
        RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: name,
            productCode: code,
            kind: .fund,
            currency: currency,
            originalMarketValue: 100_000,
            confidence: 0.9,
            evidence: "\(name) \(code ?? "") 100,000"
        )
    }
}
#endif
