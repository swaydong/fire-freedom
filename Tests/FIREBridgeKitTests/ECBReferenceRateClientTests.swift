#if os(macOS)
import Foundation
import XCTest
@testable import FIREBridgeKit

final class ECBReferenceRateClientTests: XCTestCase {
    override func tearDown() {
        ECBStubURLProtocol.result = nil
        super.tearDown()
    }

    func testWeekendRequestUsesLatestWorkingDayAndOnlyRequiresRequestedCurrencies() async throws {
        ECBStubURLProtocol.result = .success(
            (
                HTTPURLResponse(
                    url: URL(string: "https://data-api.ecb.europa.eu")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/csv"]
                )!,
                Data(
                    """
                    CURRENCY,TIME_PERIOD,OBS_VALUE
                    USD,2026-07-24,1.00
                    CNY,2026-07-24,7.20
                    CNY,2026-07-25,7.30
                    """.utf8
                )
            )
        )
        let client = ECBReferenceRateClient(session: makeSession())

        let response = try await client.fetchRates(
            for: date(2026, 7, 26),
            currencies: ["USD"]
        )

        XCTAssertEqual(dayComponents(response.observationDate), [2026, 7, 24])
        XCTAssertEqual(
            response.ratesToCNY["USD"] ?? 0,
            7.2,
            accuracy: 0.000_001
        )
        XCTAssertNil(response.ratesToCNY["HKD"])
        XCTAssertEqual(response.source, "ECB（Mac 桥接）")
    }

    func testDuplicateHeadersUseFirstMatchingColumn() async throws {
        ECBStubURLProtocol.result = .success(
            (
                HTTPURLResponse(
                    url: URL(string: "https://data-api.ecb.europa.eu")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/csv"]
                )!,
                Data(
                    """
                    CURRENCY,TIME_PERIOD,OBS_VALUE,OBS_VALUE
                    HKD,2026-07-24,7.80,999
                    CNY,2026-07-24,7.20,999
                    """.utf8
                )
            )
        )
        let client = ECBReferenceRateClient(session: makeSession())

        let response = try await client.fetchRates(
            for: date(2026, 7, 26),
            currencies: ["HKD"]
        )

        XCTAssertEqual(
            response.ratesToCNY["HKD"] ?? 0,
            7.2 / 7.8,
            accuracy: 0.000_001
        )
    }

    func testParsesECBResponseWithCRLFLineEndings() async throws {
        let csv = [
            "CURRENCY,TIME_PERIOD,OBS_VALUE",
            "USD,2026-07-24,1.00",
            "HKD,2026-07-24,7.80",
            "CNY,2026-07-24,7.20",
        ].joined(separator: "\r\n")
        ECBStubURLProtocol.result = .success(
            (
                HTTPURLResponse(
                    url: URL(string: "https://data-api.ecb.europa.eu")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/csv"]
                )!,
                Data(csv.utf8)
            )
        )
        let client = ECBReferenceRateClient(session: makeSession())

        let response = try await client.fetchRates(
            for: date(2026, 7, 26),
            currencies: ["USD", "HKD"]
        )

        XCTAssertEqual(dayComponents(response.observationDate), [2026, 7, 24])
        XCTAssertEqual(
            response.ratesToCNY["USD"] ?? 0,
            7.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            response.ratesToCNY["HKD"] ?? 0,
            7.2 / 7.8,
            accuracy: 0.000_001
        )
    }

    func testRejectsUnsupportedCurrencyBeforeRequestingNetwork() async throws {
        let client = ECBReferenceRateClient(session: makeSession())

        do {
            _ = try await client.fetchRates(
                for: date(2026, 7, 26),
                currencies: ["EUR"]
            )
            XCTFail("unsupported currency should fail")
        } catch let error as ReferenceExchangeRateError {
            XCTAssertEqual(error, .invalidCurrencies(["EUR"]))
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ECBStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }

    private func dayComponents(_ value: Date) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: value
        )
        return [
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
        ]
    }
}

private final class ECBStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var result:
        Result<(HTTPURLResponse, Data), Error>?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let result = Self.result else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unknown)
            )
            return
        }
        switch result {
        case let .success((response, data)):
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
#endif
