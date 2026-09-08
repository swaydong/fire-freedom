import Foundation
import XCTest
@testable import FIRE

@MainActor
final class RiskFreeRateSuggestionServiceTests: XCTestCase {
    override func tearDown() {
        RiskFreeRateStubURLProtocol.result = nil
        RiskFreeRateStubURLProtocol.requestCount = 0
        RiskFreeRateStubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testDecodesTenYearGovernmentBondYieldAndWorkDate() throws {
        let suggestion = try RiskFreeRateSuggestionService.decodeSuggestion(
            from: fixtureData,
            fetchedAt: date(2026, 7, 27)
        )

        XCTAssertEqual(suggestion.rate, 0.0173, accuracy: 0.000_001)
        XCTAssertEqual(suggestion.asOf, date(2026, 7, 24))
        XCTAssertEqual(suggestion.fetchedAt, date(2026, 7, 27))
        XCTAssertEqual(
            suggestion.source,
            "财政部：中国国债收益率曲线（10年期）"
        )
        XCTAssertFalse(suggestion.isFromCache)
        XCTAssertFalse(suggestion.isStale)
    }

    func testEmptyHistoryReturnsExplicitError() {
        XCTAssertThrowsError(
            try RiskFreeRateSuggestionService.decodeSuggestion(
                from: Data(#"{"heList":[],"flag":"0"}"#.utf8),
                fetchedAt: date(2026, 7, 27)
            )
        ) { error in
            XCTAssertEqual(
                error as? RiskFreeRateSuggestionError,
                .tenYearYieldMissing
            )
        }
    }

    func testSkipsRowsWithNullOrMissingValues() throws {
        let data = Data(
            """
            {
              "heList": [
                {"workTime": "2026-07-25", "tenYear": null},
                {"workTime": null, "tenYear": "9.99"},
                {"workTime": "2026-07-24", "tenYear": "1.73"},
                {"workTime": "2026-07-23"}
              ],
              "flag": "0"
            }
            """.utf8
        )

        let suggestion = try RiskFreeRateSuggestionService.decodeSuggestion(
            from: data,
            fetchedAt: date(2026, 7, 27)
        )

        XCTAssertEqual(suggestion.rate, 0.0173, accuracy: 0.000_001)
        XCTAssertEqual(suggestion.asOf, date(2026, 7, 24))
    }

    func testFreshCacheReturnsWithoutNetworkRequest() async throws {
        let suiteName = "RiskFreeRateSuggestionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = date(2026, 7, 20)
        RiskFreeRateStubURLProtocol.result = successResponse(fixtureData)
        let firstService = RiskFreeRateSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt }
        )
        _ = try await firstService.suggestion(forceRefresh: true)

        RiskFreeRateStubURLProtocol.requestCount = 0
        RiskFreeRateStubURLProtocol.result = .failure(
            URLError(.notConnectedToInternet)
        )
        let cachedService = RiskFreeRateSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt.addingTimeInterval(24 * 60 * 60) }
        )
        let cached = try await cachedService.suggestion()

        XCTAssertEqual(RiskFreeRateStubURLProtocol.requestCount, 0)
        XCTAssertTrue(cached.isFromCache)
        XCTAssertFalse(cached.isStale)
        XCTAssertEqual(cached.rate, 0.0173, accuracy: 0.000_001)
    }

    func testOfflineRefreshFallsBackToStaleCache() async throws {
        let suiteName = "RiskFreeRateSuggestionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = date(2026, 7, 1)
        RiskFreeRateStubURLProtocol.result = successResponse(fixtureData)
        let onlineService = RiskFreeRateSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt }
        )
        _ = try await onlineService.suggestion(forceRefresh: true)

        RiskFreeRateStubURLProtocol.requestCount = 0
        RiskFreeRateStubURLProtocol.result = .failure(
            URLError(.notConnectedToInternet)
        )
        let offlineService = RiskFreeRateSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: {
                fetchedAt.addingTimeInterval(
                    RiskFreeRateSuggestionService.cacheLifetime + 1
                )
            }
        )
        let cached = try await offlineService.suggestion(forceRefresh: true)

        XCTAssertEqual(RiskFreeRateStubURLProtocol.requestCount, 1)
        XCTAssertTrue(cached.isFromCache)
        XCTAssertTrue(cached.isStale)
        XCTAssertEqual(cached.rate, 0.0173, accuracy: 0.000_001)
    }

    func testFailedForcedRefreshKeepsFreshCacheMarkedCurrent() async throws {
        let suiteName = "RiskFreeRateSuggestionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = date(2026, 7, 20)
        RiskFreeRateStubURLProtocol.result = successResponse(fixtureData)
        let onlineService = RiskFreeRateSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt }
        )
        _ = try await onlineService.suggestion(forceRefresh: true)

        RiskFreeRateStubURLProtocol.requestCount = 0
        RiskFreeRateStubURLProtocol.result = .failure(
            URLError(.notConnectedToInternet)
        )
        let offlineService = RiskFreeRateSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { fetchedAt.addingTimeInterval(24 * 60 * 60) }
        )
        let cached = try await offlineService.suggestion(forceRefresh: true)

        XCTAssertEqual(RiskFreeRateStubURLProtocol.requestCount, 1)
        XCTAssertTrue(cached.isFromCache)
        XCTAssertFalse(cached.isStale)
    }

    func testOfflineWithoutCacheReturnsExplicitError() async {
        let suiteName = "RiskFreeRateSuggestionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        RiskFreeRateStubURLProtocol.result = .failure(
            URLError(.notConnectedToInternet)
        )
        let service = RiskFreeRateSuggestionService(
            session: makeSession(),
            defaults: defaults
        )

        do {
            _ = try await service.suggestion()
            XCTFail("offline without cache should fail")
        } catch let error as RiskFreeRateSuggestionError {
            XCTAssertEqual(error, .unavailableWithoutCache)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNetworkRequestUsesPostAndExpectedEndpoint() async throws {
        let suiteName = "RiskFreeRateSuggestionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        RiskFreeRateStubURLProtocol.result = successResponse(fixtureData)
        let service = RiskFreeRateSuggestionService(
            session: makeSession(),
            defaults: defaults,
            now: { self.date(2026, 7, 27) }
        )

        _ = try await service.suggestion(forceRefresh: true)

        let request = try XCTUnwrap(
            RiskFreeRateStubURLProtocol.lastRequest
        )
        XCTAssertEqual(request.httpMethod, "POST")
        let components = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )
        )
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "yield.chinabond.com.cn")
        XCTAssertEqual(
            components.path,
            "/cbweb-czb-web/czb/historyQuery"
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value)
            }
        )
        XCTAssertEqual(query["startDate"]!, "2026-06-27")
        XCTAssertEqual(query["endDate"]!, "2026-07-27")
        XCTAssertEqual(query["gjqx"]!, "10")
        XCTAssertEqual(query["locale"]!, "en_US")
        XCTAssertEqual(query["qxmc"]!, "1")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded; charset=UTF-8"
        )
    }

    private var fixtureData: Data {
        Data(
            """
            {
              "heList": [
                {
                  "workTime": "2026-07-22",
                  "tenYear": "1.72",
                  "qxmc": "ChinaBond Government Bond Yield Curve"
                },
                {
                  "workTime": "2026-07-24",
                  "tenYear": "1.73",
                  "qxmc": "ChinaBond Government Bond Yield Curve"
                },
                {
                  "workTime": "not-a-date",
                  "tenYear": "9.99",
                  "qxmc": "ChinaBond Government Bond Yield Curve"
                }
              ],
              "flag": "0"
            }
            """.utf8
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RiskFreeRateStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func successResponse(
        _ data: Data
    ) -> Result<(HTTPURLResponse, Data), Error> {
        .success(
            (
                HTTPURLResponse(
                    url: URL(
                        string: "https://yield.chinabond.com.cn"
                    )!,
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
        _ day: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }
}

private final class RiskFreeRateStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var result:
        Result<(HTTPURLResponse, Data), Error>?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
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
