import Foundation

public enum FIRECalculator {
    public static func calculate(
        transactions: [TransactionRecord],
        assetSnapshot: AssetSnapshot,
        assumptions: FIREAssumptions = .balanced,
        plannedAnnualSpending: Decimal? = nil,
        confirmedMonthlyContribution: Decimal? = nil,
        confirmedAnnualBonusContribution: Decimal? = nil,
        transactionCoverage: TransactionCoverage? = nil,
        calculatedAt: Date = Date()
    ) -> FIREState {
        let expenseAnalysis = ExpenseAnalyzer.analyze(
            transactions,
            coverage: transactionCoverage
        )
        let contributionSuggestion = ExpenseAnalyzer.suggestMonthlyContribution(
            from: transactions,
            coverage: transactionCoverage
        )
        let annualSpending = plannedAnnualSpending
            .flatMap { $0 > 0 ? $0 : nil }
            ?? expenseAnalysis.annualSpending
        let target = assumptions.withdrawalRate > 0
            ? (annualSpending / assumptions.withdrawalRate).rounded()
            : 0
        let netWorth = assetSnapshot.investableNetWorthInCNY.rounded()
        let remaining = max(Decimal.zero, target - netWorth).rounded()
        let progress = target > 0
            ? min(Decimal(1), max(Decimal.zero, netWorth / target))
            : 0

        let estimate = estimatedDate(
            currentNetWorth: netWorth,
            target: target,
            monthlyContribution: confirmedMonthlyContribution,
            annualBonusContribution: confirmedAnnualBonusContribution,
            assumptions: assumptions,
            from: calculatedAt
        )

        return FIREState(
            calculatedAt: calculatedAt,
            investableNetWorth: netWorth,
            annualSpending: annualSpending,
            targetAmount: target,
            progress: progress,
            remainingAmount: remaining,
            confirmedMonthlyContribution: confirmedMonthlyContribution,
            confirmedAnnualBonusContribution:
                confirmedAnnualBonusContribution,
            suggestedMonthlyContribution: contributionSuggestion,
            estimatedFreedomDate: estimate.date,
            estimatedMonthsRemaining: estimate.months,
            confidence: expenseAnalysis.confidence,
            assumptions: assumptions,
            expenseAnalysis: expenseAnalysis
        )
    }

    private static func estimatedDate(
        currentNetWorth: Decimal,
        target: Decimal,
        monthlyContribution: Decimal?,
        annualBonusContribution: Decimal?,
        assumptions: FIREAssumptions,
        from date: Date
    ) -> (date: Date?, months: Int?) {
        guard target > 0 else { return (nil, nil) }
        if currentNetWorth >= target {
            return (date, 0)
        }
        guard monthlyContribution != nil || annualBonusContribution != nil else {
            return (nil, nil)
        }

        let nominalReturn = assumptions.expectedAnnualReturn.doubleValue
        let inflation = assumptions.annualInflation.doubleValue
        guard nominalReturn.isFinite,
              inflation.isFinite,
              nominalReturn > -1,
              inflation > -1 else {
            return (nil, nil)
        }
        let realAnnualReturn = (1 + nominalReturn) / (1 + inflation) - 1
        let monthlyRate = pow(1 + realAnnualReturn, 1 / 12) - 1
        let targetValue = target.doubleValue
        var projectedValue = currentNetWorth.doubleValue
        let contribution = monthlyContribution?.doubleValue ?? 0
        let annualBonus = annualBonusContribution?.doubleValue ?? 0
        guard monthlyRate.isFinite,
              targetValue.isFinite,
              projectedValue.isFinite,
              contribution.isFinite,
              annualBonus.isFinite else {
            return (nil, nil)
        }

        for month in 1...1_200 {
            projectedValue = projectedValue * (1 + monthlyRate) + contribution
            if month.isMultiple(of: 12) {
                projectedValue += annualBonus
            }
            guard projectedValue.isFinite else {
                return (nil, nil)
            }
            if projectedValue >= targetValue {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
                return (
                    calendar.date(byAdding: .month, value: month, to: date),
                    month
                )
            }
        }
        return (nil, nil)
    }
}

public struct PositionMergeSuggestion: Codable, Equatable, Sendable {
    public var leftPositionID: UUID
    public var rightPositionID: UUID
    public var reason: String

    public init(leftPositionID: UUID, rightPositionID: UUID, reason: String) {
        self.leftPositionID = leftPositionID
        self.rightPositionID = rightPositionID
        self.reason = reason
    }
}

public enum PositionAggregator {
    public static func aggregate(_ positions: [PositionSnapshot]) -> [PositionSnapshot] {
        let grouped = Dictionary(grouping: positions, by: aggregationKey)
        return grouped.values
            .map(aggregateGroup)
            .sorted {
                if $0.instrument.kind != $1.instrument.kind {
                    return $0.instrument.kind.rawValue < $1.instrument.kind.rawValue
                }
                return $0.instrument.name.localizedStandardCompare($1.instrument.name)
                    == .orderedAscending
            }
    }

    public static func nameMatchSuggestions(
        in positions: [PositionSnapshot]
    ) -> [PositionMergeSuggestion] {
        let noCode = positions.filter { $0.instrument.code == nil }
        var suggestions: [PositionMergeSuggestion] = []
        for leftIndex in noCode.indices {
            for rightIndex in noCode.indices where rightIndex > leftIndex {
                let left = noCode[leftIndex]
                let right = noCode[rightIndex]
                guard left.instrument.id != right.instrument.id,
                      normalizedName(left.instrument.name) == normalizedName(right.instrument.name),
                      left.instrument.kind == right.instrument.kind,
                      left.instrument.currency == right.instrument.currency
                else {
                    continue
                }
                suggestions.append(
                    PositionMergeSuggestion(
                        leftPositionID: left.id,
                        rightPositionID: right.id,
                        reason: "产品名称相同但缺少代码，需人工确认是否为同一产品。"
                    )
                )
            }
        }
        return suggestions
    }

    private static func aggregationKey(_ position: PositionSnapshot) -> String {
        if let code = position.instrument.code?.trimmedNilIfEmpty {
            return [
                "code",
                position.instrument.kind.rawValue,
                position.instrument.currency.rawValue,
                code.uppercased(),
            ].joined(separator: "|")
        }
        return "confirmed-id|\(position.instrument.id.uuidString)"
    }

    private static func aggregateGroup(_ group: [PositionSnapshot]) -> PositionSnapshot {
        guard let first = group.first else {
            preconditionFailure("Position groups must never be empty.")
        }
        guard group.count > 1 else { return first }

        var result = first
        result.originalMarketValue = group.reduce(0) { $0 + $1.originalMarketValue }
        result.marketValueInCNY = group.reduce(0) { $0 + $1.marketValueInCNY }
        result.quantity = group.compactMap(\.quantity).count == group.count
            ? group.compactMap(\.quantity).reduce(0, +)
            : nil
        result.unitPrice = nil
        result.recognitionConfidence = group.map(\.recognitionConfidence).min() ?? 0
        result.needsConfirmation = group.contains(where: \.needsConfirmation)
        result.sourceImportID = nil
        return result
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

public enum SnapshotReconciler {
    public static func closedInstrumentIDs(
        previous: AssetSnapshot,
        current: AssetSnapshot
    ) -> [UUID] {
        guard current.status == .confirmedComplete else { return [] }
        let currentKeys = Set(current.positions.map(instrumentKey))
        return previous.positions.compactMap { position in
            currentKeys.contains(instrumentKey(position)) ? nil : position.instrument.id
        }
    }

    private static func instrumentKey(_ position: PositionSnapshot) -> String {
        if let code = position.instrument.code?.trimmedNilIfEmpty {
            return [
                position.instrument.kind.rawValue,
                position.instrument.currency.rawValue,
                code.uppercased(),
            ].joined(separator: "|")
        }
        return position.instrument.id.uuidString
    }
}
