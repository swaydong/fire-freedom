import FIRECore
import Foundation
import CryptoKit
import SwiftData
import XCTest
@testable import FIRE

@MainActor
final class MonthlyProgressDashboardTests: XCTestCase {
    func testAnalysisPreservesPositionKindsWhileFIREUsesFrozenTotal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let capturedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = AssetSnapshotEntity(
            capturedAt: capturedAt,
            cashCNY: 20,
            cashValueInCNY: 20,
            liabilityPrincipalCNY: 0,
            positionsCNY: 200,
            isComplete: true,
            exchangeRateState: .current,
            exchangeRateAsOf: capturedAt
        )
        let instrument = InstrumentEntity(
            code: "TEST",
            name: "测试股票",
            kind: .stock,
            currency: "CNY"
        )
        let position = PositionSnapshotEntity(
            assetSnapshotID: snapshot.id,
            instrumentID: instrument.id,
            originalMarketValue: 100,
            cnyMarketValue: 100,
            capturedAt: capturedAt,
            recognitionConfidence: 1,
            sourceCount: 1,
            wasManuallyConfirmed: true
        )

        let packet = CoreDataAdapter(context: context).analysisPacket(
            transactions: [],
            latestAssetSnapshot: snapshot,
            allPositions: [position],
            instruments: [instrument],
            liabilities: [],
            settings: nil,
            reportDate: capturedAt
        )

        XCTAssertEqual(packet.assetSnapshot.positions.count, 1)
        XCTAssertEqual(packet.assetSnapshot.positions[0].instrument.kind, .stock)
        XCTAssertEqual(packet.assetSnapshot.positions[0].marketValueInCNY, 100)
        XCTAssertEqual(packet.fireState.investableNetWorth, 220)
        XCTAssertTrue(
            packet.assetSnapshot.dataIssues.contains {
                $0.contains("产品明细与资产快照不一致")
            }
        )
    }

    func testDashboardHistoryUsesCurrentTargetAndFrozenSnapshots() throws {
        let container = try makeContainer()
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: month,
                    day: day,
                    hour: 12
                )
            )!
        }

        let january = AssetSnapshotEntity(
            capturedAt: date(1, 31),
            cashCNY: 200_000,
            cashValueInCNY: 200_000,
            liabilityPrincipalCNY: 0,
            positionsCNY: 800_000,
            isComplete: true,
            exchangeRateState: .current,
            exchangeRateAsOf: date(1, 31)
        )
        let february = AssetSnapshotEntity(
            capturedAt: date(2, 28),
            cashCNY: 200_000,
            cashValueInCNY: 200_000,
            liabilityPrincipalCNY: 0,
            positionsCNY: 900_000,
            isComplete: true,
            exchangeRateState: .current,
            exchangeRateAsOf: date(2, 28)
        )
        let incompleteMarch = AssetSnapshotEntity(
            capturedAt: date(3, 31),
            cashCNY: 300_000,
            cashValueInCNY: 300_000,
            liabilityPrincipalCNY: 0,
            positionsCNY: 1_000_000,
            isComplete: false,
            exchangeRateState: .current,
            exchangeRateAsOf: date(3, 31)
        )
        let plannedSpending = AppMetadataEntity(
            key: AppMetadataKey.plannedAnnualSpending,
            doubleValue: 175_000
        )
        [january, february, incompleteMarch].forEach(context.insert)
        context.insert(plannedSpending)
        try context.save()

        let adapter = CoreDataAdapter(context: context)
        var dashboard = adapter.dashboard(
            transactions: [],
            latestAssetSnapshot: february,
            assetSnapshots: [incompleteMarch, january, february],
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )

        XCTAssertEqual(dashboard.monthlyProgress.count, 2)
        XCTAssertEqual(
            double(dashboard.monthlyProgress[0].fireProgress),
            0.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            double(dashboard.monthlyProgress[1].investableNetWorth),
            1_100_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            dashboard.investableNetWorth,
            double(dashboard.monthlyProgress.last?.investableNetWorth),
            accuracy: 0.001
        )
        XCTAssertEqual(
            double(dashboard.monthlyProgress[1].changeAmount),
            100_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            double(dashboard.monthlyProgress[1].changeRate),
            0.1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            double(dashboard.monthlyProgress[1].fireProgressChange),
            0.02,
            accuracy: 0.000_001
        )

        plannedSpending.doubleValue = 350_000
        try context.save()
        dashboard = adapter.dashboard(
            transactions: [],
            latestAssetSnapshot: february,
            assetSnapshots: [january, february],
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )

        XCTAssertEqual(
            double(dashboard.monthlyProgress[1].investableNetWorth),
            1_100_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            double(dashboard.monthlyProgress[1].changeAmount),
            100_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            double(dashboard.monthlyProgress[1].fireProgress),
            0.11,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            double(dashboard.monthlyProgress[1].fireProgressChange),
            0.01,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            dashboard.investableNetWorth,
            double(dashboard.monthlyProgress.last?.investableNetWorth),
            accuracy: 0.001
        )

        let progressBeforeBackup = dashboard.monthlyProgress
        let backupService = EncryptedBackupService(
            context: context,
            keyProvider: MonthlyProgressBackupKeyProvider()
        )
        let document = try backupService.createDocument()
        let restorePlan = try backupService.prepareRestore(document: document)
        try backupService.restore(restorePlan)

        let restoredSnapshots = try context.fetch(
            FetchDescriptor<AssetSnapshotEntity>()
        )
        let restoredLatest = try XCTUnwrap(
            restoredSnapshots
                .filter(\.isComplete)
                .max(by: { $0.capturedAt < $1.capturedAt })
        )
        let restoredDashboard = adapter.dashboard(
            transactions: [],
            latestAssetSnapshot: restoredLatest,
            assetSnapshots: restoredSnapshots,
            allPositions: [],
            instruments: [],
            liabilities: [],
            settings: nil
        )

        XCTAssertEqual(restoredDashboard.monthlyProgress, progressBeforeBackup)
        XCTAssertEqual(
            restoredDashboard.investableNetWorth,
            double(restoredDashboard.monthlyProgress.last?.investableNetWorth),
            accuracy: 0.001
        )
    }

    private func double(_ value: Decimal?) -> Double {
        guard let value else { return .nan }
        return NSDecimalNumber(decimal: value).doubleValue
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(FIREModelSchema.models)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }
}

private struct MonthlyProgressBackupKeyProvider: BackupKeyProviding {
    func key() throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0xA5, count: 32))
    }
}
