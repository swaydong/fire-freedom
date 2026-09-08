import Foundation

struct InflationSuggestion: Codable, Equatable, Sendable {
    static let sourceName = "世界银行：中国 CPI 年度数据（IMF IFS）"

    let rate: Double
    let latestAnnualRate: Double
    let latestYear: Int
    let sampleStartYear: Int
    let sampleEndYear: Int
    let fetchedAt: Date
    let sourceUpdatedAt: Date?
    let source: String
    let isFromCache: Bool
    let isStale: Bool

    var sampleYearRange: ClosedRange<Int> {
        sampleStartYear ... sampleEndYear
    }

    fileprivate func asCached(isStale: Bool) -> Self {
        Self(
            rate: rate,
            latestAnnualRate: latestAnnualRate,
            latestYear: latestYear,
            sampleStartYear: sampleStartYear,
            sampleEndYear: sampleEndYear,
            fetchedAt: fetchedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            source: source,
            isFromCache: true,
            isStale: isStale
        )
    }
}

enum InflationSuggestionError: Error, Equatable, LocalizedError {
    case invalidResponse
    case invalidPayload
    case noAnnualValues
    case unavailableWithoutCache

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "通胀数据服务返回异常，请稍后重试。"
        case .invalidPayload:
            "无法读取通胀数据，请稍后重试。"
        case .noAnnualValues:
            "通胀数据中没有可用的年度数值。"
        case .unavailableWithoutCache:
            "当前无法联网，且本机还没有通胀建议缓存。"
        }
    }
}

@MainActor
final class InflationSuggestionService {
    static let cacheLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date
    private let cacheKey: String

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        cacheKey: String = "fire.inflation-suggestion.v1"
    ) {
        self.session = session
        self.defaults = defaults
        self.now = now
        self.cacheKey = cacheKey
    }

    func suggestion(forceRefresh: Bool = false) async throws
        -> InflationSuggestion
    {
        let requestDate = now()
        let cached = cachedSuggestion()
        if !forceRefresh,
           let cached,
           requestDate.timeIntervalSince(cached.fetchedAt) <
            Self.cacheLifetime
        {
            return cached.asCached(isStale: false)
        }

        do {
            let request = try makeRequest(at: requestDate)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode)
            else {
                throw InflationSuggestionError.invalidResponse
            }
            let suggestion = try Self.decodeSuggestion(
                from: data,
                fetchedAt: requestDate
            )
            try cache(suggestion)
            return suggestion
        } catch {
            if let cached {
                let isStale = requestDate.timeIntervalSince(
                    cached.fetchedAt
                ) >= Self.cacheLifetime
                return cached.asCached(isStale: isStale)
            }
            if let error = error as? InflationSuggestionError {
                throw error
            }
            throw InflationSuggestionError.unavailableWithoutCache
        }
    }

    func cachedSuggestion() -> InflationSuggestion? {
        guard let data = defaults.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(
                  InflationSuggestion.self,
                  from: data
              )
        else {
            return nil
        }
        let isStale = now().timeIntervalSince(cached.fetchedAt) >=
            Self.cacheLifetime
        return cached.asCached(isStale: isStale)
    }

    static func decodeSuggestion(
        from data: Data,
        fetchedAt: Date
    ) throws -> InflationSuggestion {
        let payload: WorldBankResponse
        do {
            payload = try JSONDecoder().decode(
                WorldBankResponse.self,
                from: data
            )
        } catch {
            throw InflationSuggestionError.invalidPayload
        }

        let observations = payload.observations
            .compactMap { observation -> AnnualInflation? in
                guard let year = Int(observation.date),
                      let value = observation.value,
                      value.isFinite
                else {
                    return nil
                }
                return AnnualInflation(year: year, percent: value)
            }
            .sorted { $0.year > $1.year }

        guard let latest = observations.first else {
            throw InflationSuggestionError.noAnnualValues
        }
        let sample = Array(observations.prefix(10))
        let sortedValues = sample.map(\.percent).sorted()
        let midpoint = sortedValues.count / 2
        let medianPercent: Double
        if sortedValues.count.isMultiple(of: 2) {
            medianPercent =
                (sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2
        } else {
            medianPercent = sortedValues[midpoint]
        }

        return InflationSuggestion(
            rate: medianPercent / 100,
            latestAnnualRate: latest.percent / 100,
            latestYear: latest.year,
            sampleStartYear: sample.map(\.year).min() ?? latest.year,
            sampleEndYear: sample.map(\.year).max() ?? latest.year,
            fetchedAt: fetchedAt,
            sourceUpdatedAt: parseDate(payload.metadata.lastUpdated),
            source: InflationSuggestion.sourceName,
            isFromCache: false,
            isStale: false
        )
    }

    private func makeRequest(at date: Date) throws -> URLRequest {
        let currentYear = Calendar(identifier: .gregorian).component(
            .year,
            from: date
        )
        var components = URLComponents(
            string: "https://api.worldbank.org/v2/country/CHN/indicator/FP.CPI.TOTL.ZG"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "date",
                value: "\(currentYear - 14):\(currentYear)"
            ),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "per_page", value: "30"),
        ]
        guard let url = components?.url else {
            throw InflationSuggestionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func cache(_ suggestion: InflationSuggestion) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(suggestion)
        } catch {
            throw InflationSuggestionError.invalidPayload
        }
        defaults.set(data, forKey: cacheKey)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

private struct WorldBankResponse: Decodable {
    let metadata: Metadata
    let observations: [Observation]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        metadata = try container.decode(Metadata.self)
        observations = try container.decode([Observation].self)
    }

    struct Metadata: Decodable {
        let lastUpdated: String?

        enum CodingKeys: String, CodingKey {
            case lastUpdated = "lastupdated"
        }
    }

    struct Observation: Decodable {
        let date: String
        let value: Double?
    }
}

private struct AnnualInflation {
    let year: Int
    let percent: Double
}
