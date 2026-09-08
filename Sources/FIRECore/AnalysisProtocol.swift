import Foundation

public struct MonthlyFinancialSummaryV1: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var periodStart: Date
    public var periodEnd: Date
    public var isCompleteMonth: Bool
    public var transactionCount: Int
    public var income: Decimal
    public var livingExpense: Decimal
    public var refundIncome: Decimal?
    public var netCashFlow: Decimal
    public var assetSnapshotDate: Date
    public var fundValue: Decimal
    public var stockValue: Decimal
    public var optionValue: Decimal?
    public var cashValue: Decimal
    public var totalAssets: Decimal
    public var liabilities: Decimal
    public var investableNetWorth: Decimal

    public init(
        schemaVersion: String = "1.0",
        periodStart: Date,
        periodEnd: Date,
        isCompleteMonth: Bool,
        transactionCount: Int,
        income: Decimal,
        livingExpense: Decimal,
        refundIncome: Decimal? = nil,
        netCashFlow: Decimal,
        assetSnapshotDate: Date,
        fundValue: Decimal,
        stockValue: Decimal,
        optionValue: Decimal? = nil,
        cashValue: Decimal,
        totalAssets: Decimal,
        liabilities: Decimal,
        investableNetWorth: Decimal
    ) {
        self.schemaVersion = schemaVersion
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.isCompleteMonth = isCompleteMonth
        self.transactionCount = transactionCount
        self.income = income
        self.livingExpense = livingExpense
        self.refundIncome = refundIncome
        self.netCashFlow = netCashFlow
        self.assetSnapshotDate = assetSnapshotDate
        self.fundValue = fundValue
        self.stockValue = stockValue
        self.optionValue = optionValue
        self.cashValue = cashValue
        self.totalAssets = totalAssets
        self.liabilities = liabilities
        self.investableNetWorth = investableNetWorth
    }
}

public struct AnalysisPacketV1: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var generatedAt: Date
    public var periodStart: Date?
    public var periodEnd: Date?
    public var transactions: [TransactionRecord]
    public var assetSnapshot: AssetSnapshot
    public var fireState: FIREState
    public var monthlySummary: MonthlyFinancialSummaryV1?
    public var spendingAnalysis: MonthlySpendingAnalysisV1?

    public init(
        schemaVersion: String = "1.0",
        generatedAt: Date = Date(),
        periodStart: Date?,
        periodEnd: Date?,
        transactions: [TransactionRecord],
        assetSnapshot: AssetSnapshot,
        fireState: FIREState,
        monthlySummary: MonthlyFinancialSummaryV1? = nil,
        spendingAnalysis: MonthlySpendingAnalysisV1? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.transactions = transactions
        self.assetSnapshot = assetSnapshot
        self.fireState = fireState
        self.monthlySummary = monthlySummary
        self.spendingAnalysis = spendingAnalysis
    }
}

public extension AnalysisPacketV1 {
    /// Produces the privacy-safe, deterministic representation used to decide
    /// whether two attempts belong to the same report operation.
    func normalizedForOperationFingerprint() -> AnalysisPacketV1 {
        var normalized = self

        // Make duplicate-reference redaction deterministic before it chooses a
        // representative transaction for each source fingerprint.
        normalized.transactions = normalized.transactions
            .map { transaction in
                var transaction = transaction
                transaction.tags.sort()
                return transaction
            }
            .sorted {
                $0.id.uuidString.lowercased()
                    < $1.id.uuidString.lowercased()
            }
        normalized = PIIRedactor.redact(packet: normalized)

        normalized.generatedAt = operationFingerprintReferenceDate
        normalized.fireState.calculatedAt = operationFingerprintReferenceDate
        normalized.fireState.estimatedFreedomDate = nil

        normalized.assetSnapshot.id = operationFingerprintZeroUUID
        let snapshotDate = normalized.assetSnapshot.capturedAt
        normalized.assetSnapshot.positions = normalized.assetSnapshot.positions
            .map { position in
                var position = position
                position.id = operationFingerprintZeroUUID
                position.instrument.id = operationFingerprintZeroUUID
                position.capturedAt = snapshotDate
                return position
            }
            .sortedForOperationFingerprint()
        normalized.assetSnapshot.liabilities =
            normalized.assetSnapshot.liabilities
                .map { liability in
                    var liability = liability
                    liability.id = operationFingerprintZeroUUID
                    liability.updatedAt = operationFingerprintReferenceDate
                    return liability
                }
                .sortedForOperationFingerprint()
        if var exchangeRates = normalized.assetSnapshot.exchangeRates {
            exchangeRates.fetchedAt = operationFingerprintReferenceDate
            normalized.assetSnapshot.exchangeRates = exchangeRates
        }
        normalized.assetSnapshot.dataIssues.sort()
        normalized.transactions = normalized.transactions
            .map { transaction in
                var transaction = transaction
                transaction.tags.sort()
                return transaction
            }
            .sortedForOperationFingerprint()
        return normalized
    }
}

private let operationFingerprintReferenceDate = Date(timeIntervalSince1970: 0)
private let operationFingerprintZeroUUID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
)

private extension Array where Element: Encodable {
    func sortedForOperationFingerprint() -> [Element] {
        map { value in
            (key: operationFingerprintSortKey(value), value: value)
        }
        .sorted { lhs, rhs in
            lhs.key.lexicographicallyPrecedes(rhs.key)
        }
        .map(\.value)
    }
}

private func operationFingerprintSortKey<Value: Encodable>(
    _ value: Value
) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)) ?? Data()
}

public struct AnalysisEvidenceV1: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var value: String
    public var transactionFingerprints: [String]

    public init(
        id: String,
        label: String,
        value: String,
        transactionFingerprints: [String] = []
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.transactionFingerprints = transactionFingerprints
    }
}

public struct AnalysisFindingV1: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var evidenceRefs: [String]

    public init(title: String, detail: String, evidenceRefs: [String]) {
        self.title = title
        self.detail = detail
        self.evidenceRefs = evidenceRefs
    }
}

public struct AnalysisConfidenceV1: Codable, Equatable, Sendable {
    public var level: DataConfidence
    public var explanation: String
    public var evidenceRefs: [String]

    public init(
        level: DataConfidence,
        explanation: String,
        evidenceRefs: [String] = []
    ) {
        self.level = level
        self.explanation = explanation
        self.evidenceRefs = evidenceRefs
    }
}

public struct AnalysisActionV1: Codable, Equatable, Sendable {
    public var title: String
    public var rationale: String
    public var evidenceRefs: [String]

    public init(title: String, rationale: String, evidenceRefs: [String]) {
        self.title = title
        self.rationale = rationale
        self.evidenceRefs = evidenceRefs
    }
}

public struct AnalysisReportV1: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var coreConclusion: String
    public var dataConfidence: AnalysisConfidenceV1
    public var spendingFindings: [AnalysisFindingV1]
    public var assetStructureRisks: [AnalysisFindingV1]
    public var fireDrivers: [AnalysisFindingV1]
    public var actions: [AnalysisActionV1]
    public var evidence: [AnalysisEvidenceV1]
    public var limitations: [String]
    public var monthlySummary: MonthlyFinancialSummaryV1?
    public var spendingAnalysis: MonthlySpendingAnalysisV1?

    public init(
        schemaVersion: String = "1.0",
        coreConclusion: String,
        dataConfidence: AnalysisConfidenceV1,
        spendingFindings: [AnalysisFindingV1],
        assetStructureRisks: [AnalysisFindingV1],
        fireDrivers: [AnalysisFindingV1],
        actions: [AnalysisActionV1],
        evidence: [AnalysisEvidenceV1],
        limitations: [String],
        monthlySummary: MonthlyFinancialSummaryV1? = nil,
        spendingAnalysis: MonthlySpendingAnalysisV1? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.coreConclusion = coreConclusion
        self.dataConfidence = dataConfidence
        self.spendingFindings = spendingFindings
        self.assetStructureRisks = assetStructureRisks
        self.fireDrivers = fireDrivers
        self.actions = actions
        self.evidence = evidence
        self.limitations = limitations
        self.monthlySummary = monthlySummary
        self.spendingAnalysis = spendingAnalysis
    }

    public func validate() throws {
        guard schemaVersion == "1.0" else {
            throw AnalysisSchemaError.unsupportedVersion(schemaVersion)
        }
        guard (1...3).contains(actions.count) else {
            throw AnalysisSchemaError.invalidActionCount(actions.count)
        }
        guard !evidence.isEmpty else {
            throw AnalysisSchemaError.missingEvidence
        }
        let evidenceIDs = evidence.map(\.id)
        let duplicateEvidenceIDs = Dictionary(grouping: evidenceIDs, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        guard duplicateEvidenceIDs.isEmpty else {
            throw AnalysisSchemaError.duplicateEvidenceIDs(duplicateEvidenceIDs)
        }

        var requiredReferenceGroups: [(field: String, references: [String])] = [
            ("dataConfidence", dataConfidence.evidenceRefs),
        ]
        requiredReferenceGroups.append(
            contentsOf: spendingFindings.enumerated().map {
                ("spendingFindings[\($0.offset)]", $0.element.evidenceRefs)
            }
        )
        requiredReferenceGroups.append(
            contentsOf: assetStructureRisks.enumerated().map {
                ("assetStructureRisks[\($0.offset)]", $0.element.evidenceRefs)
            }
        )
        requiredReferenceGroups.append(
            contentsOf: fireDrivers.enumerated().map {
                ("fireDrivers[\($0.offset)]", $0.element.evidenceRefs)
            }
        )
        requiredReferenceGroups.append(
            contentsOf: actions.enumerated().map {
                ("actions[\($0.offset)]", $0.element.evidenceRefs)
            }
        )
        let emptyReferenceFields = requiredReferenceGroups.compactMap {
            $0.references.isEmpty ? $0.field : nil
        }
        guard emptyReferenceFields.isEmpty else {
            throw AnalysisSchemaError.emptyEvidenceReferences(emptyReferenceFields)
        }

        let validEvidence = Set(evidence.map(\.id))
        let references = dataConfidence.evidenceRefs
            + spendingFindings.flatMap(\.evidenceRefs)
            + assetStructureRisks.flatMap(\.evidenceRefs)
            + fireDrivers.flatMap(\.evidenceRefs)
            + actions.flatMap(\.evidenceRefs)
        let missing = Set(references).subtracting(validEvidence)
        guard missing.isEmpty else {
            throw AnalysisSchemaError.missingEvidenceReferences(missing.sorted())
        }
    }
}

public struct AnalysisAnswerV1: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var answer: String
    public var evidenceRefs: [String]
    public var limitations: [String]
    public var refusedInvestmentInstruction: Bool

    public init(
        schemaVersion: String = "1.0",
        answer: String,
        evidenceRefs: [String],
        limitations: [String],
        refusedInvestmentInstruction: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.answer = answer
        self.evidenceRefs = evidenceRefs
        self.limitations = limitations
        self.refusedInvestmentInstruction = refusedInvestmentInstruction
    }
}

public enum AnalysisSchemaError: Error, Equatable, Sendable {
    case unsupportedVersion(String)
    case invalidActionCount(Int)
    case missingEvidence
    case duplicateEvidenceIDs([String])
    case emptyEvidenceReferences([String])
    case missingEvidenceReferences([String])
}
