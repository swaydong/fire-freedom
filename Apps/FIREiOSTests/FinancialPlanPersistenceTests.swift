import CryptoKit
import SwiftData
import XCTest
@testable import FIRE

@MainActor
final class FinancialPlanPersistenceTests: XCTestCase {
    func testIncomePlanSavesPairDeduplicatesAndClearsLegacyValues() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        let settings = [
            FIRESettingsEntity(
                confirmedMonthlyContribution: 8_000,
                contributionConfirmedAt: .now
            ),
            FIRESettingsEntity(
                confirmedMonthlyContribution: 9_000,
                contributionConfirmedAt: .now
            ),
        ]
        settings.forEach(context.insert)
        insertMetadata(
            key: AppMetadataKey.plannedMonthlyIncome,
            values: [1, 2],
            into: context
        )
        insertMetadata(
            key: AppMetadataKey.plannedAnnualIncome,
            values: [3, 4],
            into: context
        )
        insertMetadata(
            key: AppMetadataKey.confirmedAnnualBonusContribution,
            values: [50_000, 60_000],
            into: context
        )
        try context.save()

        XCTAssertTrue(
            appState.saveIncomePlan(
                monthlyIncome: 20_000,
                annualIncome: 100_000
            )
        )

        var metadata = try context.fetch(
            FetchDescriptor<AppMetadataEntity>()
        )
        let monthly = metadata.filter {
            $0.key == AppMetadataKey.plannedMonthlyIncome
        }
        let annual = metadata.filter {
            $0.key == AppMetadataKey.plannedAnnualIncome
        }
        XCTAssertEqual(monthly.count, 1)
        XCTAssertEqual(monthly.first?.doubleValue, 20_000)
        XCTAssertEqual(annual.count, 1)
        XCTAssertEqual(annual.first?.doubleValue, 100_000)
        XCTAssertEqual(monthly.first?.dateValue, annual.first?.dateValue)
        XCTAssertFalse(
            metadata.contains {
                $0.key == AppMetadataKey.confirmedAnnualBonusContribution
            }
        )
        XCTAssertTrue(
            settings.allSatisfy {
                $0.confirmedMonthlyContribution == nil
                    && $0.contributionConfirmedAt == nil
            }
        )
        XCTAssertFalse(
            appState.saveIncomePlan(
                monthlyIncome: 1e308,
                annualIncome: 0
            )
        )
        metadata = try context.fetch(FetchDescriptor<AppMetadataEntity>())
        XCTAssertEqual(
            metadata.first {
                $0.key == AppMetadataKey.plannedMonthlyIncome
            }?.doubleValue,
            20_000
        )

        settings.forEach {
            $0.confirmedMonthlyContribution = 7_000
            $0.contributionConfirmedAt = .now
        }
        context.insert(
            AppMetadataEntity(
                key: AppMetadataKey.confirmedAnnualBonusContribution,
                doubleValue: 40_000
            )
        )
        try context.save()

        XCTAssertTrue(appState.clearIncomePlan())
        metadata = try context.fetch(FetchDescriptor<AppMetadataEntity>())
        let removedKeys: Set<String> = [
            AppMetadataKey.plannedMonthlyIncome,
            AppMetadataKey.plannedAnnualIncome,
            AppMetadataKey.confirmedAnnualBonusContribution,
        ]
        XCTAssertFalse(metadata.contains { removedKeys.contains($0.key) })
        XCTAssertTrue(
            settings.allSatisfy {
                $0.confirmedMonthlyContribution == nil
                    && $0.contributionConfirmedAt == nil
            }
        )
    }

    func testLegacyContributionInputsRejectUnrepresentableAmounts() throws {
        let container = try makeContainer()
        let appState = FIREAppState()
        appState.configure(context: container.mainContext)

        XCTAssertFalse(appState.saveMonthlyContribution(1e308))
        XCTAssertFalse(appState.saveAnnualBonusContribution(1e308))
    }

    func testBackupCreationRejectsPlanPairFromDifferentSaveTimes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(
            AppMetadataEntity(
                key: AppMetadataKey.plannedMonthlyIncome,
                dateValue: Date(timeIntervalSince1970: 100),
                doubleValue: 10_000
            )
        )
        context.insert(
            AppMetadataEntity(
                key: AppMetadataKey.plannedAnnualIncome,
                dateValue: Date(timeIntervalSince1970: 101),
                doubleValue: 20_000
            )
        )
        try context.save()
        let service = EncryptedBackupService(
            context: context,
            keyProvider: FinancialPlanBackupKeyProvider()
        )

        XCTAssertThrowsError(try service.createDocument()) { error in
            guard case BackupError.invalidData(let reason) = error else {
                return XCTFail("应拒绝不是同一次保存的规划数据。")
            }
            XCTAssertTrue(reason.contains("不是同一次保存"))
        }
    }

    func testExpensePlanRequiresPositiveTotalAndClearsLegacyValues() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = FIREAppState()
        appState.configure(context: context)
        insertMetadata(
            key: AppMetadataKey.plannedMonthlyExpense,
            values: [1, 2],
            into: context
        )
        insertMetadata(
            key: AppMetadataKey.plannedAnnualIrregularExpense,
            values: [3, 4],
            into: context
        )
        insertMetadata(
            key: AppMetadataKey.plannedAnnualSpending,
            values: [120_000, 130_000],
            into: context
        )
        try context.save()

        XCTAssertFalse(
            appState.saveExpensePlan(
                monthlyExpense: 0,
                annualIrregularExpense: 0
            )
        )
        XCTAssertTrue(
            appState.saveExpensePlan(
                monthlyExpense: 0,
                annualIrregularExpense: 24_000
            )
        )

        var metadata = try context.fetch(
            FetchDescriptor<AppMetadataEntity>()
        )
        let monthly = metadata.filter {
            $0.key == AppMetadataKey.plannedMonthlyExpense
        }
        let irregular = metadata.filter {
            $0.key == AppMetadataKey.plannedAnnualIrregularExpense
        }
        XCTAssertEqual(monthly.count, 1)
        XCTAssertEqual(monthly.first?.doubleValue, 0)
        XCTAssertEqual(irregular.count, 1)
        XCTAssertEqual(irregular.first?.doubleValue, 24_000)
        XCTAssertEqual(monthly.first?.dateValue, irregular.first?.dateValue)
        XCTAssertFalse(
            metadata.contains {
                $0.key == AppMetadataKey.plannedAnnualSpending
            }
        )

        XCTAssertFalse(
            appState.saveExpensePlan(
                monthlyExpense: 1e308,
                annualIrregularExpense: 0
            )
        )
        metadata = try context.fetch(FetchDescriptor<AppMetadataEntity>())
        XCTAssertEqual(
            metadata.first {
                $0.key == AppMetadataKey.plannedAnnualIrregularExpense
            }?.doubleValue,
            24_000
        )

        context.insert(
            AppMetadataEntity(
                key: AppMetadataKey.plannedAnnualSpending,
                doubleValue: 180_000
            )
        )
        try context.save()
        XCTAssertTrue(appState.clearExpensePlan())
        metadata = try context.fetch(FetchDescriptor<AppMetadataEntity>())
        let removedKeys: Set<String> = [
            AppMetadataKey.plannedMonthlyExpense,
            AppMetadataKey.plannedAnnualIrregularExpense,
            AppMetadataKey.plannedAnnualSpending,
        ]
        XCTAssertFalse(metadata.contains { removedKeys.contains($0.key) })
    }

    func testBackupCreationRequiresValidPairedPlans() throws {
        try assertInvalidBackup(
            metadata: [
                (AppMetadataKey.plannedMonthlyIncome, 10_000),
            ],
            reasonContains: "收入规划"
        )
        try assertInvalidBackup(
            metadata: [
                (AppMetadataKey.plannedMonthlyIncome, -1),
                (AppMetadataKey.plannedAnnualIncome, 0),
            ],
            reasonContains: "收入规划"
        )
        try assertInvalidBackup(
            metadata: [
                (AppMetadataKey.plannedMonthlyExpense, 0),
                (AppMetadataKey.plannedAnnualIrregularExpense, 0),
            ],
            reasonContains: "支出规划"
        )
        try assertInvalidBackup(
            metadata: [
                (AppMetadataKey.plannedAnnualIrregularExpense, 12_000),
            ],
            reasonContains: "支出规划"
        )
        try assertInvalidBackup(
            metadata: [
                (AppMetadataKey.plannedMonthlyExpense, 1e308),
                (AppMetadataKey.plannedAnnualIrregularExpense, 0),
            ],
            reasonContains: "支出规划"
        )
        try assertInvalidBackup(
            metadata: [
                (AppMetadataKey.plannedMonthlyIncome, 10_000),
                (AppMetadataKey.plannedMonthlyIncome, 20_000),
                (AppMetadataKey.plannedAnnualIncome, 0),
            ],
            reasonContains: "元数据键重复"
        )

        let valid = try makeBackup(
            metadata: [
                (AppMetadataKey.plannedMonthlyIncome, 0),
                (AppMetadataKey.plannedAnnualIncome, 0),
                (AppMetadataKey.plannedMonthlyExpense, 0),
                (AppMetadataKey.plannedAnnualIrregularExpense, 12_000),
            ]
        )
        XCTAssertNoThrow(
            try valid.service.prepareRestore(document: valid.document)
        )
    }

    private func assertInvalidBackup(
        metadata: [(key: String, value: Double?)],
        reasonContains expectedReason: String
    ) throws {
        XCTAssertThrowsError(
            try makeBackup(metadata: metadata)
        ) { error in
            guard case BackupError.invalidData(let reason) = error else {
                return XCTFail("应拒绝无效的规划元数据。")
            }
            XCTAssertTrue(reason.contains(expectedReason))
        }
    }

    private func makeBackup(
        metadata: [(key: String, value: Double?)]
    ) throws -> (
        service: EncryptedBackupService,
        document: FIREBackupDocument
    ) {
        let container = try makeContainer()
        let context = container.mainContext
        for item in metadata {
            context.insert(
                AppMetadataEntity(
                    key: item.key,
                    doubleValue: item.value
                )
            )
        }
        try context.save()
        let service = EncryptedBackupService(
            context: context,
            keyProvider: FinancialPlanBackupKeyProvider()
        )
        return (service, try service.createDocument())
    }

    private func insertMetadata(
        key: String,
        values: [Double],
        into context: ModelContext
    ) {
        for value in values {
            context.insert(
                AppMetadataEntity(key: key, doubleValue: value)
            )
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(FIREModelSchema.models)
        let configuration = ModelConfiguration(
            "FinancialPlanTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }
}

private struct FinancialPlanBackupKeyProvider: BackupKeyProviding {
    func key() throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0x27, count: 32))
    }
}
