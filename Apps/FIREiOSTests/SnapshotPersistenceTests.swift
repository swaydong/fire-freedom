import CryptoKit
import FIRECore
import SwiftData
import XCTest
@testable import FIRE

@MainActor
final class SnapshotPersistenceTests: XCTestCase {
    func testNoScreenshotCannotClosePriorProductsWithoutExplicitConfirmation() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        let priorInstrument = InstrumentEntity(
            code: "000001",
            name: "旧基金",
            kind: .fund,
            currency: "CNY"
        )
        context.insert(priorInstrument)
        try context.save()

        let saved = await appState.confirmAssetSnapshot(
            capturedAt: Calendar.current.startOfDay(for: .now),
            cashCNY: 10_000,
            cashUSD: 0,
            cashHKD: 0,
            confirmsAllScreenshotsWereSelected: false,
            confirmsNoInvestmentPositions: false,
            latestConfirmedSnapshotDate: nil,
            existingInstruments: [priorInstrument],
            liabilities: []
        )

        XCTAssertFalse(saved)
        XCTAssertTrue(priorInstrument.isActive)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<AssetSnapshotEntity>()).isEmpty
        )
    }

    func testCashOnlySnapshotCanClosePriorProductsAndRejectSameDayRepeat() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        let priorInstrument = InstrumentEntity(
            code: "000001",
            name: "旧基金",
            kind: .fund,
            currency: "CNY"
        )
        context.insert(priorInstrument)
        try context.save()
        let capturedAt = Calendar.current.startOfDay(for: .now)

        let firstSaved = await appState.confirmAssetSnapshot(
            capturedAt: capturedAt,
            cashCNY: 10_000,
            cashUSD: 0,
            cashHKD: 0,
            confirmsAllScreenshotsWereSelected: false,
            confirmsNoInvestmentPositions: true,
            latestConfirmedSnapshotDate: nil,
            existingInstruments: [priorInstrument],
            liabilities: []
        )

        XCTAssertTrue(firstSaved)
        XCTAssertFalse(priorInstrument.isActive)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AssetSnapshotEntity>()).count,
            1
        )
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<PositionSnapshotEntity>()).isEmpty
        )

        let secondSaved = await appState.confirmAssetSnapshot(
            capturedAt: capturedAt,
            cashCNY: 11_000,
            cashUSD: 0,
            cashHKD: 0,
            confirmsAllScreenshotsWereSelected: false,
            confirmsNoInvestmentPositions: true,
            latestConfirmedSnapshotDate: capturedAt,
            existingInstruments: [priorInstrument],
            liabilities: []
        )

        XCTAssertFalse(secondSaved)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AssetSnapshotEntity>()).count,
            1
        )
    }

    func testAnalysisPacketUsesRatesFrozenInAssetSnapshot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let capturedAt = Date(timeIntervalSince1970: 1_783_270_800)
        let snapshot = AssetSnapshotEntity(
            capturedAt: capturedAt,
            cashCNY: 1_000,
            cashUSD: 100,
            cashHKD: 200,
            cashValueInCNY: 3_513,
            liabilityPrincipalCNY: 0,
            positionsCNY: 0,
            isComplete: true,
            exchangeRateState: .stale,
            exchangeRateAsOf: capturedAt,
            exchangeRateFetchedAt: capturedAt.addingTimeInterval(60),
            exchangeRateSource: "ECB 缓存",
            usdToCNY: 7.25,
            hkdToCNY: 0.94
        )
        context.insert(snapshot)
        try context.save()

        let packet = CoreDataAdapter(context: context).analysisPacket(
            transactions: [],
            latestAssetSnapshot: snapshot,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )

        XCTAssertEqual(
            decimalDouble(
                packet.assetSnapshot.exchangeRates?.cnyPerUnit["USD"]
            ),
            7.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            decimalDouble(
                packet.assetSnapshot.exchangeRates?.cnyPerUnit["HKD"]
            ),
            0.94,
            accuracy: 0.000_001
        )
        XCTAssertEqual(packet.assetSnapshot.exchangeRates?.source, "ECB 缓存")
        XCTAssertEqual(packet.assetSnapshot.exchangeRates?.isStale, true)
    }

    func testAnalysisPacketPreservesCashbackAsRefundIncome() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let capturedAt = Date(timeIntervalSince1970: 1_783_270_800)
        let cashback = TransactionEntity(
            fingerprint: "cashback",
            transactionDate: capturedAt,
            directionRawValue: "收入",
            amount: 88,
            category: "购物",
            subcategory: "返现",
            merchant: "商店",
            note: "",
            account: ""
        )
        let snapshot = AssetSnapshotEntity(
            capturedAt: capturedAt,
            cashCNY: 0,
            cashValueInCNY: 0,
            liabilityPrincipalCNY: 0,
            positionsCNY: 0,
            isComplete: true,
            exchangeRateState: .current,
            exchangeRateAsOf: capturedAt
        )

        let packet = CoreDataAdapter(context: context).analysisPacket(
            transactions: [cashback],
            latestAssetSnapshot: snapshot,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )

        XCTAssertEqual(packet.monthlySummary?.refundIncome, 88)
        XCTAssertEqual(packet.monthlySummary?.netCashFlow, 88)
    }

    func testHistoricalReportPacketExcludesLaterTransactions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let juneExpense = TransactionEntity(
            fingerprint: "june-expense",
            transactionDate: reportTestDate(2026, 6, 12),
            directionRawValue: "支出",
            amount: 1_000,
            category: "餐饮",
            subcategory: "聚餐",
            merchant: "六月餐厅",
            note: "",
            account: ""
        )
        let julyExpense = TransactionEntity(
            fingerprint: "july-expense",
            transactionDate: reportTestDate(2026, 7, 5),
            directionRawValue: "支出",
            amount: 9_000,
            category: "旅行",
            subcategory: "酒店",
            merchant: "七月酒店",
            note: "",
            account: ""
        )
        let snapshot = AssetSnapshotEntity(
            capturedAt: reportTestDate(2026, 6, 30),
            cashCNY: 10_000,
            cashValueInCNY: 10_000,
            liabilityPrincipalCNY: 0,
            positionsCNY: 0,
            isComplete: true,
            exchangeRateState: .current,
            exchangeRateAsOf: reportTestDate(2026, 6, 30)
        )
        context.insert(
            AppMetadataEntity(
                key: "transactions.coverage.start",
                dateValue: reportTestDate(2026, 3, 1)
            )
        )
        context.insert(
            AppMetadataEntity(
                key: "transactions.coverage.end",
                dateValue: reportTestDate(2026, 7, 31)
            )
        )
        try context.save()

        let reportDate = reportTestDate(2026, 6, 15)
        let packet = CoreDataAdapter(context: context).analysisPacket(
            transactions: [juneExpense, julyExpense],
            latestAssetSnapshot: snapshot,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil,
            reportDate: reportDate
        )

        XCTAssertEqual(packet.transactions.map(\.fingerprint), [
            juneExpense.id.uuidString.lowercased(),
        ])
        XCTAssertEqual(packet.monthlySummary?.livingExpense, 1_000)
        XCTAssertTrue(
            MonthlyReportSelection.isSameMonth(
                try XCTUnwrap(packet.monthlySummary?.periodStart),
                reportDate
            )
        )
        XCTAssertEqual(packet.fireState.calculatedAt, reportDate)
    }

    func testSameNamedLiabilityIsUpdatedInsteadOfDoubleCounted() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)

        let firstSave = await appState.saveLiability(
            existing: nil,
            name: " 房贷 ",
            currency: "CNY",
            principal: 500_000
        )
        XCTAssertTrue(firstSave)
        let secondSave = await appState.saveLiability(
            existing: nil,
            name: "房贷",
            currency: "CNY",
            principal: 480_000
        )
        XCTAssertTrue(secondSave)

        let liabilities = try context.fetch(FetchDescriptor<LiabilityEntity>())
        XCTAssertEqual(liabilities.count, 1)
        XCTAssertEqual(liabilities[0].remainingPrincipal, 480_000)
        XCTAssertEqual(liabilities[0].cnyRemainingPrincipal, 480_000)
    }

    func testAssumptionUpdatePersistsWithdrawalRateInSettings() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)

        appState.updateAssumptions(
            withdrawalRate: 0.035,
            expectedReturn: 0.04,
            inflation: 0.018
        )

        let saved = try XCTUnwrap(
            context.fetch(FetchDescriptor<FIRESettingsEntity>()).first
        )
        XCTAssertEqual(saved.withdrawalRate, 0.035, accuracy: 0.000_001)
        XCTAssertEqual(saved.expectedReturn, 0.04, accuracy: 0.000_001)
        XCTAssertEqual(saved.inflation, 0.018, accuracy: 0.000_001)
    }

    func testLatestSnapshotAllowsManualOptionAddEditAndDelete() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        let snapshot = AssetSnapshotEntity(
            capturedAt: Calendar.current.startOfDay(for: .now),
            cashCNY: 0,
            cashValueInCNY: 0,
            liabilityPrincipalCNY: 0,
            positionsCNY: 0,
            isComplete: true,
            exchangeRateState: .current,
            exchangeRateAsOf: .now,
            exchangeRateSource: "ECB",
            usdToCNY: 7.25
        )
        context.insert(snapshot)
        try context.save()

        let added = await appState.saveManualPosition(
            snapshot: snapshot,
            existingPosition: nil,
            name: "公司期权",
            code: nil,
            kind: .option,
            currency: "USD",
            originalMarketValue: 100
        )

        XCTAssertTrue(added)
        var positions = try context.fetch(
            FetchDescriptor<PositionSnapshotEntity>()
        )
        var instruments = try context.fetch(
            FetchDescriptor<InstrumentEntity>()
        )
        let position = try XCTUnwrap(positions.first)
        let instrument = try XCTUnwrap(instruments.first)
        XCTAssertEqual(instrument.kind, .option)
        XCTAssertEqual(position.cnyMarketValue, 725, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.positionsCNY, 725, accuracy: 0.000_001)

        let updated = await appState.saveManualPosition(
            snapshot: snapshot,
            existingPosition: position,
            name: "公司期权",
            code: nil,
            kind: .option,
            currency: "USD",
            originalMarketValue: 120
        )

        XCTAssertTrue(updated)
        positions = try context.fetch(
            FetchDescriptor<PositionSnapshotEntity>()
        )
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(
            positions[0].cnyMarketValue,
            870,
            accuracy: 0.000_001
        )
        XCTAssertEqual(snapshot.positionsCNY, 870, accuracy: 0.000_001)

        XCTAssertTrue(
            appState.deletePositionFromLatestSnapshot(
                positions[0],
                snapshot: snapshot
            )
        )
        positions = try context.fetch(
            FetchDescriptor<PositionSnapshotEntity>()
        )
        instruments = try context.fetch(
            FetchDescriptor<InstrumentEntity>()
        )
        XCTAssertTrue(positions.isEmpty)
        XCTAssertEqual(snapshot.positionsCNY, 0, accuracy: 0.000_001)
        XCTAssertFalse(try XCTUnwrap(instruments.first).isActive)
    }

    func testHistoricalSnapshotRejectsManualPositionEditing() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        let oldSnapshot = AssetSnapshotEntity(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            cashCNY: 0,
            cashValueInCNY: 0,
            liabilityPrincipalCNY: 0,
            positionsCNY: 0,
            isComplete: true,
            exchangeRateState: .current,
            exchangeRateAsOf: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let latestSnapshot = AssetSnapshotEntity(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            cashCNY: 0,
            cashValueInCNY: 0,
            liabilityPrincipalCNY: 0,
            positionsCNY: 0,
            isComplete: true,
            exchangeRateState: .current,
            exchangeRateAsOf: Date(timeIntervalSince1970: 1_800_000_000)
        )
        context.insert(oldSnapshot)
        context.insert(latestSnapshot)
        try context.save()

        let saved = await appState.saveManualPosition(
            snapshot: oldSnapshot,
            existingPosition: nil,
            name: "历史期权",
            code: nil,
            kind: .option,
            currency: "CNY",
            originalMarketValue: 100_000
        )

        XCTAssertFalse(saved)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<PositionSnapshotEntity>()).isEmpty
        )
    }

    func testContributionSplitPersistsIndependentlyAndIsIncludedInAnalysisPacket() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)

        XCTAssertTrue(appState.saveAnnualBonusContribution(80_000))
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<FIRESettingsEntity>()).isEmpty
        )
        XCTAssertTrue(appState.saveMonthlyContribution(12_000))

        var settings = try XCTUnwrap(
            context.fetch(FetchDescriptor<FIRESettingsEntity>()).first
        )
        var annualBonuses = try context.fetch(
            FetchDescriptor<AppMetadataEntity>()
        ).filter {
            $0.key == AppMetadataKey.confirmedAnnualBonusContribution
        }
        XCTAssertEqual(settings.confirmedMonthlyContribution, 12_000)
        XCTAssertEqual(annualBonuses.count, 1)
        XCTAssertEqual(annualBonuses.first?.doubleValue, 80_000)

        XCTAssertTrue(appState.saveMonthlyContribution(15_000))
        annualBonuses = try context.fetch(
            FetchDescriptor<AppMetadataEntity>()
        ).filter {
            $0.key == AppMetadataKey.confirmedAnnualBonusContribution
        }
        XCTAssertEqual(annualBonuses.count, 1)
        XCTAssertEqual(annualBonuses.first?.doubleValue, 80_000)

        XCTAssertTrue(appState.saveAnnualBonusContribution(90_000))
        settings = try XCTUnwrap(
            context.fetch(FetchDescriptor<FIRESettingsEntity>()).first
        )
        let annualBonus = try XCTUnwrap(
            context.fetch(FetchDescriptor<AppMetadataEntity>())
                .first(where: {
                    $0.key == AppMetadataKey.confirmedAnnualBonusContribution
                })
        )
        let packet = CoreDataAdapter(context: context).analysisPacket(
            transactions: [],
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: settings
        )

        XCTAssertEqual(settings.confirmedMonthlyContribution, 15_000)
        XCTAssertEqual(annualBonus.doubleValue, 90_000)
        XCTAssertEqual(
            CoreDataAdapter(context: context).dashboard(
                transactions: [],
                latestAssetSnapshot: nil,
                allPositions: [],
                instruments: [],
                liabilities: [],
                settings: settings
            ).monthlyIncome,
            15_000
        )
        XCTAssertEqual(packet.fireState.confirmedMonthlyContribution, 15_000)
        XCTAssertEqual(
            packet.fireState.confirmedAnnualBonusContribution,
            90_000
        )
    }

    func testExplicitZeroContributionsRemainDistinctFromMissingValues() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        let adapter = CoreDataAdapter(context: context)

        var dashboard = adapter.dashboard(
            transactions: [],
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )
        XCTAssertFalse(dashboard.confirmedContribution)
        XCTAssertFalse(dashboard.annualBonusContributionConfirmed)

        XCTAssertTrue(appState.saveMonthlyContribution(0))
        let settings = try XCTUnwrap(
            context.fetch(FetchDescriptor<FIRESettingsEntity>()).first
        )
        dashboard = adapter.dashboard(
            transactions: [],
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: settings
        )
        XCTAssertEqual(settings.confirmedMonthlyContribution, 0)
        XCTAssertTrue(dashboard.confirmedContribution)
        XCTAssertFalse(dashboard.annualBonusContributionConfirmed)

        XCTAssertTrue(appState.saveAnnualBonusContribution(0))
        dashboard = adapter.dashboard(
            transactions: [],
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: settings
        )
        let packet = adapter.analysisPacket(
            transactions: [],
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: settings
        )

        XCTAssertTrue(dashboard.confirmedContribution)
        XCTAssertTrue(dashboard.annualBonusContributionConfirmed)
        XCTAssertEqual(dashboard.monthlyContribution, 0)
        XCTAssertEqual(dashboard.annualBonusContribution, 0)
        XCTAssertEqual(packet.fireState.confirmedMonthlyContribution, 0)
        XCTAssertEqual(packet.fireState.confirmedAnnualBonusContribution, 0)
    }

    func testPlannedAnnualSpendingCanOverrideAndReturnToLedgerValue() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        let adapter = CoreDataAdapter(context: context)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let monthStart = try XCTUnwrap(
            calendar.date(
                from: DateComponents(year: 2026, month: 1, day: 1)
            )
        )
        let monthEnd = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 1,
                    day: 31,
                    hour: 23
                )
            )
        )
        let transactions = [
            TransactionEntity(
                fingerprint: "annual-expense",
                transactionDate: monthStart,
                directionRawValue: "支出",
                amount: 1_000,
                category: "餐饮",
                subcategory: "日常",
                merchant: "餐厅",
                note: "",
                account: ""
            ),
            TransactionEntity(
                fingerprint: "month-boundary",
                transactionDate: monthEnd,
                directionRawValue: "支出",
                amount: 0,
                category: "内部转账",
                subcategory: "",
                merchant: "",
                note: "",
                account: "",
                isInternalTransfer: true
            ),
        ]

        var dashboard = adapter.dashboard(
            transactions: transactions,
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )
        XCTAssertNil(dashboard.plannedAnnualExpense)
        XCTAssertEqual(dashboard.annualExpense, 12_000)
        XCTAssertEqual(dashboard.ledgerAnnualExpense, 12_000)
        XCTAssertEqual(dashboard.recurringAnnualizedExpense, 12_000)
        XCTAssertEqual(dashboard.irregularAnnualExpense, 0)

        XCTAssertTrue(appState.saveAnnualBonusContribution(80_000))
        XCTAssertTrue(appState.savePlannedAnnualSpending(18_000))
        context.insert(
            AppMetadataEntity(
                key: AppMetadataKey.plannedAnnualSpending,
                doubleValue: 17_000
            )
        )
        try context.save()
        XCTAssertTrue(appState.savePlannedAnnualSpending(20_000))
        XCTAssertFalse(appState.savePlannedAnnualSpending(0))
        XCTAssertFalse(appState.savePlannedAnnualSpending(-1))
        XCTAssertFalse(appState.savePlannedAnnualSpending(.infinity))
        XCTAssertFalse(appState.savePlannedAnnualSpending(1e308))

        let plannedMetadata = try context.fetch(
            FetchDescriptor<AppMetadataEntity>()
        ).filter {
            $0.key == AppMetadataKey.plannedAnnualSpending
        }
        XCTAssertEqual(plannedMetadata.count, 1)
        XCTAssertEqual(plannedMetadata.first?.doubleValue, 20_000)

        dashboard = adapter.dashboard(
            transactions: transactions,
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )
        let packet = adapter.analysisPacket(
            transactions: transactions,
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )
        XCTAssertEqual(dashboard.plannedAnnualExpense, 20_000)
        XCTAssertEqual(dashboard.annualExpense, 20_000)
        XCTAssertEqual(dashboard.monthlyExpense, 1_000)
        XCTAssertEqual(dashboard.annualIrregularExpense, 8_000)
        XCTAssertEqual(dashboard.annualIncome, 88_000)
        XCTAssertEqual(dashboard.annualBonusContribution, 80_000)
        XCTAssertEqual(dashboard.ledgerAnnualExpense, 12_000)
        XCTAssertEqual(packet.fireState.annualSpending, 20_000)
        XCTAssertEqual(packet.fireState.expenseAnalysis.annualSpending, 12_000)

        plannedMetadata.first?.doubleValue = 1e308
        try context.save()
        dashboard = adapter.dashboard(
            transactions: transactions,
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )
        XCTAssertNil(dashboard.plannedAnnualExpense)
        XCTAssertEqual(dashboard.annualExpense, 12_000)
        XCTAssertTrue(appState.savePlannedAnnualSpending(20_000))

        XCTAssertTrue(appState.clearPlannedAnnualSpending())
        dashboard = adapter.dashboard(
            transactions: transactions,
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )
        let remainingMetadata = try context.fetch(
            FetchDescriptor<AppMetadataEntity>()
        )
        XCTAssertNil(dashboard.plannedAnnualExpense)
        XCTAssertEqual(dashboard.annualExpense, 12_000)
        XCTAssertFalse(
            remainingMetadata.contains {
                $0.key == AppMetadataKey.plannedAnnualSpending
            }
        )
        XCTAssertTrue(
            remainingMetadata.contains {
                $0.key == AppMetadataKey.confirmedAnnualBonusContribution
            }
        )
    }

    func testDashboardCombinesEditableMonthlyAndAnnualIncomeAndExpensePlans() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        let adapter = CoreDataAdapter(context: context)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: month,
                    day: day,
                    hour: hour
                )
            )!
        }

        var transactions: [TransactionEntity] = []
        for month in 1...3 {
            transactions.append(
                TransactionEntity(
                    fingerprint: "salary-\(month)",
                    transactionDate: date(month, 1),
                    directionRawValue: "收入",
                    amount: 20_000,
                    category: "职业收入",
                    subcategory: "工资",
                    merchant: "公司",
                    note: "",
                    account: ""
                )
            )
            transactions.append(
                TransactionEntity(
                    fingerprint: "housing-\(month)",
                    transactionDate: date(month, 15),
                    directionRawValue: "支出",
                    amount: 5_000,
                    category: "住房",
                    subcategory: "房租",
                    merchant: "房东",
                    note: "",
                    account: ""
                )
            )
        }
        transactions.append(
            TransactionEntity(
                fingerprint: "trip",
                transactionDate: date(2, 20),
                directionRawValue: "支出",
                amount: 12_000,
                category: "旅行",
                subcategory: "度假",
                merchant: "酒店",
                note: "",
                account: ""
            )
        )
        transactions.append(
            TransactionEntity(
                fingerprint: "bonus",
                transactionDate: date(3, 31, hour: 23),
                directionRawValue: "收入",
                amount: 30_000,
                category: "职业收入",
                subcategory: "绩效奖金",
                merchant: "公司",
                note: "",
                account: ""
            )
        )

        var dashboard = adapter.dashboard(
            transactions: transactions,
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )

        XCTAssertEqual(dashboard.monthlyIncomeReference.median, 20_000)
        XCTAssertEqual(dashboard.monthlyIncomeReference.latest, 20_000)
        XCTAssertEqual(dashboard.monthlyIncomeReference.monthsUsed, 3)
        XCTAssertEqual(dashboard.monthlyIncome, 20_000)
        XCTAssertEqual(dashboard.annualIncome, 30_000)
        XCTAssertEqual(dashboard.monthlyExpense, 5_000)
        XCTAssertEqual(dashboard.annualIrregularExpense, 12_000)
        XCTAssertEqual(dashboard.recurringAnnualizedExpense, 60_000)
        XCTAssertEqual(dashboard.irregularAnnualExpense, 12_000)
        XCTAssertEqual(dashboard.ledgerAnnualExpense, 72_000)
        XCTAssertFalse(dashboard.confirmedContribution)
        XCTAssertFalse(dashboard.annualBonusContributionConfirmed)

        XCTAssertTrue(
            appState.saveExpensePlan(
                monthlyExpense: 6_000,
                annualIrregularExpense: 10_000
            )
        )
        XCTAssertTrue(
            appState.saveIncomePlan(
                monthlyIncome: 25_000,
                annualIncome: 50_000
            )
        )

        dashboard = adapter.dashboard(
            transactions: transactions,
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )
        let packet = adapter.analysisPacket(
            transactions: transactions,
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )

        XCTAssertEqual(dashboard.monthlyIncome, 25_000)
        XCTAssertEqual(dashboard.annualIncome, 50_000)
        XCTAssertEqual(dashboard.monthlyExpense, 6_000)
        XCTAssertEqual(dashboard.annualIrregularExpense, 10_000)
        XCTAssertEqual(dashboard.annualExpense, 82_000)
        XCTAssertEqual(dashboard.monthlyContribution, 19_000)
        XCTAssertEqual(dashboard.annualBonusContribution, 40_000)
        XCTAssertEqual(dashboard.annualPlannedContribution, 268_000)
        XCTAssertEqual(packet.fireState.annualSpending, 82_000)
        XCTAssertEqual(
            packet.fireState.confirmedMonthlyContribution,
            19_000
        )
        XCTAssertEqual(
            packet.fireState.confirmedAnnualBonusContribution,
            40_000
        )
        XCTAssertEqual(dashboard.monthlyIncomeReference.median, 20_000)
        XCTAssertEqual(dashboard.ledgerAnnualExpense, 72_000)
    }

    func testDashboardUsesLatestCompletePlanningPairsWithoutMixingDuplicates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let orphan = Date(timeIntervalSince1970: 300)

        func insert(_ key: String, _ value: Double, _ date: Date) {
            context.insert(
                AppMetadataEntity(
                    key: key,
                    dateValue: date,
                    doubleValue: value
                )
            )
        }

        insert(AppMetadataKey.plannedMonthlyIncome, 10_000, older)
        insert(AppMetadataKey.plannedAnnualIncome, 20_000, older)
        insert(AppMetadataKey.plannedMonthlyIncome, 30_000, newer)
        insert(AppMetadataKey.plannedAnnualIncome, 40_000, newer)
        insert(AppMetadataKey.plannedMonthlyIncome, 99_000, orphan)
        insert(AppMetadataKey.plannedMonthlyExpense, 1_000, older)
        insert(
            AppMetadataKey.plannedAnnualIrregularExpense,
            2_000,
            older
        )
        insert(AppMetadataKey.plannedMonthlyExpense, 9_000, orphan)
        try context.save()

        let adapter = CoreDataAdapter(context: context)
        let dashboard = adapter.dashboard(
            transactions: [],
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )
        let packet = adapter.analysisPacket(
            transactions: [],
            latestAssetSnapshot: nil,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )

        XCTAssertEqual(dashboard.monthlyIncome, 30_000)
        XCTAssertEqual(dashboard.annualIncome, 40_000)
        XCTAssertEqual(dashboard.monthlyExpense, 1_000)
        XCTAssertEqual(dashboard.annualIrregularExpense, 2_000)
        XCTAssertEqual(dashboard.annualExpense, 14_000)
        XCTAssertEqual(
            packet.fireState.confirmedMonthlyContribution,
            29_000
        )
        XCTAssertEqual(
            packet.fireState.confirmedAnnualBonusContribution,
            38_000
        )
    }

    func testEncryptedBackupRoundTripPreservesFrozenRates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let snapshot = AssetSnapshotEntity(
            capturedAt: Date(timeIntervalSince1970: 1_783_270_800),
            cashCNY: 1_000,
            cashUSD: 100,
            cashHKD: 0,
            cashValueInCNY: 1_725,
            liabilityPrincipalCNY: 0,
            positionsCNY: 0,
            isComplete: true,
            exchangeRateState: .manual,
            exchangeRateAsOf: Date(timeIntervalSince1970: 1_783_270_800),
            exchangeRateFetchedAt: Date(timeIntervalSince1970: 1_783_270_900),
            exchangeRateSource: "手动",
            usdToCNY: 7.25,
            hkdToCNY: 0.94
        )
        let annualBonus = AppMetadataEntity(
            key: AppMetadataKey.confirmedAnnualBonusContribution,
            doubleValue: 80_000
        )
        let plannedAnnualSpending = AppMetadataEntity(
            key: AppMetadataKey.plannedAnnualSpending,
            doubleValue: 180_000
        )
        let option = InstrumentEntity(
            code: nil,
            name: "公司期权",
            kind: .option,
            currency: "USD"
        )
        let optionPosition = PositionSnapshotEntity(
            assetSnapshotID: snapshot.id,
            instrumentID: option.id,
            originalMarketValue: 10_000,
            cnyMarketValue: 72_500,
            capturedAt: snapshot.capturedAt,
            recognitionConfidence: 1,
            sourceCount: 1,
            wasManuallyConfirmed: true
        )
        snapshot.positionsCNY = 72_500
        context.insert(snapshot)
        context.insert(annualBonus)
        context.insert(plannedAnnualSpending)
        context.insert(option)
        context.insert(optionPosition)
        try context.save()

        let service = EncryptedBackupService(
            context: context,
            keyProvider: FixedBackupKeyProvider()
        )
        let document = try service.createDocument()
        let decoded = try service.decode(document: document)
        let archived = try XCTUnwrap(decoded.assetSnapshots.first)

        XCTAssertEqual(archived.exchangeRateSource, "手动")
        XCTAssertEqual(archived.usdToCNY, 7.25)
        XCTAssertEqual(archived.hkdToCNY, 0.94)
        XCTAssertEqual(
            decoded.instruments.first?.kind,
            FIRE.AssetKind.option.rawValue
        )
        XCTAssertEqual(decoded.positions.first?.cnyMarketValue, 72_500)
        XCTAssertEqual(
            decoded.metadata.first(where: {
                $0.key == AppMetadataKey.confirmedAnnualBonusContribution
            })?.doubleValue,
            80_000
        )
        XCTAssertEqual(
            decoded.metadata.first(where: {
                $0.key == AppMetadataKey.plannedAnnualSpending
            })?.doubleValue,
            180_000
        )

        let plan = try service.prepareRestore(document: document)
        try service.restore(plan)
        let restored = try XCTUnwrap(
            context.fetch(FetchDescriptor<AssetSnapshotEntity>()).first
        )
        XCTAssertEqual(restored.exchangeRateSource, "手动")
        XCTAssertEqual(restored.usdToCNY, 7.25)
        XCTAssertEqual(restored.hkdToCNY, 0.94)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<InstrumentEntity>()).first?.kind,
            .option
        )
        XCTAssertEqual(
            try context.fetch(
                FetchDescriptor<PositionSnapshotEntity>()
            ).first?.cnyMarketValue,
            72_500
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AppMetadataEntity>())
                .first(where: {
                    $0.key == AppMetadataKey.confirmedAnnualBonusContribution
                })?.doubleValue,
            80_000
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AppMetadataEntity>())
                .first(where: {
                    $0.key == AppMetadataKey.plannedAnnualSpending
                })?.doubleValue,
            180_000
        )
    }

    func testBackupCreationRejectsInvalidPlannedAnnualSpendingMetadata() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let metadata = AppMetadataEntity(
            key: AppMetadataKey.plannedAnnualSpending
        )
        context.insert(metadata)
        let service = EncryptedBackupService(
            context: context,
            keyProvider: FixedBackupKeyProvider()
        )

        for invalidValue in [nil, 0, -1, 1e308] as [Double?] {
            metadata.doubleValue = invalidValue
            try context.save()

            XCTAssertThrowsError(
                try service.createDocument()
            ) { error in
                guard case BackupError.invalidData(let reason) = error else {
                    return XCTFail("应拒绝无效的规划年度支出元数据。")
                }
                XCTAssertTrue(reason.contains("规划年度支出"))
            }
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(FIREModelSchema.models)
        let configuration = ModelConfiguration(
            "FIRETests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }

    private func decimalDouble(_ value: Decimal?) -> Double {
        guard let value else { return 0 }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    private func reportTestDate(
        _ year: Int,
        _ month: Int,
        _ day: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }
}

private struct FixedBackupKeyProvider: BackupKeyProviding {
    func key() throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0x42, count: 32))
    }
}
