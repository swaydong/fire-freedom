import Foundation
import XCTest
@testable import FIRE

final class DashboardSnapshotTests: XCTestCase {
    func testFinancialPrivacyFormatterMasksNumbersAndProgress() {
        let formatter = FinancialPrivacyFormatter(hidesNumbers: true)

        XCTAssertEqual(formatter.value("¥1,234,567"), "••••")
        XCTAssertEqual(formatter.value("2035年8月"), "••••")
        XCTAssertEqual(formatter.progress(0.42), 0)
    }

    func testFinancialPrivacyFormatterKeepsValuesWhenVisible() {
        let formatter = FinancialPrivacyFormatter(hidesNumbers: false)

        XCTAssertEqual(formatter.value("42.0%"), "42.0%")
        XCTAssertEqual(formatter.progress(0.42), 0.42)
    }

    func testFinancialPrivacyKeepsExistingPreferenceKey() {
        XCTAssertEqual(
            FinancialPrivacy.storageKey,
            "dashboard.hidesNumbers"
        )
    }

    func testConfirmedZeroContributionCanReachGoalFromInvestmentGrowth() {
        let snapshot = DashboardSnapshot(
            investableNetWorth: 900_000,
            annualExpense: 35_000,
            monthlyContribution: 0,
            confirmedContribution: true,
            confidence: .high,
            observedMonths: 12,
            assumptions: .defaults
        )

        XCTAssertNotNil(
            snapshot.estimatedDate(
                withdrawalRate: 0.035,
                now: Date(timeIntervalSince1970: 0)
            )
        )
    }

    func testUnconfirmedContributionDoesNotProduceEstimatedDate() {
        let snapshot = DashboardSnapshot(
            investableNetWorth: 900_000,
            annualExpense: 35_000,
            monthlyContribution: 10_000,
            confirmedContribution: false,
            confidence: .high,
            observedMonths: 12,
            assumptions: .defaults
        )

        XCTAssertNil(snapshot.estimatedDate(withdrawalRate: 0.035))
    }

    func testInvalidReturnOrInflationDoesNotProduceEstimatedDate() {
        var snapshot = DashboardSnapshot(
            investableNetWorth: 100_000,
            annualExpense: 35_000,
            monthlyContribution: 10_000,
            confirmedContribution: true,
            confidence: .high,
            observedMonths: 12,
            assumptions: .defaults
        )

        snapshot.assumptions.expectedReturn = .infinity
        XCTAssertNil(snapshot.estimatedDate(withdrawalRate: 0.035))

        snapshot.assumptions.expectedReturn = 0.05
        snapshot.assumptions.inflation = -1
        XCTAssertNil(snapshot.estimatedDate(withdrawalRate: 0.035))
    }

    func testAnnualBonusOnlyProjectionIgnoresUnconfirmedMonthlySuggestion() {
        let now = Date(timeIntervalSince1970: 0)
        var snapshot = DashboardSnapshot(
            investableNetWorth: 100_000,
            annualExpense: 4_200,
            monthlyContribution: 1_000_000,
            annualBonusContribution: 20_000,
            confirmedContribution: false,
            annualBonusContributionConfirmed: true,
            confidence: .high,
            observedMonths: 12,
            assumptions: FIREDisplayAssumptions(
                withdrawalRate: 0.035,
                expectedReturn: 0,
                inflation: 0
            )
        )

        XCTAssertEqual(
            snapshot.estimatedDate(withdrawalRate: 0.035, now: now),
            Calendar.current.date(byAdding: .month, value: 12, to: now)
        )

        snapshot.annualBonusContribution = 0
        XCTAssertNil(
            snapshot.estimatedDate(withdrawalRate: 0.035, now: now)
        )
    }

    func testAnnualCashFlowSummaryUsesMonthlyAndAnnualIncomeMinusExpenses() {
        let snapshot = DashboardSnapshot(
            investableNetWorth: 100_000,
            annualExpense: 126_000,
            monthlyIncome: 20_000,
            annualIncome: 50_000,
            monthlyExpense: 8_000,
            annualIrregularExpense: 30_000,
            monthlyContribution: 12_000,
            annualBonusContribution: 20_000,
            confirmedContribution: true,
            annualBonusContributionConfirmed: true,
            confidence: .medium,
            observedMonths: 8,
            assumptions: .defaults
        )

        XCTAssertEqual(snapshot.annualPlannedIncome, 290_000)
        XCTAssertEqual(snapshot.annualPlannedOutflow, 126_000)
        XCTAssertEqual(snapshot.annualPlannedContribution, 164_000)
    }

    func testNegativeAnnualCashFlowStillParticipatesInProjection() {
        let now = Date(timeIntervalSince1970: 0)
        let snapshot = DashboardSnapshot(
            investableNetWorth: 100_000,
            annualExpense: 7_000,
            monthlyContribution: 1_000,
            annualBonusContribution: -2_000,
            confirmedContribution: true,
            annualBonusContributionConfirmed: true,
            confidence: .high,
            observedMonths: 12,
            assumptions: FIREDisplayAssumptions(
                withdrawalRate: 0.035,
                expectedReturn: 0,
                inflation: 0
            )
        )

        XCTAssertNotNil(
            snapshot.estimatedDate(withdrawalRate: 0.035, now: now)
        )
    }

    func testDashboardUsesCoreCalculationWithoutRecomputingAtDisplayBoundary() {
        let estimatedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = DashboardSnapshot(
            investableNetWorth: 999,
            annualExpense: 321,
            monthlyContribution: 0,
            confirmedContribution: true,
            confidence: .high,
            observedMonths: 12,
            assumptions: .defaults,
            coreTargetAmount: 12_345,
            coreProgress: 0.123,
            coreRemainingAmount: 10_000,
            coreEstimatedFreedomDate: estimatedDate,
            usesCoreCalculation: true
        )

        XCTAssertEqual(snapshot.target(withdrawalRate: 0.99), 12_345)
        XCTAssertEqual(snapshot.progress(withdrawalRate: 0.99), 0.123)
        XCTAssertEqual(snapshot.remaining(withdrawalRate: 0.99), 10_000)
        XCTAssertEqual(
            snapshot.estimatedDate(withdrawalRate: 0.99),
            estimatedDate
        )
    }
}
