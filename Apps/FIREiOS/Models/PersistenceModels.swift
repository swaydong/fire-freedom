import Foundation
import SwiftData

@Model
final class TransactionEntity {
    var id: UUID
    var fingerprint: String
    var semanticHash: String?
    var sourceRawValue: String?
    var sourceScopeID: String?
    var importBatchID: UUID?
    var logicalTransactionID: UUID?
    var sourceRow: Int?
    var transactionDate: Date
    var directionRawValue: String
    var amount: Double
    var category: String
    var subcategory: String
    var merchant: String
    var note: String
    var account: String
    var currency: String
    var tagsJSON: Data?
    var ledgerName: String?
    var sourceIncludedInCashFlow: Bool?
    var includedInBudget: Bool?
    var allocationDetails: String?
    var rawSourceJSON: Data?
    var isIncluded: Bool
    var isSuspectedDuplicate: Bool
    var isInternalTransfer: Bool
    var isInvestmentTrade: Bool
    var isLoanPrincipal: Bool
    var importedAt: Date

    init(
        id: UUID = UUID(),
        fingerprint: String,
        semanticHash: String? = nil,
        sourceRawValue: String? = nil,
        sourceScopeID: String? = nil,
        importBatchID: UUID? = nil,
        logicalTransactionID: UUID? = nil,
        sourceRow: Int? = nil,
        transactionDate: Date,
        directionRawValue: String,
        amount: Double,
        category: String,
        subcategory: String,
        merchant: String,
        note: String,
        account: String,
        currency: String = "CNY",
        tagsJSON: Data? = nil,
        ledgerName: String? = nil,
        sourceIncludedInCashFlow: Bool? = nil,
        includedInBudget: Bool? = nil,
        allocationDetails: String? = nil,
        rawSourceJSON: Data? = nil,
        isIncluded: Bool = true,
        isSuspectedDuplicate: Bool = false,
        isInternalTransfer: Bool = false,
        isInvestmentTrade: Bool = false,
        isLoanPrincipal: Bool = false,
        importedAt: Date = .now
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.semanticHash = semanticHash
        self.sourceRawValue = sourceRawValue
        self.sourceScopeID = sourceScopeID
        self.importBatchID = importBatchID
        self.logicalTransactionID = logicalTransactionID
        self.sourceRow = sourceRow
        self.transactionDate = transactionDate
        self.directionRawValue = directionRawValue
        self.amount = amount
        self.category = category
        self.subcategory = subcategory
        self.merchant = merchant
        self.note = note
        self.account = account
        self.currency = currency
        self.tagsJSON = tagsJSON
        self.ledgerName = ledgerName
        self.sourceIncludedInCashFlow = sourceIncludedInCashFlow
        self.includedInBudget = includedInBudget
        self.allocationDetails = allocationDetails
        self.rawSourceJSON = rawSourceJSON
        self.isIncluded = isIncluded
        self.isSuspectedDuplicate = isSuspectedDuplicate
        self.isInternalTransfer = isInternalTransfer
        self.isInvestmentTrade = isInvestmentTrade
        self.isLoanPrincipal = isLoanPrincipal
        self.importedAt = importedAt
    }
}

@Model
final class KapiImportBatchEntity {
    var id: UUID
    var sourceScopeID: String
    var fileName: String
    var fileSHA256: String
    var coverageStart: Date
    var coverageEnd: Date
    var previousCoverageStart: Date?
    var previousCoverageEnd: Date?
    var importedAt: Date
    var appliedAt: Date
    var revertedAt: Date?
    var stateRawValue: String
    var baseVersionToken: String
    var appliedVersionToken: String
    var appliedRowsData: Data
    var replacedRowsData: Data
    var diffSummaryData: Data
    var rowCount: Int
    var incomeTotal: Double
    var expenseTotal: Double

    init(
        id: UUID = UUID(),
        sourceScopeID: String,
        fileName: String,
        fileSHA256: String,
        coverageStart: Date,
        coverageEnd: Date,
        previousCoverageStart: Date?,
        previousCoverageEnd: Date?,
        importedAt: Date,
        appliedAt: Date = .now,
        revertedAt: Date? = nil,
        stateRawValue: String = "applied",
        baseVersionToken: String,
        appliedVersionToken: String,
        appliedRowsData: Data,
        replacedRowsData: Data,
        diffSummaryData: Data,
        rowCount: Int,
        incomeTotal: Double,
        expenseTotal: Double
    ) {
        self.id = id
        self.sourceScopeID = sourceScopeID
        self.fileName = fileName
        self.fileSHA256 = fileSHA256
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.previousCoverageStart = previousCoverageStart
        self.previousCoverageEnd = previousCoverageEnd
        self.importedAt = importedAt
        self.appliedAt = appliedAt
        self.revertedAt = revertedAt
        self.stateRawValue = stateRawValue
        self.baseVersionToken = baseVersionToken
        self.appliedVersionToken = appliedVersionToken
        self.appliedRowsData = appliedRowsData
        self.replacedRowsData = replacedRowsData
        self.diffSummaryData = diffSummaryData
        self.rowCount = rowCount
        self.incomeTotal = incomeTotal
        self.expenseTotal = expenseTotal
    }
}

@Model
final class InstrumentEntity {
    var id: UUID
    var code: String?
    var name: String
    var kindRawValue: String
    var currency: String
    var normalizedIdentity: String
    var isActive: Bool
    var closedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        code: String?,
        name: String,
        kind: AssetKind,
        currency: String
    ) {
        self.id = id
        self.code = code
        self.name = name
        self.kindRawValue = kind.rawValue
        self.currency = currency
        self.normalizedIdentity = InstrumentEntity.identity(
            code: code,
            name: name,
            kind: kind,
            currency: currency
        )
        self.isActive = true
        self.closedAt = nil
        self.createdAt = .now
    }

    var kind: AssetKind {
        get { AssetKind(rawValue: kindRawValue) ?? .fund }
        set { kindRawValue = newValue.rawValue }
    }

    static func identity(
        code: String?,
        name: String,
        kind: AssetKind,
        currency: String
    ) -> String {
        if let code, !code.isEmpty {
            return "\(kind.rawValue)::\(currency.uppercased())::\(code.uppercased())"
        }
        return "\(kind.rawValue)::\(currency.uppercased())::NAME::\(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
    }
}

@Model
final class PositionSnapshotEntity {
    var id: UUID
    var assetSnapshotID: UUID
    var instrumentID: UUID
    var originalMarketValue: Double
    var cnyMarketValue: Double
    var quantity: Double?
    var unitPrice: Double?
    var capturedAt: Date
    var recognitionConfidence: Double
    var sourceCount: Int
    var wasManuallyConfirmed: Bool

    init(
        id: UUID = UUID(),
        assetSnapshotID: UUID,
        instrumentID: UUID,
        originalMarketValue: Double,
        cnyMarketValue: Double,
        quantity: Double? = nil,
        unitPrice: Double? = nil,
        capturedAt: Date,
        recognitionConfidence: Double,
        sourceCount: Int,
        wasManuallyConfirmed: Bool
    ) {
        self.id = id
        self.assetSnapshotID = assetSnapshotID
        self.instrumentID = instrumentID
        self.originalMarketValue = originalMarketValue
        self.cnyMarketValue = cnyMarketValue
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.capturedAt = capturedAt
        self.recognitionConfidence = recognitionConfidence
        self.sourceCount = sourceCount
        self.wasManuallyConfirmed = wasManuallyConfirmed
    }
}

@Model
final class AssetSnapshotEntity {
    var id: UUID
    var capturedAt: Date
    var cashCNY: Double
    var cashUSD: Double
    var cashHKD: Double
    var cashValueInCNY: Double
    var liabilityPrincipalCNY: Double
    var positionsCNY: Double
    var isComplete: Bool
    var exchangeRateStateRawValue: String
    var exchangeRateAsOf: Date?
    var exchangeRateFetchedAt: Date?
    var exchangeRateSource: String
    var usdToCNY: Double?
    var hkdToCNY: Double?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        cashCNY: Double,
        cashUSD: Double = 0,
        cashHKD: Double = 0,
        cashValueInCNY: Double,
        liabilityPrincipalCNY: Double,
        positionsCNY: Double,
        isComplete: Bool,
        exchangeRateState: ExchangeRateState,
        exchangeRateAsOf: Date?,
        exchangeRateFetchedAt: Date? = nil,
        exchangeRateSource: String = "",
        usdToCNY: Double? = nil,
        hkdToCNY: Double? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.cashCNY = cashCNY
        self.cashUSD = cashUSD
        self.cashHKD = cashHKD
        self.cashValueInCNY = cashValueInCNY
        self.liabilityPrincipalCNY = liabilityPrincipalCNY
        self.positionsCNY = positionsCNY
        self.isComplete = isComplete
        self.exchangeRateStateRawValue = exchangeRateState.rawValue
        self.exchangeRateAsOf = exchangeRateAsOf
        self.exchangeRateFetchedAt = exchangeRateFetchedAt
        self.exchangeRateSource = exchangeRateSource
        self.usdToCNY = usdToCNY
        self.hkdToCNY = hkdToCNY
        self.createdAt = .now
    }

    var investableNetWorth: Double {
        positionsCNY + cashValueInCNY - liabilityPrincipalCNY
    }
}

@Model
final class LiabilityEntity {
    var id: UUID
    var name: String
    var currency: String
    var remainingPrincipal: Double
    var cnyRemainingPrincipal: Double
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        currency: String,
        remainingPrincipal: Double,
        cnyRemainingPrincipal: Double,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.currency = currency
        self.remainingPrincipal = remainingPrincipal
        self.cnyRemainingPrincipal = cnyRemainingPrincipal
        self.updatedAt = updatedAt
    }
}

@Model
final class ExchangeRateCacheEntity {
    var cacheKey: String
    var sourceCurrency: String
    var targetCurrency: String
    var rate: Double
    var observationDate: Date
    var fetchedAt: Date
    var isManual: Bool

    init(
        sourceCurrency: String,
        targetCurrency: String = "CNY",
        rate: Double,
        observationDate: Date,
        fetchedAt: Date = .now,
        isManual: Bool = false
    ) {
        self.cacheKey = "\(sourceCurrency.uppercased())-\(targetCurrency.uppercased())"
        self.sourceCurrency = sourceCurrency.uppercased()
        self.targetCurrency = targetCurrency.uppercased()
        self.rate = rate
        self.observationDate = observationDate
        self.fetchedAt = fetchedAt
        self.isManual = isManual
    }
}

@Model
final class FIRESettingsEntity {
    var id: UUID
    var withdrawalRate: Double
    var expectedReturn: Double
    var inflation: Double
    var suggestedMonthlyContribution: Double
    var confirmedMonthlyContribution: Double?
    var contributionConfirmedAt: Date?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        withdrawalRate: Double = 0.035,
        expectedReturn: Double = 0.05,
        inflation: Double = 0.02,
        suggestedMonthlyContribution: Double = 0,
        confirmedMonthlyContribution: Double? = nil,
        contributionConfirmedAt: Date? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.withdrawalRate = withdrawalRate
        self.expectedReturn = expectedReturn
        self.inflation = inflation
        self.suggestedMonthlyContribution = suggestedMonthlyContribution
        self.confirmedMonthlyContribution = confirmedMonthlyContribution
        self.contributionConfirmedAt = contributionConfirmedAt
        self.updatedAt = updatedAt
    }
}

@Model
final class AnalysisReportEntity {
    var id: UUID
    var bridgeReportID: String
    var codexThreadID: String
    var title: String
    var reportJSON: Data
    var createdAt: Date
    var statusRawValue: String

    init(
        id: UUID = UUID(),
        bridgeReportID: String,
        codexThreadID: String,
        title: String,
        reportJSON: Data,
        createdAt: Date = .now,
        statusRawValue: String = "complete"
    ) {
        self.id = id
        self.bridgeReportID = bridgeReportID
        self.codexThreadID = codexThreadID
        self.title = title
        self.reportJSON = reportJSON
        self.createdAt = createdAt
        self.statusRawValue = statusRawValue
    }
}

@Model
final class AnalysisAnswerEntity {
    var id: UUID
    var reportID: UUID
    var question: String
    var answerJSON: Data
    var createdAt: Date

    init(
        id: UUID = UUID(),
        reportID: UUID,
        question: String,
        answerJSON: Data,
        createdAt: Date = .now
    ) {
        self.id = id
        self.reportID = reportID
        self.question = question
        self.answerJSON = answerJSON
        self.createdAt = createdAt
    }
}

@Model
final class AppMetadataEntity {
    var key: String
    var dateValue: Date?
    var stringValue: String?
    var doubleValue: Double?

    init(
        key: String,
        dateValue: Date? = nil,
        stringValue: String? = nil,
        doubleValue: Double? = nil
    ) {
        self.key = key
        self.dateValue = dateValue
        self.stringValue = stringValue
        self.doubleValue = doubleValue
    }
}

enum AppMetadataKey {
    static let confirmedAnnualBonusContribution =
        "fire.confirmedAnnualBonusContribution"
    static let plannedAnnualSpending = "fire.plannedAnnualSpending"
    static let plannedMonthlyIncome = "fire.plannedMonthlyIncome"
    static let plannedAnnualIncome = "fire.plannedAnnualIncome"
    static let plannedMonthlyExpense = "fire.plannedMonthlyExpense"
    static let plannedAnnualIrregularExpense =
        "fire.plannedAnnualIrregularExpense"
}

enum PlanAmountValue {
    static func decimal(from value: Double?) -> Decimal? {
        guard let value, value.isFinite, value >= 0,
              let decimalValue = Decimal(
                  string: String(value),
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              !decimalValue.isNaN,
              decimalValue >= 0,
              value == 0 || decimalValue > 0 else {
            return nil
        }
        return decimalValue
    }

    static func annualExpenseTotal(
        monthlyExpense: Decimal,
        annualIrregularExpense: Decimal
    ) -> Decimal? {
        var monthlyExpense = monthlyExpense
        var monthsPerYear = Decimal(12)
        var annualizedMonthlyExpense = Decimal()
        guard NSDecimalMultiply(
            &annualizedMonthlyExpense,
            &monthlyExpense,
            &monthsPerYear,
            .plain
        ) == .noError else {
            return nil
        }

        var annualIrregularExpense = annualIrregularExpense
        var total = Decimal()
        guard NSDecimalAdd(
            &total,
            &annualizedMonthlyExpense,
            &annualIrregularExpense,
            .plain
        ) == .noError,
        !total.isNaN else {
            return nil
        }
        return total
    }
}

enum PlannedAnnualSpendingValue {
    static func decimal(from value: Double?) -> Decimal? {
        guard let decimalValue = PlanAmountValue.decimal(from: value),
              decimalValue > 0 else {
            return nil
        }
        return decimalValue
    }
}

enum FIREModelSchema {
    static let models: [any PersistentModel.Type] = [
        TransactionEntity.self,
        KapiImportBatchEntity.self,
        InstrumentEntity.self,
        PositionSnapshotEntity.self,
        AssetSnapshotEntity.self,
        LiabilityEntity.self,
        ExchangeRateCacheEntity.self,
        FIRESettingsEntity.self,
        AnalysisReportEntity.self,
        AnalysisAnswerEntity.self,
        AppMetadataEntity.self
    ]
}
