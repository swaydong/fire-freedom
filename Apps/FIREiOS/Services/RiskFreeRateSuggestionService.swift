import Foundation

struct RiskFreeRateSuggestion: Codable, Equatable, Sendable {
    static let sourceName = "财政部：中国国债收益率曲线（10年期）"
    static let sourceURL = URL(
        string: "https://yield.chinabond.com.cn/cbweb-czb-web/czb/historyQuery"
    )!

    let rate: Double
    let asOf: Date
    let fetchedAt: Date
    let source: String
    let isFromCache: Bool
    let isStale: Bool

    fileprivate func asCached(isStale: Bool) -> Self {
        Self(
            rate: rate,
            asOf: asOf,
            fetchedAt: fetchedAt,
            source: source,
            isFromCache: true,
            isStale: isStale
        )
    }
}

enum RiskFreeRateSuggestionError: Error, Equatable, LocalizedError {
    case invalidResponse
    case invalidPayload
    case tenYearYieldMissing
    case unavailableWithoutCache

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "无风险利率数据服务返回异常，请稍后重试。"
        case .invalidPayload:
            "无法读取无风险利率数据，请稍后重试。"
        case .tenYearYieldMissing:
            "中国国债收益率曲线中没有可用的 10 年期数据。"
        case .unavailableWithoutCache:
            "当前无法联网，且本机还没有无风险利率建议缓存。"
        }
    }
}

@MainActor
final class RiskFreeRateSuggestionService {
    static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date
    private let cacheKey: String

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        cacheKey: String = "fire.risk-free-rate-suggestion.v1"
    ) {
        self.session = session
        self.defaults = defaults
        self.now = now
        self.cacheKey = cacheKey
    }

    func suggestion(forceRefresh: Bool = false) async throws
        -> RiskFreeRateSuggestion
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
            let request = try Self.makeRequest(at: requestDate)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode)
            else {
                throw RiskFreeRateSuggestionError.invalidResponse
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
            if let error = error as? RiskFreeRateSuggestionError {
                throw error
            }
            throw RiskFreeRateSuggestionError.unavailableWithoutCache
        }
    }

    func cachedSuggestion() -> RiskFreeRateSuggestion? {
        guard let data = defaults.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(
                  RiskFreeRateSuggestion.self,
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
    ) throws -> RiskFreeRateSuggestion {
        let payload: ChinaBondHistoryPayload
        do {
            payload = try JSONDecoder().decode(
                ChinaBondHistoryPayload.self,
                from: data
            )
        } catch {
            throw RiskFreeRateSuggestionError.invalidPayload
        }

        let latest = payload.history.compactMap { item
            -> (date: Date, rate: Double)? in
            guard let workTime = item.workTime,
                  let tenYear = item.tenYear,
                  let date = parseDate(workTime),
                  let value = Double(tenYear),
                  value.isFinite
            else {
                return nil
            }
            return (date, value)
        }
        .max(by: { $0.date < $1.date })

        guard let latest else {
            throw RiskFreeRateSuggestionError.tenYearYieldMissing
        }

        return RiskFreeRateSuggestion(
            rate: latest.rate / 100,
            asOf: latest.date,
            fetchedAt: fetchedAt,
            source: RiskFreeRateSuggestion.sourceName,
            isFromCache: false,
            isStale: false
        )
    }

    private static func makeRequest(at date: Date) throws -> URLRequest {
        var components = URLComponents(
            url: RiskFreeRateSuggestion.sourceURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "startDate",
                value: formattedDate(
                    calendar.date(
                        byAdding: .day,
                        value: -30,
                        to: date
                    ) ?? date
                )
            ),
            URLQueryItem(name: "endDate", value: formattedDate(date)),
            URLQueryItem(name: "gjqx", value: "10"),
            URLQueryItem(name: "locale", value: "en_US"),
            URLQueryItem(name: "qxmc", value: "1")
        ]
        guard let url = components?.url else {
            throw RiskFreeRateSuggestionError.invalidPayload
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        return request
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func cache(_ suggestion: RiskFreeRateSuggestion) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(suggestion)
        } catch {
            throw RiskFreeRateSuggestionError.invalidPayload
        }
        defaults.set(data, forKey: cacheKey)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

private struct ChinaBondHistoryPayload: Decodable {
    let history: [ChinaBondHistoryItem]

    enum CodingKeys: String, CodingKey {
        case history = "heList"
    }
}

private struct ChinaBondHistoryItem: Decodable {
    let workTime: String?
    let tenYear: String?
}
