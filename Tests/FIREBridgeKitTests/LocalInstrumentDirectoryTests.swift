import XCTest
@testable import FIREBridgeKit

final class LocalInstrumentDirectoryTests: XCTestCase {
    func testPublicSeedDoesNotBundlePersonalOrUnlicensedMarketData() throws {
        let directory = try LocalInstrumentDirectory.bundled()

        XCTAssertTrue(directory.sources.isEmpty)
        XCTAssertTrue(directory.instruments.isEmpty)
    }

    func testSourceProvenanceSurvivesDecoding() throws {
        let directory = try SyntheticInstrumentDirectory.make()
        let candidate = try XCTUnwrap(directory.candidates(code: "DEMO").only)

        XCTAssertEqual(directory.sources(for: candidate).map(\.kind), [.financeDatabase])
        XCTAssertEqual(directory.sources(for: candidate).first?.id, "synthetic-database")
    }

    func testNameAndCurrencyDisambiguateUSAndHongKongListings() throws {
        let directory = try SyntheticInstrumentDirectory.make()

        XCTAssertEqual(directory.candidates(name: "示例公司").map(\.code), ["9875.HK", "DEMO"])
        XCTAssertEqual(directory.candidates(name: "示例公司", currency: .USD).map(\.code), ["DEMO"])
        XCTAssertEqual(directory.candidates(name: "示例公司", currency: .HKD).map(\.code), ["9875.HK"])
    }

    func testOverlayResolvesLeadingZeroAndCommonBrokerFormats() throws {
        let directory = try SyntheticInstrumentDirectory.make()

        for code in ["09876", "9876", "09876.HK", "9876.HK"] {
            let candidate = try XCTUnwrap(directory.candidates(code: code, currency: .HKD).only)
            XCTAssertEqual(candidate.id, "HKEX:09876")
            XCTAssertEqual(candidate.name, "Synthetic Technology Index ETF")
            XCTAssertEqual(candidate.kind, .fund)
            XCTAssertEqual(directory.sources(for: candidate).map(\.kind), [.officialOverlay])
        }

        XCTAssertEqual(directory.candidates(name: "示例科技ETF", currency: .HKD).map(\.code), ["09876"])
        XCTAssertTrue(directory.candidates(code: "09876", currency: .CNY).isEmpty)
    }

    func testCombinedFiltersDoNotForceANameOnlyMatch() throws {
        let directory = try SyntheticInstrumentDirectory.make()

        XCTAssertTrue(directory.candidates(code: "09876", name: "示例科技ETF甲类", currency: .HKD).isEmpty)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
