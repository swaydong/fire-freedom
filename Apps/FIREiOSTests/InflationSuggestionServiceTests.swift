import Foundation
import XCTest
@testable import FIRE

@MainActor
final class InflationSuggestionServiceTests: XCTestCase {
    override func tearDown() {
        InflationStubURLProtocol.result = nil
        InflationStubURLProtocol.requestCount = 0
        super.tearDown()
    }

    func testDecodesHeterogeneousWorldBankPayloadAndUsesLatestTenMedian()
        throws
    {
        let suggestion = try InflationSuggestionService.decodeSuggestion(
            from: fixtureData,
            fetchedAt: date(2026, 7, 26)
        )

        XCTAssertEqual(suggestion.rate, 0.065, accuracy: 0.000_001)
        XCTAssertEqual(
            suggestion.latestAnnualRate,
            0.11,
            accuracy: 0.000_001
        )
        XCTAssertEqual(suggestion.latestYear, 2025)
        XCTAssertEqual(suggestion.sampleStartYear, 2015)
        XCTAssertEqual(suggestion.sampleEndYear, 2025)
        XCTAssertEqual(
            suggestion.sourceUpdatedAt,
            date(2026, 7, 13, timeZone: TimeZone(secondsFromGMT: 0)!)
        )
        XCTAssertEqual(
            suggestion.source,
            "世界银行：中国 CPI 年度数据（IMF IFS）"
        )
    }

    func testFreshCacheReturnsWithoutNetworkRequest() async throws {
        let suiteName = "InflationSuggestionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = date(2026, 7, 1)
        InflationStubURLProtocol.result = successResponse(fixtureData)
        let firstService = InflationSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt }
        )
        _ = try await firstService.suggestion(forceRefresh: true)

        InflationStubURLProtocol.requestCount = 0
        InflationStubURLProtocol.result = .failure(
            URLError(.notConnectedToInternet)
        )
        let cachedService = InflationSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt.addingTimeInterval(24 * 60 * 60) }
        )
        let cached = try await cachedService.suggestion()

        XCTAssertEqual(InflationStubURLProtocol.requestCount, 0)
        XCTAssertTrue(cached.isFromCache)
        XCTAssertFalse(cached.isStale)
    }

    func testOfflineRefreshFallsBackToStaleCache() async throws {
        let suiteName = "InflationSuggestionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = date(2026, 6, 1)
        InflationStubURLProtocol.result = successResponse(fixtureData)
        let onlineService = InflationSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt }
        )
        _ = try await onlineService.suggestion(forceRefresh: true)

        InflationStubURLProtocol.requestCount = 0
        InflationStubURLProtocol.result = .failure(
            URLError(.notConnectedToInternet)
        )
        let offlineService = InflationSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: {
                fetchedAt.addingTimeInterval(
                    InflationSuggestionService.cacheLifetime + 1
                )
            }
        )
        let cached = try await offlineService.suggestion(forceRefresh: true)

        XCTAssertEqual(InflationStubURLProtocol.requestCount, 1)
        XCTAssertTrue(cached.isFromCache)
        XCTAssertTrue(cached.isStale)
        XCTAssertEqual(cached.rate, 0.065, accuracy: 0.000_001)
    }

    func testFailedForcedRefreshKeepsFreshCacheMarkedCurrent() async throws {
        let suiteName = "InflationSuggestionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = date(2026, 7, 1)
        InflationStubURLProtocol.result = successResponse(fixtureData)
        let onlineService = InflationSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt }
        )
        _ = try await onlineService.suggestion(forceRefresh: true)

        InflationStubURLProtocol.result = .failure(
            URLError(.notConnectedToInternet)
        )
        let offlineService = InflationSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt.addingTimeInterval(24 * 60 * 60) }
        )
        let cached = try await offlineService.suggestion(forceRefresh: true)

        XCTAssertTrue(cached.isFromCache)
        XCTAssertFalse(cached.isStale)
    }

    func testOfflineWithoutCacheReturnsExplicitError() async {
        let suiteName = "InflationSuggestionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        InflationStubURLProtocol.result = .failure(
            URLError(.notConnectedToInternet)
        )
        let service = InflationSuggestionService(
            session: makeSession(),
            defaults: defaults
        )

        do {
            _ = try await service.suggestion()
            XCTFail("offline without cache should fail")
        } catch let error as InflationSuggestionError {
            XCTAssertEqual(error, .unavailableWithoutCache)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private var fixtureData: Data {
        Data(
            """
            [
              {
                "page": 1,
                "pages": 1,
                "per_page": 30,
                "total": 13,
                "lastupdated": "2026-07-13"
              },
              [
                {"date": "2025", "value": 11.0},
                {"date": "2024", "value": null},
                {"date": "2023", "value": 10.0},
                {"date": "2022", "value": 9.0},
                {"date": "2021", "value": 8.0},
                {"date": "2020", "value": 7.0},
                {"date": "2019", "value": 6.0},
                {"date": "2018", "value": 5.0},
                {"date": "2017", "value": 4.0},
                {"date": "2016", "value": 3.0},
                {"date": "2015", "value": 2.0},
                {"date": "2014", "value": 1.0},
                {"date": "not-a-year", "value": 99.0}
              ]
            ]
            """.utf8
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InflationStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func successResponse(
        _ data: Data
    ) -> Result<(HTTPURLResponse, Data), Error> {
        .success(
            (
                HTTPURLResponse(
                    url: URL(string: "https://api.worldbank.org")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }
}

private final class InflationStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var result:
        Result<(HTTPURLResponse, Data), Error>?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
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
