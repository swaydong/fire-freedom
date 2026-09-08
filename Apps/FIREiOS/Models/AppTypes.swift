import FIRECore
import Foundation

enum AssetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case fund
    case stock
    case option
    case cash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fund: "基金"
        case .stock: "股票"
        case .option: "期权"
        case .cash: "现金"
        }
    }

    var systemImage: String {
        switch self {
        case .fund: "chart.pie.fill"
        case .stock: "chart.line.uptrend.xyaxis"
        case .option: "doc.text.magnifyingglass"
        case .cash: "banknote.fill"
        }
    }
}

enum ConfidenceLevel: String, Codable, CaseIterable, Sendable {
    case insufficient
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .insufficient: "数据不足"
        case .low: "低可信度"
        case .medium: "中可信度"
        case .high: "高可信度"
        }
    }

    var explanation: String {
        switch self {
        case .insufficient: "完整账单不足 3 个月，当前进度仅供预览。"
        case .low: "基于 3–5 个完整月，季节性支出可能尚未出现。"
        case .medium: "基于 6–11 个完整月，已能反映大部分日常开支。"
        case .high: "基于至少 12 个月，并纳入滚动年度不规则支出。"
        }
    }
}

enum ExchangeRateState: String, Codable, Sendable {
    case current
    case stale
    case manual
    case missing

    var displayName: String {
        switch self {
        case .current: "ECB 已更新"
        case .stale: "使用过期缓存"
        case .manual: "使用手动汇率"
        case .missing: "缺少汇率"
        }
    }
}

struct MonthlySurplusReferenceSnapshot: Equatable, Sendable {
    var median: Double?
    var latest: Double?
    var minimum: Double?
    var maximum: Double?
    var monthsUsed: Int

    static let empty = MonthlySurplusReferenceSnapshot(
        median: nil,
        latest: nil,
        minimum: nil,
        maximum: nil,
        monthsUsed: 0
    )
}

struct AnnualBonusReferenceSnapshot: Equatable, Sendable {
    var latestYear: Int?
    var latestYearTotal: Double?
    var annualMedian: Double?
    var yearsUsed: Int
    var transactionCount: Int

    static let empty = AnnualBonusReferenceSnapshot(
        latestYear: nil,
        latestYearTotal: nil,
        annualMedian: nil,
        yearsUsed: 0,
        transactionCount: 0
    )
}

struct DashboardSnapshot: Sendable {
    var investableNetWorth: Double
    var annualExpense: Double
    var plannedAnnualExpense: Double? = nil
    var ledgerAnnualExpense: Double = 0
    var recurringAnnualizedExpense: Double = 0
    var irregularAnnualExpense: Double = 0
    var monthlyIncome: Double = 0
    var annualIncome: Double = 0
    var monthlyExpense: Double = 0
    var annualIrregularExpense: Double = 0
    var plannedMonthlyIncome: Double? = nil
    var plannedAnnualIncome: Double? = nil
    var plannedMonthlyExpense: Double? = nil
    var plannedAnnualIrregularExpense: Double? = nil
    var monthlyIncomeReference: MonthlySurplusReferenceSnapshot = .empty
    var monthlyContribution: Double
    var annualBonusContribution: Double = 0
    var confirmedContribution: Bool
    var annualBonusContributionConfirmed: Bool = false
    var suggestedMonthlyContribution: Double? = nil
    var monthlySurplusReference: MonthlySurplusReferenceSnapshot = .empty
    var annualBonusReference: AnnualBonusReferenceSnapshot = .empty
    var monthlyProgress: [MonthlyProgressPoint] = []
    var confidence: ConfidenceLevel
    var observedMonths: Int
    var assumptions: FIREDisplayAssumptions
    var coreTargetAmount: Double? = nil
    var coreProgress: Double? = nil
    var coreRemainingAmount: Double? = nil
    var coreEstimatedFreedomDate: Date? = nil
    var usesCoreCalculation: Bool = false

    static let empty = DashboardSnapshot(
        investableNetWorth: 0,
        annualExpense: 0,
        plannedAnnualExpense: nil,
        ledgerAnnualExpense: 0,
        recurringAnnualizedExpense: 0,
        irregularAnnualExpense: 0,
        monthlyIncome: 0,
        annualIncome: 0,
        monthlyExpense: 0,
        annualIrregularExpense: 0,
        plannedMonthlyIncome: nil,
        plannedAnnualIncome: nil,
        plannedMonthlyExpense: nil,
        plannedAnnualIrregularExpense: nil,
        monthlyIncomeReference: .empty,
        monthlyContribution: 0,
        annualBonusContribution: 0,
        confirmedContribution: false,
        annualBonusContributionConfirmed: false,
        suggestedMonthlyContribution: nil,
        monthlySurplusReference: .empty,
        annualBonusReference: .empty,
        confidence: .insufficient,
        observedMonths: 0,
        assumptions: .defaults,
        coreTargetAmount: nil,
        coreProgress: nil,
        coreRemainingAmount: nil,
        coreEstimatedFreedomDate: nil,
        usesCoreCalculation: false
    )

    var hasManualIncomePlan: Bool {
        plannedMonthlyIncome != nil || plannedAnnualIncome != nil
    }

    var hasManualExpensePlan: Bool {
        plannedMonthlyExpense != nil
            || plannedAnnualIrregularExpense != nil
            || plannedAnnualExpense != nil
    }

    var annualPlannedIncome: Double {
        monthlyIncome * 12 + annualIncome
    }

    var annualPlannedOutflow: Double {
        monthlyExpense * 12 + annualIrregularExpense
    }

    var annualPlannedContribution: Double? {
        guard confirmedContribution || annualBonusContributionConfirmed else {
            return nil
        }
        let monthlyPlan = confirmedContribution ? monthlyContribution : 0
        let annualPlan = annualBonusContributionConfirmed
            ? annualBonusContribution
            : 0
        guard monthlyPlan.isFinite, annualPlan.isFinite else {
            return nil
        }
        return monthlyPlan * 12 + annualPlan
    }

    func target(withdrawalRate: Double) -> Double {
        if usesCoreCalculation, let coreTargetAmount {
            return coreTargetAmount
        }
        guard withdrawalRate > 0 else { return 0 }
        return annualExpense / withdrawalRate
    }

    func progress(withdrawalRate: Double) -> Double {
        if usesCoreCalculation, let coreProgress {
            return coreProgress
        }
        let target = target(withdrawalRate: withdrawalRate)
        guard target > 0 else { return 0 }
        return min(max(investableNetWorth / target, 0), 1)
    }

    func remaining(withdrawalRate: Double) -> Double {
        if usesCoreCalculation, let coreRemainingAmount {
            return coreRemainingAmount
        }
        return max(
            target(withdrawalRate: withdrawalRate) - investableNetWorth,
            0
        )
    }

    func estimatedDate(withdrawalRate: Double, now: Date = .now) -> Date? {
        if usesCoreCalculation {
            return coreEstimatedFreedomDate
        }
        let goal = target(withdrawalRate: withdrawalRate)
        guard goal > 0 else { return nil }
        if investableNetWorth >= goal { return now }
        guard confirmedContribution || annualBonusContributionConfirmed else {
            return nil
        }
        let monthlyPlan = confirmedContribution ? monthlyContribution : 0
        let annualBonusPlan = annualBonusContributionConfirmed
            ? annualBonusContribution
            : 0
        guard monthlyPlan.isFinite, annualBonusPlan.isFinite else {
            return nil
        }
        guard assumptions.expectedReturn.isFinite,
              assumptions.inflation.isFinite,
              assumptions.expectedReturn > -1,
              assumptions.inflation > -1 else {
            return nil
        }

        let monthlyRealReturn = pow(
            (1 + assumptions.expectedReturn) / (1 + assumptions.inflation),
            1.0 / 12.0
        ) - 1
        guard monthlyRealReturn.isFinite, monthlyRealReturn > -1 else {
            return nil
        }
        var balance = investableNetWorth

        for month in 1...1_200 {
            balance = balance * (1 + monthlyRealReturn) + monthlyPlan
            if month.isMultiple(of: 12) {
                balance += annualBonusPlan
            }
            guard balance.isFinite else { return nil }
            if balance >= goal {
                return Calendar.current.date(byAdding: .month, value: month, to: now)
            }
        }
        return nil
    }
}

struct FIREDisplayAssumptions: Codable, Sendable {
    var withdrawalRate: Double
    var expectedReturn: Double
    var inflation: Double

    static let defaults = FIREDisplayAssumptions(
        withdrawalRate: 0.035,
        expectedReturn: 0.05,
        inflation: 0.02
    )
}

enum AssetProductVerification: String, Codable, Sendable {
    case verified
    case manual
    case ambiguous
    case notFound
    case unavailable
    case notApplicable
    case localOnly
}

struct OCRPositionCandidate: Identifiable, Hashable, Sendable {
    let id: UUID
    var sourceImageIndex: Int
    var productName: String
    var productCode: String?
    var kind: AssetKind
    var currency: String
    var originalMarketValue: Double
    var confidence: Double
    var requiresMergeConfirmation: Bool
    var rawEvidence: String
    var verification: AssetProductVerification

    init(
        id: UUID = UUID(),
        sourceImageIndex: Int,
        productName: String,
        productCode: String? = nil,
        kind: AssetKind = .fund,
        currency: String = "CNY",
        originalMarketValue: Double,
        confidence: Double,
        requiresMergeConfirmation: Bool,
        rawEvidence: String,
        verification: AssetProductVerification = .localOnly
    ) {
        self.id = id
        self.sourceImageIndex = sourceImageIndex
        self.productName = productName
        self.productCode = productCode
        self.kind = kind
        self.currency = currency
        self.originalMarketValue = originalMarketValue
        self.confidence = confidence
        self.requiresMergeConfirmation = requiresMergeConfirmation
        self.rawEvidence = rawEvidence
        self.verification = verification
    }
}

enum AssetRecognitionState: Equatable, Sendable {
    case idle
    case recognizing
    case awaitingBridgeDecision
    case valid
    case invalid
}

enum UncodedPositionResolution: Equatable, Sendable {
    case existingInstrument(UUID)
    case createNewInstrument
    case batchCanonical(String)
}

struct AggregatedPosition: Identifiable, Sendable {
    let id: String
    let code: String?
    let name: String
    let kind: AssetKind
    let currency: String
    let originalMarketValue: Double
    let sourceCount: Int
    let confidence: Double
    let requiresConfirmation: Bool
    let verification: AssetProductVerification
    let candidateIDs: [UUID]

    init(
        id: String,
        code: String?,
        name: String,
        kind: AssetKind,
        currency: String,
        originalMarketValue: Double,
        sourceCount: Int,
        confidence: Double,
        requiresConfirmation: Bool,
        verification: AssetProductVerification = .localOnly,
        candidateIDs: [UUID] = []
    ) {
        self.id = id
        self.code = code
        self.name = name
        self.kind = kind
        self.currency = currency
        self.originalMarketValue = originalMarketValue
        self.sourceCount = sourceCount
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
        self.verification = verification
        self.candidateIDs = candidateIDs
    }
}

struct ImportSummary: Sendable {
    let importedCount: Int
    let duplicateCount: Int
    let firstDate: Date?
    let lastDate: Date?
    let incomeTotal: Double
    let expenseTotal: Double
    let coverageWarning: String?
}

struct KapiSyncPreview: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let fileSHA256: String
    let coverage: FIRECore.TransactionCoverage
    let importedAt: Date
    let baselineVersionToken: String
    let incomingItems: [FIRECore.KapiSnapshotItem]
    let reconciliation: FIRECore.KapiSnapshotReconciliation
    let legacyUpgradeCount: Int
    let previousIncomeTotal: Double
    let previousExpenseTotal: Double
    let incomingIncomeTotal: Double
    let incomingExpenseTotal: Double

    var duplicateMultiplicityChanges:
        [FIRECore.KapiSnapshotMultiplicityChange] {
        reconciliation.multiplicityChanges.filter {
            $0.previousCount > 1 || $0.incomingCount > 1
        }
    }

    func representative(
        for change: FIRECore.KapiSnapshotMultiplicityChange
    ) -> FIRECore.KapiSnapshotItem? {
        incomingItems.first {
            $0.semanticFingerprint == change.semanticFingerprint
        } ?? reconciliation.removed.first {
            $0.semanticFingerprint == change.semanticFingerprint
        }
    }
}

struct KapiSyncReceipt: Sendable {
    let batchID: UUID
    let coverage: FIRECore.TransactionCoverage
    let appliedAt: Date
    let unchangedCount: Int
    let addedCount: Int
    let removedCount: Int
    let isReverted: Bool

    var canUndo: Bool { !isReverted }
}

extension Double {
    var cnyText: String {
        formatted(
            .currency(code: "CNY")
                .precision(.fractionLength(0))
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    var percentText: String {
        formatted(.percent.precision(.fractionLength(1)))
    }
}
