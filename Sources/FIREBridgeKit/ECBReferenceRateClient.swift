import Foundation

public protocol ReferenceExchangeRateFetching: Sendable {
    func fetchRates(
        for snapshotDate: Date,
        currencies: [String]
    ) async throws -> ExchangeRatesFetchedResponseV1
}

public enum ReferenceExchangeRateError: LocalizedError, Equatable {
    case invalidCurrencies([String])
    case requestFailed(String)
    case invalidResponse
    case missingCurrency(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCurrencies(let currencies):
            "暂不支持这些汇率币种：\(currencies.joined(separator: "、"))。"
        case .requestFailed:
            "Mac 暂时无法连接 ECB 官方汇率服务。"
        case .invalidResponse:
            "ECB 暂时没有返回可用汇率。"
        case .missingCurrency(let currency):
            "ECB 返回结果缺少 \(currency) 对人民币汇率。"
        }
    }
}

public actor ECBReferenceRateClient: ReferenceExchangeRateFetching {
    private static let supportedCurrencies = Set(["CNY", "USD", "HKD"])

    private let session: URLSession
    private var calendar: Calendar

    public init(session: URLSession = .shared) {
        self.session = session
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    public func fetchRates(
        for snapshotDate: Date,
        currencies: [String]
    ) async throws -> ExchangeRatesFetchedResponseV1 {
        let required = Set(currencies.map { $0.uppercased() })
        let unsupported = required.subtracting(Self.supportedCurrencies).sorted()
        guard !required.isEmpty, unsupported.isEmpty else {
            throw ReferenceExchangeRateError.invalidCurrencies(unsupported)
        }
        if required == ["CNY"] {
            return ExchangeRatesFetchedResponseV1(
                observationDate: snapshotDate,
                ratesToCNY: ["CNY": 1],
                source: "无需换算"
            )
        }

        guard let startDate = calendar.date(
            byAdding: .day,
            value: -14,
            to: snapshotDate
        ) else {
            throw ReferenceExchangeRateError.invalidResponse
        }

        let formatter = makeDateFormatter()
        var components = URLComponents(
            string: "https://data-api.ecb.europa.eu/service/data/EXR/D.USD+HKD+CNY.EUR.SP00.A"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "startPeriod",
                value: formatter.string(from: startDate)
            ),
            URLQueryItem(
                name: "endPeriod",
                value: formatter.string(from: snapshotDate)
            ),
            URLQueryItem(name: "format", value: "csvdata"),
        ]
        guard let url = components?.url else {
            throw ReferenceExchangeRateError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/csv", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReferenceExchangeRateError.requestFailed(
                error.localizedDescription
            )
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let csv = String(data: data, encoding: .utf8) else {
            throw ReferenceExchangeRateError.invalidResponse
        }

        let requestedDay = calendar.startOfDay(for: snapshotDate)
        let observations = parseCSV(csv).filter { $0.date <= requestedDay }
        let requiredForDate = required.union(["CNY"])
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
            throw ReferenceExchangeRateError.invalidResponse
        }

        let latest = observationsByDate[observationDate] ?? []
        var unitsPerEUR: [String: Double] = [:]
        for observation in latest
            where observation.value.isFinite && observation.value > 0 {
            unitsPerEUR[observation.currency] = observation.value
        }
        guard let cnyPerEUR = unitsPerEUR["CNY"] else {
            throw ReferenceExchangeRateError.missingCurrency("CNY")
        }

        var ratesToCNY = ["CNY": 1.0]
        for currency in required where currency != "CNY" {
            guard let units = unitsPerEUR[currency] else {
                throw ReferenceExchangeRateError.missingCurrency(currency)
            }
            ratesToCNY[currency] = cnyPerEUR / units
        }

        return ExchangeRatesFetchedResponseV1(
            observationDate: observationDate,
            ratesToCNY: ratesToCNY
        )
    }

    private func parseCSV(_ csv: String) -> [ECBRateObservation] {
        let rows = ECBRateCSVParser.parse(csv)
        guard let headers = rows.first,
              let currencyIndex = headers.firstIndex(of: "CURRENCY"),
              let dateIndex = headers.firstIndex(of: "TIME_PERIOD"),
              let valueIndex = headers.firstIndex(of: "OBS_VALUE") else {
            return []
        }

        let formatter = makeDateFormatter()
        return rows.dropFirst().compactMap { row in
            guard row.indices.contains(currencyIndex),
                  row.indices.contains(dateIndex),
                  row.indices.contains(valueIndex),
                  let date = formatter.date(from: row[dateIndex]),
                  let value = Double(row[valueIndex]) else {
                return nil
            }
            return ECBRateObservation(
                currency: row[currencyIndex].uppercased(),
                date: calendar.startOfDay(for: date),
                value: value
            )
        }
    }

    private func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

private struct ECBRateObservation {
    let currency: String
    let date: Date
    let value: Double
}

private enum ECBRateCSVParser {
    static func parse(_ text: String) -> [[String]] {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = normalizedText.startIndex

        while index < normalizedText.endIndex {
            let character = normalizedText[index]
            if character == "\"" {
                let next = normalizedText.index(after: index)
                if isQuoted,
                   next < normalizedText.endIndex,
                   normalizedText[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    isQuoted.toggle()
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
            index = normalizedText.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
