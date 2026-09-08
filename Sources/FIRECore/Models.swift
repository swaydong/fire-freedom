import Foundation

public enum CurrencyCode: String, Codable, CaseIterable, Sendable {
    case cny = "CNY"
    case usd = "USD"
    case hkd = "HKD"
}

public enum TransactionDirection: String, Codable, Sendable {
    case income
    case expense
}

public enum AssetKind: String, Codable, CaseIterable, Sendable {
    case fund
    case stock
    case option
    case cash
}

public enum DataConfidence: String, Codable, CaseIterable, Sendable {
    case insufficient
    case low
    case medium
    case high

    public static func from(completeMonthCount: Int) -> Self {
        switch completeMonthCount {
        case 12...:
            .high
        case 6...11:
            .medium
        case 3...5:
            .low
        default:
            .insufficient
        }
    }
}

public enum AssetSnapshotStatus: String, Codable, Sendable {
    case draft
    case needsReview
    case confirmedComplete
    case blockedMissingExchangeRate
}

public struct TransactionCoverage: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct TransactionCoverageMergeResult: Equatable, Sendable {
    public var coverage: TransactionCoverage
    public var hadGap: Bool

    public init(coverage: TransactionCoverage, hadGap: Bool) {
        self.coverage = coverage
        self.hadGap = hadGap
    }
}

public enum TransactionCoverageMerger {
    public static func merge(
        existing: TransactionCoverage?,
        incoming: TransactionCoverage
    ) -> TransactionCoverageMergeResult {
        guard let existing else {
            return TransactionCoverageMergeResult(
                coverage: incoming,
                hadGap: false
            )
        }

        let calendar = coverageCalendar
        let existingEndPlusOne = calendar.date(
            byAdding: .day,
            value: 1,
            to: existing.end
        ) ?? existing.end
        let incomingEndPlusOne = calendar.date(
            byAdding: .day,
            value: 1,
            to: incoming.end
        ) ?? incoming.end
        let overlapsOrTouches = incoming.start <= existingEndPlusOne
            && existing.start <= incomingEndPlusOne

        if overlapsOrTouches {
            return TransactionCoverageMergeResult(
                coverage: TransactionCoverage(
                    start: min(existing.start, incoming.start),
                    end: max(existing.end, incoming.end)
                ),
                hadGap: false
            )
        }

        let newest = incoming.end >= existing.end ? incoming : existing
        return TransactionCoverageMergeResult(
            coverage: newest,
            hadGap: true
        )
    }

    private static var coverageCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
}

public struct TransactionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var direction: TransactionDirection
    public var amount: Decimal
    public var currency: CurrencyCode
    public var primaryCategory: String
    public var secondaryCategory: String
    public var merchantNote: String
    public var tags: [String]
    public var accountName: String
    public var ledgerName: String
    public var includedInCashFlow: Bool
    public var includedInBudget: Bool
    public var isInternalTransfer: Bool
    public var isInvestmentTrade: Bool
    public var isLoanPrincipal: Bool
    public var isRefund: Bool
    public var fingerprint: String
    public var suspectedDuplicate: Bool
    public var duplicateOfFingerprint: String?
    public var importRow: Int?

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        direction: TransactionDirection,
        amount: Decimal,
        currency: CurrencyCode = .cny,
        primaryCategory: String,
        secondaryCategory: String = "",
        merchantNote: String = "",
        tags: [String] = [],
        accountName: String = "",
        ledgerName: String = "",
        includedInCashFlow: Bool = true,
        includedInBudget: Bool = true,
        isInternalTransfer: Bool = false,
        isInvestmentTrade: Bool = false,
        isLoanPrincipal: Bool = false,
        isRefund: Bool = false,
        fingerprint: String = "",
        suspectedDuplicate: Bool = false,
        duplicateOfFingerprint: String? = nil,
        importRow: Int? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.direction = direction
        self.amount = amount
        self.currency = currency
        self.primaryCategory = primaryCategory
        self.secondaryCategory = secondaryCategory
        self.merchantNote = merchantNote
        self.tags = tags
        self.accountName = accountName
        self.ledgerName = ledgerName
        self.includedInCashFlow = includedInCashFlow
        self.includedInBudget = includedInBudget
        self.isInternalTransfer = isInternalTransfer
        self.isInvestmentTrade = isInvestmentTrade
        self.isLoanPrincipal = isLoanPrincipal
        self.isRefund = isRefund
        self.fingerprint = fingerprint
        self.suspectedDuplicate = suspectedDuplicate
        self.duplicateOfFingerprint = duplicateOfFingerprint
        self.importRow = importRow
    }
}

public struct Instrument: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var code: String?
    public var name: String
    public var kind: AssetKind
    public var currency: CurrencyCode

    public init(
        id: UUID = UUID(),
        code: String? = nil,
        name: String,
        kind: AssetKind,
        currency: CurrencyCode
    ) {
        self.id = id
        self.code = code?.trimmedNilIfEmpty
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.currency = currency
    }
}

public struct PositionSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var instrument: Instrument
    public var originalMarketValue: Decimal
    public var marketValueInCNY: Decimal
    public var quantity: Decimal?
    public var unitPrice: Decimal?
    public var capturedAt: Date
    public var recognitionConfidence: Double
    public var needsConfirmation: Bool
    public var sourceImportID: String?

    public init(
        id: UUID = UUID(),
        instrument: Instrument,
        originalMarketValue: Decimal,
        marketValueInCNY: Decimal,
        quantity: Decimal? = nil,
        unitPrice: Decimal? = nil,
        capturedAt: Date,
        recognitionConfidence: Double = 1,
        needsConfirmation: Bool = false,
        sourceImportID: String? = nil
    ) {
        self.id = id
        self.instrument = instrument
        self.originalMarketValue = originalMarketValue
        self.marketValueInCNY = marketValueInCNY
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.capturedAt = capturedAt
        self.recognitionConfidence = min(max(recognitionConfidence, 0), 1)
        self.needsConfirmation = needsConfirmation
        self.sourceImportID = sourceImportID
    }
}

public struct Liability: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var currency: CurrencyCode
    public var remainingPrincipal: Decimal
    public var remainingPrincipalInCNY: Decimal
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        currency: CurrencyCode,
        remainingPrincipal: Decimal,
        remainingPrincipalInCNY: Decimal,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.remainingPrincipal = remainingPrincipal
        self.remainingPrincipalInCNY = remainingPrincipalInCNY
        self.updatedAt = updatedAt
    }
}

public struct ExchangeRateSnapshot: Codable, Equatable, Sendable {
    public var asOf: Date
    public var fetchedAt: Date
    public var cnyPerUnit: [String: Decimal]
    public var source: String
    public var isStale: Bool

    public init(
        asOf: Date,
        fetchedAt: Date = Date(),
        cnyPerUnit: [String: Decimal],
        source: String = "ECB",
        isStale: Bool = false
    ) {
        self.asOf = asOf
        self.fetchedAt = fetchedAt
        self.cnyPerUnit = cnyPerUnit
        self.source = source
        self.isStale = isStale
    }

    public func convertedToCNY(_ amount: Decimal, currency: CurrencyCode) -> Decimal? {
        guard let rate = cnyPerUnit[currency.rawValue] else {
            return currency == .cny ? amount : nil
        }
        return amount * rate
    }
}

public struct AssetSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var positions: [PositionSnapshot]
    public var cashBalances: [String: Decimal]
    public var cashValueInCNY: Decimal
    public var liabilities: [Liability]
    public var exchangeRates: ExchangeRateSnapshot?
    public var status: AssetSnapshotStatus
    public var dataIssues: [String]

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        positions: [PositionSnapshot],
        cashBalances: [String: Decimal] = [:],
        cashValueInCNY: Decimal = 0,
        liabilities: [Liability] = [],
        exchangeRates: ExchangeRateSnapshot? = nil,
        status: AssetSnapshotStatus = .draft,
        dataIssues: [String] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.positions = positions
        self.cashBalances = cashBalances
        self.cashValueInCNY = cashValueInCNY
        self.liabilities = liabilities
        self.exchangeRates = exchangeRates
        self.status = status
        self.dataIssues = dataIssues
    }

    public var investedAssetsInCNY: Decimal {
        positions
            .filter { $0.instrument.kind != .cash }
            .reduce(0) { $0 + $1.marketValueInCNY }
    }

    public var outstandingLiabilitiesInCNY: Decimal {
        liabilities.reduce(0) { $0 + $1.remainingPrincipalInCNY }
    }

    public var totalCashInCNY: Decimal {
        if cashValueInCNY != 0 || !cashBalances.isEmpty {
            return cashValueInCNY
        }
        return positions
            .filter { $0.instrument.kind == .cash }
            .reduce(0) { $0 + $1.marketValueInCNY }
    }

    public var investableNetWorthInCNY: Decimal {
        investedAssetsInCNY + totalCashInCNY - outstandingLiabilitiesInCNY
    }
}

public struct ExpenseAnalysis: Codable, Equatable, Sendable {
    public var annualSpending: Decimal
    public var recurringAnnualized: Decimal
    public var irregularObservedOrRolling12: Decimal
    public var refundOffset: Decimal
    public var completeMonthCount: Int
    public var confidence: DataConfidence
    public var excludedTransactionCount: Int
    public var duplicateTransactionCount: Int
    public var periodStart: Date?
    public var periodEnd: Date?

    public init(
        annualSpending: Decimal,
        recurringAnnualized: Decimal,
        irregularObservedOrRolling12: Decimal,
        refundOffset: Decimal,
        completeMonthCount: Int,
        confidence: DataConfidence,
        excludedTransactionCount: Int,
        duplicateTransactionCount: Int,
        periodStart: Date?,
        periodEnd: Date?
    ) {
        self.annualSpending = annualSpending
        self.recurringAnnualized = recurringAnnualized
        self.irregularObservedOrRolling12 = irregularObservedOrRolling12
        self.refundOffset = refundOffset
        self.completeMonthCount = completeMonthCount
        self.confidence = confidence
        self.excludedTransactionCount = excludedTransactionCount
        self.duplicateTransactionCount = duplicateTransactionCount
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}

public struct MonthlyContributionSuggestion: Codable, Equatable, Sendable {
    public var amount: Decimal?
    public var monthsUsed: Int
    public var confidence: DataConfidence
    public var rationale: String

    public init(
        amount: Decimal?,
        monthsUsed: Int,
        confidence: DataConfidence,
        rationale: String
    ) {
        self.amount = amount
        self.monthsUsed = monthsUsed
        self.confidence = confidence
        self.rationale = rationale
    }
}

public struct MonthlySurplusReference: Equatable, Sendable {
    public var median: Decimal?
    public var latest: Decimal?
    public var minimum: Decimal?
    public var maximum: Decimal?
    public var monthsUsed: Int

    public init(
        median: Decimal?,
        latest: Decimal?,
        minimum: Decimal?,
        maximum: Decimal?,
        monthsUsed: Int
    ) {
        self.median = median
        self.latest = latest
        self.minimum = minimum
        self.maximum = maximum
        self.monthsUsed = monthsUsed
    }

    public static let empty = MonthlySurplusReference(
        median: nil,
        latest: nil,
        minimum: nil,
        maximum: nil,
        monthsUsed: 0
    )
}

public struct AnnualBonusReference: Equatable, Sendable {
    public var latestYear: Int?
    public var latestYearTotal: Decimal?
    public var annualMedian: Decimal?
    public var yearsUsed: Int
    public var transactionCount: Int

    public init(
        latestYear: Int?,
        latestYearTotal: Decimal?,
        annualMedian: Decimal?,
        yearsUsed: Int,
        transactionCount: Int
    ) {
        self.latestYear = latestYear
        self.latestYearTotal = latestYearTotal
        self.annualMedian = annualMedian
        self.yearsUsed = yearsUsed
        self.transactionCount = transactionCount
    }

    public static let empty = AnnualBonusReference(
        latestYear: nil,
        latestYearTotal: nil,
        annualMedian: nil,
        yearsUsed: 0,
        transactionCount: 0
    )
}

public struct ContributionHistoryReference: Equatable, Sendable {
    public var monthlySurplus: MonthlySurplusReference
    public var monthlyStableIncome: MonthlySurplusReference
    public var annualBonus: AnnualBonusReference

    public init(
        monthlySurplus: MonthlySurplusReference,
        monthlyStableIncome: MonthlySurplusReference = .empty,
        annualBonus: AnnualBonusReference
    ) {
        self.monthlySurplus = monthlySurplus
        self.monthlyStableIncome = monthlyStableIncome
        self.annualBonus = annualBonus
    }

    public static let empty = ContributionHistoryReference(
        monthlySurplus: .empty,
        monthlyStableIncome: .empty,
        annualBonus: .empty
    )
}

public struct FIREAssumptions: Codable, Equatable, Sendable {
    public var withdrawalRate: Decimal
    public var expectedAnnualReturn: Decimal
    public var annualInflation: Decimal

    public init(
        withdrawalRate: Decimal = Decimal(string: "0.035")!,
        expectedAnnualReturn: Decimal = Decimal(string: "0.05")!,
        annualInflation: Decimal = Decimal(string: "0.02")!
    ) {
        self.withdrawalRate = withdrawalRate
        self.expectedAnnualReturn = expectedAnnualReturn
        self.annualInflation = annualInflation
    }

    public static let conservative = FIREAssumptions(
        withdrawalRate: Decimal(string: "0.03")!
    )
    public static let balanced = FIREAssumptions()
    public static let optimisticWithdrawal = FIREAssumptions(
        withdrawalRate: Decimal(string: "0.04")!
    )
}

public struct FIREState: Codable, Equatable, Sendable {
    public var calculatedAt: Date
    public var investableNetWorth: Decimal
    public var annualSpending: Decimal
    public var targetAmount: Decimal
    public var progress: Decimal
    public var remainingAmount: Decimal
    public var confirmedMonthlyContribution: Decimal?
    public var confirmedAnnualBonusContribution: Decimal?
    public var suggestedMonthlyContribution: MonthlyContributionSuggestion
    public var estimatedFreedomDate: Date?
    public var estimatedMonthsRemaining: Int?
    public var confidence: DataConfidence
    public var assumptions: FIREAssumptions
    public var expenseAnalysis: ExpenseAnalysis

    public init(
        calculatedAt: Date,
        investableNetWorth: Decimal,
        annualSpending: Decimal,
        targetAmount: Decimal,
        progress: Decimal,
        remainingAmount: Decimal,
        confirmedMonthlyContribution: Decimal?,
        confirmedAnnualBonusContribution: Decimal? = nil,
        suggestedMonthlyContribution: MonthlyContributionSuggestion,
        estimatedFreedomDate: Date?,
        estimatedMonthsRemaining: Int?,
        confidence: DataConfidence,
        assumptions: FIREAssumptions,
        expenseAnalysis: ExpenseAnalysis
    ) {
        self.calculatedAt = calculatedAt
        self.investableNetWorth = investableNetWorth
        self.annualSpending = annualSpending
        self.targetAmount = targetAmount
        self.progress = progress
        self.remainingAmount = remainingAmount
        self.confirmedMonthlyContribution = confirmedMonthlyContribution
        self.confirmedAnnualBonusContribution =
            confirmedAnnualBonusContribution
        self.suggestedMonthlyContribution = suggestedMonthlyContribution
        self.estimatedFreedomDate = estimatedFreedomDate
        self.estimatedMonthsRemaining = estimatedMonthsRemaining
        self.confidence = confidence
        self.assumptions = assumptions
        self.expenseAnalysis = expenseAnalysis
    }
}

public extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }

    func rounded(scale: Int = 2) -> Decimal {
        var source = self
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .bankers)
        return result
    }
}

extension String {
    var trimmedNilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
