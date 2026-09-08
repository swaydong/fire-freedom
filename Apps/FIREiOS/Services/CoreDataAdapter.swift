import FIRECore
import Foundation
import SwiftData

@MainActor
final class CoreDataAdapter {
    private enum MetadataKey {
        static let coverageStart = "transactions.coverage.start"
        static let coverageEnd = "transactions.coverage.end"
    }

    private struct ResolvedCashFlowPlan {
        var plannedAnnualSpending: Decimal?
        var monthlyIncome: Decimal
        var annualIncome: Decimal
        var monthlyExpense: Decimal
        var annualIrregularExpense: Decimal
        var plannedMonthlyIncome: Decimal?
        var plannedAnnualIncome: Decimal?
        var plannedMonthlyExpense: Decimal?
        var plannedAnnualIrregularExpense: Decimal?
        var monthlyContribution: Decimal?
        var annualContribution: Decimal?
    }

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func dashboard(
        transactions: [TransactionEntity],
        latestAssetSnapshot: AssetSnapshotEntity?,
        assetSnapshots: [AssetSnapshotEntity] = [],
        allPositions: [PositionSnapshotEntity],
        instruments: [InstrumentEntity],
        liabilities: [LiabilityEntity],
        settings: FIRESettingsEntity?
    ) -> DashboardSnapshot {
        let records = transactions.map(\.coreValue)
        let snapshot = coreSnapshot(
            latestAssetSnapshot,
            positions: allPositions,
            instruments: instruments,
            liabilities: liabilities,
            reconcilePositionsToFrozenTotal: true
        )
        let assumptions = FIRECore.FIREAssumptions(
            withdrawalRate: Decimal(settings?.withdrawalRate ?? 0.035),
            expectedAnnualReturn: Decimal(settings?.expectedReturn ?? 0.05),
            annualInflation: Decimal(settings?.inflation ?? 0.02)
        )
        let coverage = storedTransactionCoverage()
        let contributionReference =
            ExpenseAnalyzer.contributionHistoryReference(
                from: records,
                coverage: coverage
            )
        let expenseAnalysis = ExpenseAnalyzer.analyze(
            records,
            coverage: coverage
        )
        let plan = resolvedCashFlowPlan(
            expenseAnalysis: expenseAnalysis,
            contributionReference: contributionReference,
            settings: settings
        )
        let state = FIRECalculator.calculate(
            transactions: records,
            assetSnapshot: snapshot,
            assumptions: assumptions,
            plannedAnnualSpending: plan.plannedAnnualSpending,
            confirmedMonthlyContribution: plan.monthlyContribution,
            confirmedAnnualBonusContribution: plan.annualContribution,
            transactionCoverage: coverage
        )
        let historySnapshots: [AssetSnapshotEntity]
        if assetSnapshots.isEmpty, let latestAssetSnapshot {
            historySnapshots = [latestAssetSnapshot]
        } else {
            historySnapshots = assetSnapshots
        }
        let monthlyProgress = MonthlyProgressCalculator.calculate(
            snapshots: historySnapshots.map {
                MonthlyProgressSnapshot(
                    id: $0.id,
                    capturedAt: $0.capturedAt,
                    positionsCNY: Decimal($0.positionsCNY),
                    cashCNY: Decimal($0.cashValueInCNY),
                    liabilitiesCNY: Decimal($0.liabilityPrincipalCNY),
                    isComplete: $0.isComplete
                )
            },
            targetAmount: state.targetAmount
        )
        return DashboardSnapshot(
            investableNetWorth: state.investableNetWorth.doubleValue,
            annualExpense: state.annualSpending.doubleValue,
            plannedAnnualExpense: plan.plannedAnnualSpending?.doubleValue,
            ledgerAnnualExpense:
                state.expenseAnalysis.annualSpending.doubleValue,
            recurringAnnualizedExpense:
                state.expenseAnalysis.recurringAnnualized.doubleValue,
            irregularAnnualExpense:
                state.expenseAnalysis.irregularObservedOrRolling12
                    .doubleValue,
            monthlyIncome: plan.monthlyIncome.doubleValue,
            annualIncome: plan.annualIncome.doubleValue,
            monthlyExpense: plan.monthlyExpense.doubleValue,
            annualIrregularExpense:
                plan.annualIrregularExpense.doubleValue,
            plannedMonthlyIncome:
                plan.plannedMonthlyIncome?.doubleValue,
            plannedAnnualIncome:
                plan.plannedAnnualIncome?.doubleValue,
            plannedMonthlyExpense:
                plan.plannedMonthlyExpense?.doubleValue,
            plannedAnnualIrregularExpense:
                plan.plannedAnnualIrregularExpense?.doubleValue,
            monthlyIncomeReference: MonthlySurplusReferenceSnapshot(
                median:
                    contributionReference.monthlyStableIncome.median?
                        .doubleValue,
                latest:
                    contributionReference.monthlyStableIncome.latest?
                        .doubleValue,
                minimum:
                    contributionReference.monthlyStableIncome.minimum?
                        .doubleValue,
                maximum:
                    contributionReference.monthlyStableIncome.maximum?
                        .doubleValue,
                monthsUsed:
                    contributionReference.monthlyStableIncome.monthsUsed
            ),
            monthlyContribution:
                state.confirmedMonthlyContribution?.doubleValue ?? 0,
            annualBonusContribution:
                state.confirmedAnnualBonusContribution?.doubleValue ?? 0,
            confirmedContribution: state.confirmedMonthlyContribution != nil,
            annualBonusContributionConfirmed:
                state.confirmedAnnualBonusContribution != nil,
            suggestedMonthlyContribution:
                state.suggestedMonthlyContribution.amount?.doubleValue,
            monthlySurplusReference: MonthlySurplusReferenceSnapshot(
                median:
                    contributionReference.monthlySurplus.median?.doubleValue,
                latest:
                    contributionReference.monthlySurplus.latest?.doubleValue,
                minimum:
                    contributionReference.monthlySurplus.minimum?.doubleValue,
                maximum:
                    contributionReference.monthlySurplus.maximum?.doubleValue,
                monthsUsed:
                    contributionReference.monthlySurplus.monthsUsed
            ),
            annualBonusReference: AnnualBonusReferenceSnapshot(
                latestYear:
                    contributionReference.annualBonus.latestYear,
                latestYearTotal:
                    contributionReference.annualBonus.latestYearTotal?
                        .doubleValue,
                annualMedian:
                    contributionReference.annualBonus.annualMedian?
                        .doubleValue,
                yearsUsed:
                    contributionReference.annualBonus.yearsUsed,
                transactionCount:
                    contributionReference.annualBonus.transactionCount
            ),
            monthlyProgress: monthlyProgress,
            confidence: ConfidenceLevel(rawValue: state.confidence.rawValue) ?? .insufficient,
            observedMonths: state.expenseAnalysis.completeMonthCount,
            assumptions: FIREDisplayAssumptions(
                withdrawalRate: state.assumptions.withdrawalRate.doubleValue,
                expectedReturn: state.assumptions.expectedAnnualReturn.doubleValue,
                inflation: state.assumptions.annualInflation.doubleValue
            ),
            coreTargetAmount: state.targetAmount.doubleValue,
            coreProgress: state.progress.doubleValue,
            coreRemainingAmount: state.remainingAmount.doubleValue,
            coreEstimatedFreedomDate: state.estimatedFreedomDate,
            usesCoreCalculation: true
        )
    }

    func analysisPacket(
        transactions: [TransactionEntity],
        latestAssetSnapshot: AssetSnapshotEntity?,
        allPositions: [PositionSnapshotEntity],
        instruments: [InstrumentEntity],
        liabilities: [LiabilityEntity],
        settings: FIRESettingsEntity?,
        reportDate requestedReportDate: Date? = nil
    ) -> FIRECore.AnalysisPacketV1 {
        let allRecords = transactions.map(\.coreValue)
        let snapshot = coreSnapshot(
            latestAssetSnapshot,
            positions: allPositions,
            instruments: instruments,
            liabilities: liabilities
        )
        let calculationSnapshot = coreSnapshot(
            latestAssetSnapshot,
            positions: allPositions,
            instruments: instruments,
            liabilities: liabilities,
            reconcilePositionsToFrozenTotal: true
        )
        let reportDate = requestedReportDate
            ?? allRecords.map(\.occurredAt).max()
            ?? snapshot.capturedAt
        let recordsThroughReportMonth = records(
            allRecords,
            throughMonthContaining: reportDate
        )
        let records = rollingTwelveMonthRecords(
            recordsThroughReportMonth,
            through: reportDate
        )
        let assumptions = FIRECore.FIREAssumptions(
            withdrawalRate: Decimal(settings?.withdrawalRate ?? 0.035),
            expectedAnnualReturn: Decimal(settings?.expectedReturn ?? 0.05),
            annualInflation: Decimal(settings?.inflation ?? 0.02)
        )
        let coverage = storedTransactionCoverage(through: reportDate)
        let contributionReference =
            ExpenseAnalyzer.contributionHistoryReference(
                from: recordsThroughReportMonth,
                coverage: coverage
            )
        let expenseAnalysis = ExpenseAnalyzer.analyze(
            recordsThroughReportMonth,
            coverage: coverage
        )
        let plan = resolvedCashFlowPlan(
            expenseAnalysis: expenseAnalysis,
            contributionReference: contributionReference,
            settings: settings
        )
        let state = FIRECalculator.calculate(
            transactions: recordsThroughReportMonth,
            assetSnapshot: calculationSnapshot,
            assumptions: assumptions,
            plannedAnnualSpending: plan.plannedAnnualSpending,
            confirmedMonthlyContribution: plan.monthlyContribution,
            confirmedAnnualBonusContribution: plan.annualContribution,
            transactionCoverage: coverage,
            calculatedAt: reportDate
        )
        let monthlySummary = FIRECore.MonthlySummaryCalculator.calculate(
            transactions: recordsThroughReportMonth,
            reportDate: reportDate,
            assetSnapshot: snapshot,
            coverage: coverage
        )
        let spendingAnalysis = FIRECore.MonthlySpendingAnalyzer.analyze(
            transactions: recordsThroughReportMonth,
            reportDate: reportDate,
            coverage: coverage
        )
        let packet = FIRECore.AnalysisPacketV1(
            periodStart: records.map(\.occurredAt).min(),
            periodEnd: records.map(\.occurredAt).max(),
            transactions: records,
            assetSnapshot: snapshot,
            fireState: state,
            monthlySummary: monthlySummary,
            spendingAnalysis: spendingAnalysis
        )
        return FIRECore.PIIRedactor.redact(packet: packet)
    }

    private func storedAnnualBonusContribution(
        in metadata: [AppMetadataEntity]
    ) -> Double? {
        metadataValues(
            for: AppMetadataKey.confirmedAnnualBonusContribution,
            in: metadata
        ).first {
            PlanAmountValue.decimal(from: $0) != nil
        }
    }

    private func storedPlannedAnnualSpending(
        in metadata: [AppMetadataEntity]
    ) -> Decimal? {
        metadataValues(
            for: AppMetadataKey.plannedAnnualSpending,
            in: metadata
        )
        .compactMap(PlannedAnnualSpendingValue.decimal(from:))
        .first
    }

    private func resolvedCashFlowPlan(
        expenseAnalysis: FIRECore.ExpenseAnalysis,
        contributionReference: FIRECore.ContributionHistoryReference,
        settings: FIRESettingsEntity?
    ) -> ResolvedCashFlowPlan {
        let metadata = (
            try? context.fetch(FetchDescriptor<AppMetadataEntity>())
        ) ?? []
        let ledgerMonthlyExpense =
            expenseAnalysis.recurringAnnualized / 12
        let ledgerAnnualIrregularExpense =
            expenseAnalysis.irregularObservedOrRolling12

        let storedExpensePlan = storedPlanningPair(
            firstKey: AppMetadataKey.plannedMonthlyExpense,
            secondKey: AppMetadataKey.plannedAnnualIrregularExpense,
            in: metadata
        )
        let legacyAnnualSpending = storedPlannedAnnualSpending(in: metadata)

        let monthlyExpense: Decimal
        let annualIrregularExpense: Decimal
        let plannedMonthlyExpense: Decimal?
        let plannedAnnualIrregularExpense: Decimal?
        let plannedAnnualSpending: Decimal?

        if let storedExpensePlan,
           let annualSpending = PlanAmountValue.annualExpenseTotal(
               monthlyExpense: storedExpensePlan.first,
               annualIrregularExpense: storedExpensePlan.second
           ),
           annualSpending > 0 {
            let storedMonthlyExpense = storedExpensePlan.first
            let storedAnnualIrregularExpense = storedExpensePlan.second
            monthlyExpense = storedMonthlyExpense
            annualIrregularExpense = storedAnnualIrregularExpense
            plannedMonthlyExpense = storedMonthlyExpense
            plannedAnnualIrregularExpense = storedAnnualIrregularExpense
            plannedAnnualSpending = annualSpending
        } else if let legacyAnnualSpending {
            monthlyExpense = min(
                ledgerMonthlyExpense,
                legacyAnnualSpending / 12
            )
            annualIrregularExpense = max(
                0,
                legacyAnnualSpending - monthlyExpense * 12
            )
            plannedMonthlyExpense = monthlyExpense
            plannedAnnualIrregularExpense = annualIrregularExpense
            plannedAnnualSpending = legacyAnnualSpending
        } else {
            monthlyExpense = ledgerMonthlyExpense
            annualIrregularExpense = ledgerAnnualIrregularExpense
            plannedMonthlyExpense = nil
            plannedAnnualIrregularExpense = nil
            plannedAnnualSpending = nil
        }

        let storedIncomePlan = storedPlanningPair(
            firstKey: AppMetadataKey.plannedMonthlyIncome,
            secondKey: AppMetadataKey.plannedAnnualIncome,
            in: metadata
        )
        let legacyMonthlyContribution = settings?
            .confirmedMonthlyContribution
            .flatMap(nonnegativeDecimal)
        let legacyAnnualContribution = storedAnnualBonusContribution(
            in: metadata
        )
            .flatMap(nonnegativeDecimal)

        let monthlyIncomeReference =
            contributionReference.monthlyStableIncome.median ?? 0
        let annualIncomeReference =
            contributionReference.annualBonus.annualMedian
                ?? contributionReference.annualBonus.latestYearTotal
                ?? 0

        let monthlyIncome: Decimal
        let annualIncome: Decimal
        let plannedMonthlyIncome: Decimal?
        let plannedAnnualIncome: Decimal?
        let monthlyContribution: Decimal?
        let annualContribution: Decimal?

        if let storedIncomePlan {
            let storedMonthlyIncome = storedIncomePlan.first
            let storedAnnualIncome = storedIncomePlan.second
            monthlyIncome = storedMonthlyIncome
            annualIncome = storedAnnualIncome
            plannedMonthlyIncome = storedMonthlyIncome
            plannedAnnualIncome = storedAnnualIncome
            monthlyContribution = storedMonthlyIncome - monthlyExpense
            annualContribution =
                storedAnnualIncome - annualIrregularExpense
        } else {
            if let legacyMonthlyContribution {
                monthlyIncome = legacyMonthlyContribution + monthlyExpense
                plannedMonthlyIncome = monthlyIncome
                monthlyContribution = legacyMonthlyContribution
            } else {
                monthlyIncome = monthlyIncomeReference
                plannedMonthlyIncome = nil
                monthlyContribution = nil
            }

            if let legacyAnnualContribution {
                annualIncome =
                    legacyAnnualContribution + annualIrregularExpense
                plannedAnnualIncome = annualIncome
                annualContribution = legacyAnnualContribution
            } else {
                annualIncome = annualIncomeReference
                plannedAnnualIncome = nil
                annualContribution = nil
            }
        }

        return ResolvedCashFlowPlan(
            plannedAnnualSpending: plannedAnnualSpending,
            monthlyIncome: monthlyIncome,
            annualIncome: annualIncome,
            monthlyExpense: monthlyExpense,
            annualIrregularExpense: annualIrregularExpense,
            plannedMonthlyIncome: plannedMonthlyIncome,
            plannedAnnualIncome: plannedAnnualIncome,
            plannedMonthlyExpense: plannedMonthlyExpense,
            plannedAnnualIrregularExpense: plannedAnnualIrregularExpense,
            monthlyContribution: monthlyContribution,
            annualContribution: annualContribution
        )
    }

    private func storedPlanningPair(
        firstKey: String,
        secondKey: String,
        in metadata: [AppMetadataEntity]
    ) -> (first: Decimal, second: Decimal)? {
        let firstValues = validPlanningMetadata(
            for: firstKey,
            in: metadata
        )
        let secondValues = validPlanningMetadata(
            for: secondKey,
            in: metadata
        )
        let commonDates = Set(firstValues.compactMap(\.dateValue))
            .intersection(Set(secondValues.compactMap(\.dateValue)))
            .sorted(by: >)
        for date in commonDates {
            let firstMatches = firstValues.filter {
                $0.dateValue == date
            }
            let secondMatches = secondValues.filter {
                $0.dateValue == date
            }
            if firstMatches.count == 1, secondMatches.count == 1,
               let first = firstMatches.first,
               let second = secondMatches.first {
                return (first.value, second.value)
            }
        }
        if firstValues.count == 1,
           secondValues.count == 1,
           firstValues[0].dateValue == nil,
           secondValues[0].dateValue == nil {
            return (firstValues[0].value, secondValues[0].value)
        }
        return nil
    }

    private func validPlanningMetadata(
        for key: String,
        in metadata: [AppMetadataEntity]
    ) -> [(dateValue: Date?, value: Decimal)] {
        metadata
            .filter { $0.key == key }
            .sorted {
                ($0.dateValue ?? .distantPast)
                    > ($1.dateValue ?? .distantPast)
            }
            .compactMap { item in
                guard let value = nonnegativeDecimal(item.doubleValue) else {
                    return nil
                }
                return (item.dateValue, value)
            }
    }

    private func metadataValues(
        for key: String,
        in metadata: [AppMetadataEntity]
    ) -> [Double] {
        metadata
            .filter { $0.key == key }
            .sorted {
                ($0.dateValue ?? .distantPast)
                    > ($1.dateValue ?? .distantPast)
            }
            .compactMap(\.doubleValue)
    }

    private func nonnegativeDecimal(_ value: Double?) -> Decimal? {
        PlanAmountValue.decimal(from: value)
    }

    private func storedTransactionCoverage(
        through reportDate: Date? = nil
    ) -> FIRECore.TransactionCoverage? {
        guard let metadata = try? context.fetch(
            FetchDescriptor<AppMetadataEntity>()
        ),
        let start = metadata.first(where: {
            $0.key == MetadataKey.coverageStart
        })?.dateValue,
        let end = metadata.first(where: {
            $0.key == MetadataKey.coverageEnd
        })?.dateValue,
        start <= end else {
            return nil
        }
        guard let reportDate,
              let month = Self.reportingCalendar.dateInterval(
                of: .month,
                for: reportDate
              ),
              let reportMonthEnd = Self.reportingCalendar.date(
                byAdding: .day,
                value: -1,
                to: month.end
              ) else {
            return FIRECore.TransactionCoverage(start: start, end: end)
        }
        let clippedEnd = min(end, reportMonthEnd)
        guard start <= clippedEnd else { return nil }
        return FIRECore.TransactionCoverage(
            start: start,
            end: clippedEnd
        )
    }

    private func rollingTwelveMonthRecords(
        _ records: [FIRECore.TransactionRecord],
        through reportDate: Date
    ) -> [FIRECore.TransactionRecord] {
        let calendar = Self.reportingCalendar
        guard let reportMonth = calendar.dateInterval(
            of: .month,
            for: reportDate
        ) else {
            return records
        }
        let cutoff = calendar.date(
            byAdding: .month,
            value: -11,
            to: reportMonth.start
        ) ?? .distantPast
        return records.filter {
            $0.occurredAt >= cutoff && $0.occurredAt < reportMonth.end
        }
    }

    private func records(
        _ records: [FIRECore.TransactionRecord],
        throughMonthContaining reportDate: Date
    ) -> [FIRECore.TransactionRecord] {
        guard let month = Self.reportingCalendar.dateInterval(
            of: .month,
            for: reportDate
        ) else {
            return records.filter { $0.occurredAt <= reportDate }
        }
        return records.filter { $0.occurredAt < month.end }
    }

    private static var reportingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func coreSnapshot(
        _ snapshot: AssetSnapshotEntity?,
        positions: [PositionSnapshotEntity],
        instruments: [InstrumentEntity],
        liabilities: [LiabilityEntity],
        reconcilePositionsToFrozenTotal: Bool = false
    ) -> FIRECore.AssetSnapshot {
        guard let snapshot else {
            return FIRECore.AssetSnapshot(
                capturedAt: .now,
                positions: [],
                cashBalances: [:],
                cashValueInCNY: 0,
                liabilities: [],
                status: .draft
            )
        }
        let instrumentByID = Dictionary(uniqueKeysWithValues: instruments.map { ($0.id, $0) })
        let corePositions = positions
            .filter { $0.assetSnapshotID == snapshot.id }
            .compactMap { position -> FIRECore.PositionSnapshot? in
                guard let instrument = instrumentByID[position.instrumentID] else { return nil }
                return FIRECore.PositionSnapshot(
                    id: position.id,
                    instrument: instrument.coreValue,
                    originalMarketValue: Decimal(position.originalMarketValue),
                    marketValueInCNY: Decimal(position.cnyMarketValue),
                    quantity: position.quantity.map { Decimal($0) },
                    unitPrice: position.unitPrice.map { Decimal($0) },
                    capturedAt: position.capturedAt,
                    recognitionConfidence: position.recognitionConfidence,
                    needsConfirmation: !position.wasManuallyConfirmed
                )
            }
        let detailedPositionsTotal = corePositions.reduce(Decimal.zero) {
            $0 + $1.marketValueInCNY
        }
        let frozenPositionsTotal = Decimal(snapshot.positionsCNY)
        let positionsMatchSnapshot = abs(
            detailedPositionsTotal.doubleValue - snapshot.positionsCNY
        ) < 0.005
        let snapshotPositions: [FIRECore.PositionSnapshot]
        if positionsMatchSnapshot || !reconcilePositionsToFrozenTotal {
            snapshotPositions = corePositions
        } else if abs(snapshot.positionsCNY) >= 0.005 {
            snapshotPositions = [
                FIRECore.PositionSnapshot(
                    id: snapshot.id,
                    instrument: FIRECore.Instrument(
                        id: snapshot.id,
                        name: "快照日产品市值合计",
                        kind: .fund,
                        currency: .cny
                    ),
                    originalMarketValue: frozenPositionsTotal,
                    marketValueInCNY: frozenPositionsTotal,
                    capturedAt: snapshot.capturedAt
                ),
            ]
        } else {
            snapshotPositions = []
        }

        let currentLiabilities = liabilities.map(\.coreValue)
        let currentLiabilityTotal = liabilities.reduce(0) {
            $0 + $1.cnyRemainingPrincipal
        }
        let liabilitiesMatchSnapshot = abs(
            currentLiabilityTotal - snapshot.liabilityPrincipalCNY
        ) < 0.005
        let snapshotLiabilities: [FIRECore.Liability]
        if liabilitiesMatchSnapshot {
            snapshotLiabilities = currentLiabilities
        } else if snapshot.liabilityPrincipalCNY > 0 {
            snapshotLiabilities = [
                FIRECore.Liability(
                    name: "快照日未偿负债合计",
                    currency: .cny,
                    remainingPrincipal: Decimal(snapshot.liabilityPrincipalCNY),
                    remainingPrincipalInCNY: Decimal(snapshot.liabilityPrincipalCNY),
                    updatedAt: snapshot.capturedAt
                ),
            ]
        } else {
            snapshotLiabilities = []
        }
        var frozenRates: [String: Decimal] = ["CNY": 1]
        if let usdToCNY = snapshot.usdToCNY,
           usdToCNY.isFinite,
           usdToCNY > 0 {
            frozenRates["USD"] = Decimal(usdToCNY)
        }
        if let hkdToCNY = snapshot.hkdToCNY,
           hkdToCNY.isFinite,
           hkdToCNY > 0 {
            frozenRates["HKD"] = Decimal(hkdToCNY)
        }
        let hasFrozenExchangeRateEvidence = snapshot.exchangeRateAsOf != nil
            || snapshot.usdToCNY != nil
            || snapshot.hkdToCNY != nil
        let frozenExchangeRates = hasFrozenExchangeRateEvidence
            ? FIRECore.ExchangeRateSnapshot(
                asOf: snapshot.exchangeRateAsOf ?? snapshot.capturedAt,
                fetchedAt: snapshot.exchangeRateFetchedAt ?? snapshot.createdAt,
                cnyPerUnit: frozenRates,
                source: snapshot.exchangeRateSource.isEmpty
                    ? "快照内汇率"
                    : snapshot.exchangeRateSource,
                isStale: snapshot.exchangeRateStateRawValue
                    == ExchangeRateState.stale.rawValue
            )
            : nil

        var dataIssues: [String] = []
        if !positionsMatchSnapshot {
            dataIssues.append(
                "产品明细与资产快照不一致；FIRE 按快照日产品市值合计计算。"
            )
        }
        if !liabilitiesMatchSnapshot {
            dataIssues.append(
                "当前负债明细与资产快照不一致；FIRE 按快照日负债合计计算。"
            )
        }

        return FIRECore.AssetSnapshot(
            id: snapshot.id,
            capturedAt: snapshot.capturedAt,
            positions: snapshotPositions,
            cashBalances: [
                "CNY": Decimal(snapshot.cashCNY),
                "USD": Decimal(snapshot.cashUSD),
                "HKD": Decimal(snapshot.cashHKD),
            ],
            cashValueInCNY: Decimal(snapshot.cashValueInCNY),
            liabilities: snapshotLiabilities,
            exchangeRates: frozenExchangeRates,
            status: snapshot.isComplete ? .confirmedComplete : .needsReview,
            dataIssues: dataIssues
        )
    }
}

extension TransactionEntity {
    var coreValue: FIRECore.TransactionRecord {
        let refundClassification = [
            category,
            subcategory,
            merchant,
            note,
        ].joined(separator: " ")
        let isRefundIncome = directionRawValue.contains("收入")
            && ["退款", "退货", "返现"].contains {
                refundClassification.contains($0)
            }

        return FIRECore.TransactionRecord(
            id: id,
            occurredAt: transactionDate,
            direction: directionRawValue.contains("收入") ? .income : .expense,
            amount: Decimal(amount),
            currency: FIRECore.CurrencyCode(rawValue: currency) ?? .cny,
            primaryCategory: category,
            secondaryCategory: subcategory,
            merchantNote: merchant == note
                ? merchant
                : [merchant, note]
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
            tags: tagsJSON.flatMap {
                try? JSONDecoder().decode([String].self, from: $0)
            } ?? [],
            accountName: account,
            ledgerName: ledgerName ?? "",
            includedInCashFlow: isIncluded,
            includedInBudget: includedInBudget ?? isIncluded,
            isInternalTransfer: isInternalTransfer,
            isInvestmentTrade: isInvestmentTrade,
            isLoanPrincipal: isLoanPrincipal,
            isRefund: isRefundIncome,
            fingerprint: fingerprint,
            suspectedDuplicate: isSuspectedDuplicate,
            importRow: sourceRow
        )
    }
}

private extension InstrumentEntity {
    var coreValue: FIRECore.Instrument {
        FIRECore.Instrument(
            id: id,
            code: code,
            name: name,
            kind: FIRECore.AssetKind(rawValue: kindRawValue) ?? .fund,
            currency: FIRECore.CurrencyCode(rawValue: currency) ?? .cny
        )
    }
}

private extension LiabilityEntity {
    var coreValue: FIRECore.Liability {
        FIRECore.Liability(
            id: id,
            name: name,
            currency: FIRECore.CurrencyCode(rawValue: currency) ?? .cny,
            remainingPrincipal: Decimal(remainingPrincipal),
            remainingPrincipalInCNY: Decimal(cnyRemainingPrincipal),
            updatedAt: updatedAt
        )
    }
}
