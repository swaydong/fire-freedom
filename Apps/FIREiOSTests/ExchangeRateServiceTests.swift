import Foundation
import SwiftData
import XCTest
@testable import FIRE

@MainActor
final class ExchangeRateServiceTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.result = nil
        StubURLProtocol.requestCount = 0
        super.tearDown()
    }

    func testWeekendSnapshotFallsBackToLatestECBWorkingDay() async throws {
        let csv = """
        CURRENCY,TIME_PERIOD,OBS_VALUE
        USD,2026-07-24,1.00
        HKD,2026-07-24,7.80
        CNY,2026-07-24,7.20
        """
        StubURLProtocol.result = .success(
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
        let service = ECBExchangeRateService(session: makeSession())

        let quote = try await service.fetchQuote(
            for: date(2026, 7, 26)
        )

        XCTAssertEqual(dayComponents(quote.observationDate), [2026, 7, 24])
        XCTAssertEqual(
            quote.ratesToCNY["USD"] ?? 0,
            7.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            quote.ratesToCNY["HKD"] ?? 0,
            7.2 / 7.8,
            accuracy: 0.000_001
        )
    }

    func testDuplicateECBHeadersUseFirstMatchingColumnWithoutCrashing() async throws {
        let csv = """
        CURRENCY,TIME_PERIOD,OBS_VALUE,OBS_VALUE
        USD,2026-07-24,1.00,999
        HKD,2026-07-24,7.80,999
        CNY,2026-07-24,7.20,999
        """
        StubURLProtocol.result = .success(
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
        let service = ECBExchangeRateService(session: makeSession())

        let quote = try await service.fetchQuote(
            for: date(2026, 7, 26)
        )

        XCTAssertEqual(
            quote.ratesToCNY["USD"] ?? 0,
            7.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            quote.ratesToCNY["HKD"] ?? 0,
            7.2 / 7.8,
            accuracy: 0.000_001
        )
    }

    func testPhoneFetchParsesECBResponseWithCRLFLineEndings() async throws {
        let csv = [
            "CURRENCY,TIME_PERIOD,OBS_VALUE",
            "USD,2026-07-24,1.00",
            "HKD,2026-07-24,7.80",
            "CNY,2026-07-24,7.20",
        ].joined(separator: "\r\n")
        StubURLProtocol.result = .success(
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
        let service = ECBExchangeRateService(session: makeSession())

        let quote = try await service.fetchQuote(
            for: date(2026, 7, 26)
        )

        XCTAssertEqual(dayComponents(quote.observationDate), [2026, 7, 24])
        XCTAssertEqual(
            quote.ratesToCNY["USD"] ?? 0,
            7.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            quote.ratesToCNY["HKD"] ?? 0,
            7.2 / 7.8,
            accuracy: 0.000_001
        )
    }

    func testPhoneFetchOnlyRequiresCurrenciesNeededBySnapshot() async throws {
        let csv = """
        CURRENCY,TIME_PERIOD,OBS_VALUE
        USD,2026-07-24,1.00
        CNY,2026-07-24,7.20
        CNY,2026-07-25,7.30
        """
        StubURLProtocol.result = .success(
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
        let service = ECBExchangeRateService(session: makeSession())

        let quote = try await service.fetchQuote(
            for: date(2026, 7, 26),
            requiredCurrencies: ["USD"]
        )

        XCTAssertEqual(quote.ratesToCNY["USD"], 7.2)
        XCTAssertNil(quote.ratesToCNY["HKD"])
        XCTAssertEqual(dayComponents(quote.observationDate), [2026, 7, 24])
    }

    func testPhoneFetchMarksOldCompleteObservationAsStale() async throws {
        let csv = """
        CURRENCY,TIME_PERIOD,OBS_VALUE
        USD,2026-07-10,1.00
        CNY,2026-07-10,7.20
        """
        StubURLProtocol.result = .success(
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
        let service = ECBExchangeRateService(session: makeSession())

        let quote = try await service.fetchQuote(
            for: date(2026, 7, 20),
            requiredCurrencies: ["USD"]
        )

        XCTAssertEqual(quote.state, .stale)
    }

    func testOfflineResolverUsesStaleCacheAndMarksIt() async throws {
        StubURLProtocol.result = .failure(URLError(.notConnectedToInternet))
        let container = try makeContainer()
        let context = container.mainContext
        let observationDate = date(2026, 7, 10)
        context.insert(
            ExchangeRateCacheEntity(
                sourceCurrency: "USD",
                rate: 7.2,
                observationDate: observationDate
            )
        )
        context.insert(
            ExchangeRateCacheEntity(
                sourceCurrency: "HKD",
                rate: 0.92,
                observationDate: observationDate
            )
        )
        try context.save()
        let resolver = FXRateResolver(
            service: ECBExchangeRateService(session: makeSession()),
            context: context
        )

        let quote = try await resolver.quote(
            for: date(2026, 7, 20),
            requiredCurrencies: ["USD", "HKD"]
        )

        XCTAssertEqual(quote.state, .stale)
        XCTAssertEqual(quote.source, "ECB 缓存")
        XCTAssertEqual(quote.ratesToCNY["USD"], 7.2)
        XCTAssertEqual(quote.ratesToCNY["HKD"], 0.92)
    }

    func testOfflineWithoutRequiredRateIsBlocked() async throws {
        StubURLProtocol.result = .failure(URLError(.notConnectedToInternet))
        let container = try makeContainer()
        let resolver = FXRateResolver(
            service: ECBExchangeRateService(session: makeSession()),
            context: container.mainContext
        )

        do {
            _ = try await resolver.quote(
                for: date(2026, 7, 20),
                requiredCurrencies: ["USD"]
            )
            XCTFail("missing cache should fail")
        } catch let error as FXServiceError {
            guard case .noUsableCache = error else {
                return XCTFail("unexpected FX error: \(error)")
            }
        }
    }

    func testConnectedMacQuoteIsPreferredAndPersistedWithoutPhoneRequest() async throws {
        StubURLProtocol.result = .failure(URLError(.notConnectedToInternet))
        let container = try makeContainer()
        let context = container.mainContext
        let resolver = FXRateResolver(
            service: ECBExchangeRateService(session: makeSession()),
            context: context
        )

        let quote = try await resolver.quote(
            for: date(2026, 7, 26),
            requiredCurrencies: ["USD"],
            preferredFetcher: {
                FXQuote(
                    ratesToCNY: ["CNY": 1, "USD": 7.25],
                    observationDate: self.date(2026, 7, 24),
                    state: .current,
                    source: "ECB（Mac 桥接）"
                )
            }
        )

        XCTAssertEqual(quote.source, "ECB（Mac 桥接）")
        XCTAssertEqual(quote.ratesToCNY["USD"], 7.25)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        let cached = try context.fetch(
            FetchDescriptor<ExchangeRateCacheEntity>()
        )
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(cached.first?.rate, 7.25)
        XCTAssertEqual(cached.first?.isManual, false)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(FIREModelSchema.models)
        let configuration = ModelConfiguration(
            "FXTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
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

private final class StubURLProtocol: URLProtocol {
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
