import Foundation
import SwiftData

struct FXQuote: Sendable {
    let ratesToCNY: [String: Double]
    let observationDate: Date
    let state: ExchangeRateState
    let fetchedAt: Date
    let source: String

    init(
        ratesToCNY: [String: Double],
        observationDate: Date,
        state: ExchangeRateState,
        fetchedAt: Date = .now,
        source: String = "ECB"
    ) {
        self.ratesToCNY = ratesToCNY
        self.observationDate = observationDate
        self.state = state
        self.fetchedAt = fetchedAt
        self.source = source
    }

    func cnyValue(_ amount: Double, currency: String) -> Double? {
        guard let rate = ratesToCNY[currency.uppercased()] else { return nil }
        return amount * rate
    }
}

enum FXServiceError: LocalizedError {
    case invalidResponse
    case missingCurrency(String)
    case noUsableCache

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "ECB 暂时没有返回可用汇率。"
        case .missingCurrency(let currency): "缺少 \(currency) 对人民币汇率。"
        case .noUsableCache:
            "Mac 桥接和 iPhone 都未能从 ECB 获取汇率，且没有可用缓存。请检查网络后重试；手动汇率仅作为最后兜底。"
        }
    }
}

actor ECBExchangeRateService {
    private let session: URLSession
    private let calendar = Calendar(identifier: .gregorian)

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchQuote(
        for snapshotDate: Date,
        requiredCurrencies: Set<String> = ["USD", "HKD"]
    ) async throws -> FXQuote {
        guard let startDate = calendar.date(byAdding: .day, value: -10, to: snapshotDate)
        else { throw FXServiceError.invalidResponse }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var components = URLComponents(
            string: "https://data-api.ecb.europa.eu/service/data/EXR/D.USD+HKD+CNY.EUR.SP00.A"
        )
        components?.queryItems = [
            URLQueryItem(name: "startPeriod", value: formatter.string(from: startDate)),
            URLQueryItem(name: "endPeriod", value: formatter.string(from: snapshotDate)),
            URLQueryItem(name: "format", value: "csvdata")
        ]
        guard let url = components?.url else { throw FXServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/csv", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let csv = String(data: data, encoding: .utf8) else {
            throw FXServiceError.invalidResponse
        }

        let observations = parseCSV(csv)
            .filter { $0.date <= calendar.startOfDay(for: snapshotDate) }
        let normalizedRequired = Set(
            requiredCurrencies.map { $0.uppercased() }
        )
        let requiredForDate = normalizedRequired.union(["CNY"])
        let observationsByDate = Dictionary(
            grouping: observations,
            by: \.date
        )
        let completeDates = observationsByDate.compactMap { entry in
            requiredForDate.isSubset(
                of: Set(entry.value.map(\.currency))
            ) ? entry.key : nil
        }
        guard let observationDate = completeDates.max() else {
            throw FXServiceError.invalidResponse
        }

        let latest = observationsByDate[observationDate] ?? []
        var unitsPerEUR: [String: Double] = [:]
        for observation in latest {
            unitsPerEUR[observation.currency] = observation.value
        }
        guard let cnyPerEUR = unitsPerEUR["CNY"] else {
            throw FXServiceError.missingCurrency("CNY")
        }

        var ratesToCNY = ["CNY": 1.0]
        for currency in normalizedRequired
            .filter({ $0 != "CNY" }) {
            guard let units = unitsPerEUR[currency], units > 0 else {
                throw FXServiceError.missingCurrency(currency)
            }
            ratesToCNY[currency] = cnyPerEUR / units
        }

        let age = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: observationDate),
            to: calendar.startOfDay(for: snapshotDate)
        ).day ?? 999
        return FXQuote(
            ratesToCNY: ratesToCNY,
            observationDate: observationDate,
            state: age <= 4 ? .current : .stale
        )
    }

    private func parseCSV(_ csv: String) -> [ECBObservation] {
        let rows = CSVRowParser.parse(csv)
        guard let headers = rows.first else { return [] }
        guard let currencyIndex = headers.firstIndex(of: "CURRENCY"),
              let dateIndex = headers.firstIndex(of: "TIME_PERIOD"),
              let valueIndex = headers.firstIndex(of: "OBS_VALUE") else {
            return []
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        return rows.dropFirst().compactMap { row in
            guard row.indices.contains(currencyIndex),
                  row.indices.contains(dateIndex),
                  row.indices.contains(valueIndex),
                  let date = formatter.date(from: row[dateIndex]),
                  let value = Double(row[valueIndex]) else {
                return nil
            }
            return ECBObservation(
                currency: row[currencyIndex].uppercased(),
                date: calendar.startOfDay(for: date),
                value: value
            )
        }
    }
}

@MainActor
final class FXRateResolver {
    private let service: ECBExchangeRateService
    private let context: ModelContext
    private let calendar = Calendar(identifier: .gregorian)

    init(service: ECBExchangeRateService, context: ModelContext) {
        self.service = service
        self.context = context
    }

    func quote(
        for snapshotDate: Date,
        requiredCurrencies: Set<String> = ["USD", "HKD"],
        preferredFetcher: (() async throws -> FXQuote)? = nil
    ) async throws -> FXQuote {
        if let preferredFetcher,
           let preferredQuote = try? await preferredFetcher(),
           isUsable(
               preferredQuote,
               for: snapshotDate,
               requiredCurrencies: requiredCurrencies
           ) {
            persist(preferredQuote)
            try context.save()
            return preferredQuote
        }

        do {
            let quote = try await service.fetchQuote(
                for: snapshotDate,
                requiredCurrencies: requiredCurrencies
            )
            guard isUsable(
                quote,
                for: snapshotDate,
                requiredCurrencies: requiredCurrencies
            ) else {
                throw FXServiceError.invalidResponse
            }
            persist(quote)
            try context.save()
            return quote
        } catch {
            if let cached = try cachedQuote(
                for: snapshotDate,
                requiredCurrencies: requiredCurrencies
            ) {
                return cached
            }
            throw FXServiceError.noUsableCache
        }
    }

    func saveManualRate(
        sourceCurrency: String,
        rateToCNY: Double,
        for snapshotDate: Date
    ) throws {
        let normalized = sourceCurrency.uppercased()
        let cacheKey = "\(normalized)-CNY"
        let cachedRates = try context.fetch(FetchDescriptor<ExchangeRateCacheEntity>())
        if let existing = cachedRates.first(where: { $0.cacheKey == cacheKey }) {
            existing.rate = rateToCNY
            existing.observationDate = snapshotDate
            existing.fetchedAt = .now
            existing.isManual = true
        } else {
            context.insert(
                ExchangeRateCacheEntity(
                    sourceCurrency: normalized,
                    rate: rateToCNY,
                    observationDate: snapshotDate,
                    isManual: true
                )
            )
        }
        try context.save()
    }

    private func persist(_ quote: FXQuote) {
        for (currency, rate) in quote.ratesToCNY where currency != "CNY" {
            let cacheKey = "\(currency)-CNY"
            let cachedRates = try? context.fetch(
                FetchDescriptor<ExchangeRateCacheEntity>()
            )
            if let existing = cachedRates?.first(where: { $0.cacheKey == cacheKey }) {
                existing.rate = rate
                existing.observationDate = quote.observationDate
                existing.fetchedAt = .now
                existing.isManual = false
            } else {
                context.insert(
                    ExchangeRateCacheEntity(
                        sourceCurrency: currency,
                        rate: rate,
                        observationDate: quote.observationDate
                    )
                )
            }
        }
    }

    private func isUsable(
        _ quote: FXQuote,
        for snapshotDate: Date,
        requiredCurrencies: Set<String>
    ) -> Bool {
        guard calendar.startOfDay(for: quote.observationDate)
                <= calendar.startOfDay(for: snapshotDate) else {
            return false
        }
        return requiredCurrencies
            .map { $0.uppercased() }
            .allSatisfy { currency in
                guard let rate = quote.ratesToCNY[currency] else {
                    return false
                }
                return rate.isFinite && rate > 0
            }
    }

    private func cachedQuote(
        for snapshotDate: Date,
        requiredCurrencies: Set<String>
    ) throws -> FXQuote? {
        let descriptor = FetchDescriptor<ExchangeRateCacheEntity>()
        let all = try context.fetch(descriptor)
        let required = requiredCurrencies
            .map { $0.uppercased() }
            .filter { $0 != "CNY" }
        var rates = ["CNY": 1.0]
        var dates: [Date] = []
        var fetchedDates: [Date] = []
        var usedManual = false

        for currency in required {
            guard let candidate = all
                .filter({
                    $0.sourceCurrency == currency
                        && $0.targetCurrency == "CNY"
                        && $0.observationDate <= snapshotDate
                })
                .max(by: { $0.observationDate < $1.observationDate }) else {
                return nil
            }
            rates[currency] = candidate.rate
            dates.append(candidate.observationDate)
            fetchedDates.append(candidate.fetchedAt)
            usedManual = usedManual || candidate.isManual
        }

        guard let oldestDate = dates.min() else { return nil }
        let age = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: oldestDate),
            to: calendar.startOfDay(for: snapshotDate)
        ).day ?? 999

        return FXQuote(
            ratesToCNY: rates,
            observationDate: oldestDate,
            state: usedManual ? .manual : (age <= 4 ? .current : .stale),
            fetchedAt: fetchedDates.min() ?? .now,
            source: usedManual ? "手动" : "ECB 缓存"
        )
    }
}

private struct ECBObservation {
    let currency: String
    let date: Date
    let value: Double
}

private enum CSVRowParser {
    static func parse(_ text: String) -> [[String]] {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var iterator = normalizedText.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if isQuoted {
                    // RFC 4180 的双引号转义。这里通过保守状态机处理常规 ECB 输出。
                    isQuoted = false
                } else {
                    isQuoted = true
                }
            } else if character == ",", !isQuoted {
                row.append(field)
                field = ""
            } else if character == "\n", !isQuoted {
                row.append(field.trimmingCharacters(in: .newlines))
                if !row.allSatisfy({ $0.isEmpty }) {
                    rows.append(row)
                }
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
