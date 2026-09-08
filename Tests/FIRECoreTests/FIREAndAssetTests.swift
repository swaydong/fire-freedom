import FIRECore
import Foundation
import XCTest

final class FIREAndAssetTests: XCTestCase {
    func testNetWorthDeductsLiabilitiesAndIncludesAllCash() {
        let fund = Instrument(
            code: "000001",
            name: "示例基金",
            kind: .fund,
            currency: .cny
        )
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 4, 30),
            positions: [
                PositionSnapshot(
                    instrument: fund,
                    originalMarketValue: 40_000,
                    marketValueInCNY: 40_000,
                    capturedAt: testDate(2026, 4, 30)
                ),
            ],
            cashBalances: ["CNY": 20_000],
            cashValueInCNY: 20_000,
            liabilities: [
                Liability(
                    name: "房贷",
                    currency: .cny,
                    remainingPrincipal: 10_000,
                    remainingPrincipalInCNY: 10_000,
                    updatedAt: testDate(2026, 4, 30)
                ),
            ],
            status: .confirmedComplete
        )

        XCTAssertEqual(snapshot.investedAssetsInCNY, 40_000)
        XCTAssertEqual(snapshot.totalCashInCNY, 20_000)
        XCTAssertEqual(snapshot.outstandingLiabilitiesInCNY, 10_000)
        XCTAssertEqual(snapshot.investableNetWorthInCNY, 50_000)
    }

    func testCashPositionCountsWhenSeparateCashSummaryIsUnavailable() {
        let cash = Instrument(name: "现金", kind: .cash, currency: .cny)
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 4, 30),
            positions: [
                PositionSnapshot(
                    instrument: cash,
                    originalMarketValue: 2_000,
                    marketValueInCNY: 2_000,
                    capturedAt: testDate(2026, 4, 30)
                ),
            ],
            status: .confirmedComplete
        )

        XCTAssertEqual(snapshot.totalCashInCNY, 2_000)
        XCTAssertEqual(snapshot.investableNetWorthInCNY, 2_000)
    }

    func testOptionCountsInNetWorthAndMonthlyAssetSummary() {
        let option = Instrument(
            name: "公司期权",
            kind: .option,
            currency: .cny
        )
        let capturedAt = testDate(2026, 4, 30)
        let snapshot = AssetSnapshot(
            capturedAt: capturedAt,
            positions: [
                PositionSnapshot(
                    instrument: option,
                    originalMarketValue: 80_000,
                    marketValueInCNY: 80_000,
                    capturedAt: capturedAt
                ),
            ],
            status: .confirmedComplete
        )

        let summary = MonthlySummaryCalculator.calculate(
            transactions: [],
            reportDate: capturedAt,
            assetSnapshot: snapshot
        )

        XCTAssertEqual(snapshot.investableNetWorthInCNY, 80_000)
        XCTAssertEqual(summary.optionValue, 80_000)
        XCTAssertEqual(summary.totalAssets, 80_000)
        XCTAssertEqual(summary.investableNetWorth, 80_000)
    }

    func testExchangeRateSnapshotConvertsSupportedCurrenciesAndBlocksMissingRate() {
        let rates = ExchangeRateSnapshot(
            asOf: testDate(2026, 4, 30),
            cnyPerUnit: [
                "CNY": 1,
                "USD": Decimal(string: "7.2")!,
                "HKD": Decimal(string: "0.92")!,
            ]
        )

        XCTAssertEqual(rates.convertedToCNY(100, currency: .cny), 100)
        XCTAssertEqual(rates.convertedToCNY(100, currency: .usd), 720)
        XCTAssertEqual(rates.convertedToCNY(100, currency: .hkd), 92)

        var missing = rates
        missing.cnyPerUnit["USD"] = nil
        XCTAssertNil(missing.convertedToCNY(100, currency: .usd))
    }

    func testFIRECalculationUsesWithdrawalRateAndConfirmedContribution() {
        var records: [TransactionRecord] = [
            transaction(date: testDate(2026, 1, 1), amount: 1_000),
            transaction(date: testDate(2026, 2, 1), amount: 1_000),
            transaction(date: testDate(2026, 3, 1), amount: 1_000),
            transaction(date: testDate(2026, 4, 1), amount: 1_000),
            transaction(
                date: testDate(2026, 4, 30),
                amount: 0,
                internalTransfer: true
            ),
        ]
        records = DuplicateDetector.markSuspectedDuplicates(records)
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 4, 30),
            positions: [],
            cashBalances: ["CNY": 50_000],
            cashValueInCNY: 50_000,
            status: .confirmedComplete
        )

        let result = FIRECalculator.calculate(
            transactions: records,
            assetSnapshot: snapshot,
            confirmedMonthlyContribution: 500,
            calculatedAt: testDate(2026, 4, 30)
        )

        XCTAssertEqual(result.annualSpending, 12_000)
        XCTAssertEqual(result.targetAmount, Decimal(string: "342857.14")!)
        XCTAssertEqual(result.remainingAmount, Decimal(string: "292857.14")!)
        XCTAssertNotNil(result.estimatedFreedomDate)
        XCTAssertNotNil(result.estimatedMonthsRemaining)
        XCTAssertEqual(
            FIREAssumptions.conservative.withdrawalRate,
            Decimal(string: "0.03")!
        )
        XCTAssertEqual(
            FIREAssumptions.optimisticWithdrawal.withdrawalRate,
            Decimal(string: "0.04")!
        )
    }

    func testPlannedAnnualSpendingOverridesGoalButKeepsLedgerReference() {
        let records = [
            transaction(date: testDate(2026, 1, 1), amount: 1_000),
            transaction(date: testDate(2026, 2, 1), amount: 1_000),
            transaction(date: testDate(2026, 3, 1), amount: 1_000),
            transaction(date: testDate(2026, 4, 1), amount: 1_000),
            transaction(
                date: testDate(2026, 4, 30),
                amount: 0,
                internalTransfer: true
            ),
        ]
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 4, 30),
            positions: [],
            cashBalances: ["CNY": 50_000],
            cashValueInCNY: 50_000,
            status: .confirmedComplete
        )
        let assumptions = FIREAssumptions(
            withdrawalRate: Decimal(string: "0.035")!,
            expectedAnnualReturn: 0,
            annualInflation: 0
        )

        let ledgerBased = FIRECalculator.calculate(
            transactions: records,
            assetSnapshot: snapshot,
            assumptions: assumptions,
            confirmedMonthlyContribution: 10_000,
            calculatedAt: testDate(2026, 4, 30)
        )
        let planned = FIRECalculator.calculate(
            transactions: records,
            assetSnapshot: snapshot,
            assumptions: assumptions,
            plannedAnnualSpending: 6_000,
            confirmedMonthlyContribution: 10_000,
            calculatedAt: testDate(2026, 4, 30)
        )
        let zeroPlanned = FIRECalculator.calculate(
            transactions: records,
            assetSnapshot: snapshot,
            assumptions: assumptions,
            plannedAnnualSpending: 0,
            calculatedAt: testDate(2026, 4, 30)
        )
        let negativePlanned = FIRECalculator.calculate(
            transactions: records,
            assetSnapshot: snapshot,
            assumptions: assumptions,
            plannedAnnualSpending: -1,
            calculatedAt: testDate(2026, 4, 30)
        )

        XCTAssertEqual(ledgerBased.annualSpending, 12_000)
        XCTAssertEqual(ledgerBased.targetAmount, Decimal(string: "342857.14")!)
        XCTAssertEqual(ledgerBased.estimatedMonthsRemaining, 30)
        XCTAssertEqual(planned.annualSpending, 6_000)
        XCTAssertEqual(planned.targetAmount, Decimal(string: "171428.57")!)
        XCTAssertEqual(planned.remainingAmount, Decimal(string: "121428.57")!)
        XCTAssertEqual(planned.estimatedMonthsRemaining, 13)
        XCTAssertEqual(planned.expenseAnalysis.annualSpending, 12_000)
        XCTAssertEqual(zeroPlanned.annualSpending, 12_000)
        XCTAssertEqual(zeroPlanned.targetAmount, ledgerBased.targetAmount)
        XCTAssertEqual(negativePlanned.annualSpending, 12_000)
        XCTAssertEqual(negativePlanned.targetAmount, ledgerBased.targetAmount)
    }

    func testAnnualBonusContributionWorksWithoutConfirmedMonthlyContribution() {
        let records = [
            transaction(date: testDate(2026, 1, 1), amount: 350),
            transaction(date: testDate(2026, 2, 1), amount: 350),
            transaction(date: testDate(2026, 3, 1), amount: 350),
            transaction(
                date: testDate(2026, 3, 31),
                amount: 0,
                internalTransfer: true
            ),
        ]
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 3, 31),
            positions: [],
            cashBalances: ["CNY": 100_000],
            cashValueInCNY: 100_000,
            status: .confirmedComplete
        )
        let result = FIRECalculator.calculate(
            transactions: records,
            assetSnapshot: snapshot,
            assumptions: FIREAssumptions(
                withdrawalRate: Decimal(string: "0.035")!,
                expectedAnnualReturn: 0,
                annualInflation: 0
            ),
            confirmedAnnualBonusContribution: 20_000,
            calculatedAt: testDate(2026, 3, 31)
        )

        XCTAssertEqual(result.targetAmount, 120_000)
        XCTAssertNil(result.confirmedMonthlyContribution)
        XCTAssertEqual(result.confirmedAnnualBonusContribution, 20_000)
        XCTAssertEqual(result.estimatedMonthsRemaining, 12)
    }

    func testFiniteNegativeContributionsRemainProjectable() {
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 3, 31),
            positions: [],
            cashBalances: ["CNY": 100_000],
            cashValueInCNY: 100_000,
            status: .confirmedComplete
        )
        let assumptions = FIREAssumptions(
            withdrawalRate: Decimal(string: "0.035")!,
            expectedAnnualReturn: 0,
            annualInflation: 0
        )

        let monthlyDeficit = FIRECalculator.calculate(
            transactions: [],
            assetSnapshot: snapshot,
            assumptions: assumptions,
            plannedAnnualSpending: 4_200,
            confirmedMonthlyContribution: -1_000,
            confirmedAnnualBonusContribution: 32_000,
            calculatedAt: testDate(2026, 3, 31)
        )
        let annualDeficit = FIRECalculator.calculate(
            transactions: [],
            assetSnapshot: snapshot,
            assumptions: assumptions,
            plannedAnnualSpending: 5_250,
            confirmedMonthlyContribution: 3_000,
            confirmedAnnualBonusContribution: -10_000,
            calculatedAt: testDate(2026, 3, 31)
        )
        let nonFinite = FIRECalculator.calculate(
            transactions: [],
            assetSnapshot: snapshot,
            assumptions: assumptions,
            plannedAnnualSpending: 4_200,
            confirmedMonthlyContribution: .nan,
            confirmedAnnualBonusContribution: 32_000,
            calculatedAt: testDate(2026, 3, 31)
        )

        XCTAssertEqual(monthlyDeficit.confirmedMonthlyContribution, -1_000)
        XCTAssertEqual(monthlyDeficit.estimatedMonthsRemaining, 12)
        XCTAssertEqual(
            annualDeficit.confirmedAnnualBonusContribution,
            -10_000
        )
        XCTAssertEqual(annualDeficit.estimatedMonthsRemaining, 20)
        XCTAssertNil(nonFinite.estimatedFreedomDate)
        XCTAssertNil(nonFinite.estimatedMonthsRemaining)
    }

    func testSuggestedMonthlyContributionNeverDrivesProjection() {
        var records: [TransactionRecord] = []
        for month in 1...3 {
            records.append(
                transaction(
                    date: testDate(2026, month, 1),
                    direction: .income,
                    amount: 10_000,
                    primary: "职业收入",
                    secondary: "工资"
                )
            )
            records.append(
                transaction(
                    date: testDate(2026, month, 2),
                    amount: 350
                )
            )
        }
        records.append(
            transaction(
                date: testDate(2026, 3, 31),
                amount: 0,
                internalTransfer: true
            )
        )
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 3, 31),
            positions: [],
            cashBalances: ["CNY": 100_000],
            cashValueInCNY: 100_000,
            status: .confirmedComplete
        )

        let result = FIRECalculator.calculate(
            transactions: records,
            assetSnapshot: snapshot,
            assumptions: FIREAssumptions(
                withdrawalRate: Decimal(string: "0.035")!,
                expectedAnnualReturn: 0,
                annualInflation: 0
            ),
            calculatedAt: testDate(2026, 3, 31)
        )

        XCTAssertEqual(result.targetAmount, 120_000)
        XCTAssertEqual(result.suggestedMonthlyContribution.amount, 9_650)
        XCTAssertNil(result.confirmedMonthlyContribution)
        XCTAssertNil(result.estimatedFreedomDate)
        XCTAssertNil(result.estimatedMonthsRemaining)
    }

    func testSameCodeAggregatesButSameNameWithoutCodeOnlySuggestsMerge() {
        let codedA = Instrument(
            code: "09991",
            name: "示例控股",
            kind: .stock,
            currency: .hkd
        )
        let codedB = Instrument(
            code: "09991",
            name: "示例",
            kind: .stock,
            currency: .hkd
        )
        let noCodeA = Instrument(name: "某现金管理", kind: .fund, currency: .cny)
        let noCodeB = Instrument(name: "某现金管理", kind: .fund, currency: .cny)
        let date = testDate(2026, 4, 30)
        let positions = [
            PositionSnapshot(
                instrument: codedA,
                originalMarketValue: 100,
                marketValueInCNY: 90,
                capturedAt: date
            ),
            PositionSnapshot(
                instrument: codedB,
                originalMarketValue: 200,
                marketValueInCNY: 180,
                capturedAt: date
            ),
            PositionSnapshot(
                instrument: noCodeA,
                originalMarketValue: 300,
                marketValueInCNY: 300,
                capturedAt: date
            ),
            PositionSnapshot(
                instrument: noCodeB,
                originalMarketValue: 400,
                marketValueInCNY: 400,
                capturedAt: date
            ),
        ]

        let aggregated = PositionAggregator.aggregate(positions)
        let coded = aggregated.first { $0.instrument.code == "09991" }
        let suggestions = PositionAggregator.nameMatchSuggestions(in: positions)

        XCTAssertEqual(aggregated.count, 3)
        XCTAssertEqual(coded?.originalMarketValue, 300)
        XCTAssertEqual(coded?.marketValueInCNY, 270)
        XCTAssertEqual(suggestions.count, 1)
    }

    func testMissingProductIsClosedOnlyAfterCompleteSnapshotConfirmation() {
        let old = Instrument(code: "123", name: "旧产品", kind: .fund, currency: .cny)
        let oldPosition = PositionSnapshot(
            instrument: old,
            originalMarketValue: 1_000,
            marketValueInCNY: 1_000,
            capturedAt: testDate(2026, 3, 31)
        )
        let previous = AssetSnapshot(
            capturedAt: testDate(2026, 3, 31),
            positions: [oldPosition],
            status: .confirmedComplete
        )
        let draft = AssetSnapshot(
            capturedAt: testDate(2026, 4, 30),
            positions: [],
            status: .draft
        )
        let complete = AssetSnapshot(
            capturedAt: testDate(2026, 4, 30),
            positions: [],
            status: .confirmedComplete
        )

        XCTAssertEqual(SnapshotReconciler.closedInstrumentIDs(previous: previous, current: draft), [])
        XCTAssertEqual(
            SnapshotReconciler.closedInstrumentIDs(previous: previous, current: complete),
            [old.id]
        )
    }
}
