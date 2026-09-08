import CryptoKit
import FIRECore
import SwiftData
import XCTest
@testable import FIRE

@MainActor
final class KapiSyncPersistenceTests: XCTestCase {
    func testPreviewApplyAndUndoPreserveScopeAndStableIDs() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let service = KapiSyncService(context: context)
        let coverage = TransactionCoverage(
            start: date(2026, 3, 1),
            end: date(2026, 3, 31)
        )
        let unchanged = transaction(
            date: date(2026, 3, 5, 9),
            amount: 30,
            note: "咖啡"
        )
        let changedOld = transaction(
            date: date(2026, 3, 6, 18),
            amount: 100,
            note: "打车"
        )
        let changedIncoming = transaction(
            date: changedOld.occurredAt,
            amount: 120,
            note: "打车"
        )
        let unchangedEntity = legacyEntity(unchanged)
        let changedEntity = legacyEntity(changedOld)
        let otherSource = legacyEntity(
            transaction(
                date: date(2026, 3, 7),
                amount: 88,
                note: "人工流水"
            )
        )
        otherSource.sourceRawValue = "manual"
        let outside = legacyEntity(
            transaction(
                date: date(2026, 2, 20),
                amount: 66,
                note: "区间外"
            )
        )
        [unchangedEntity, changedEntity, otherSource, outside].forEach(
            context.insert
        )
        context.insert(
            AppMetadataEntity(
                key: "transactions.coverage.start",
                dateValue: coverage.start
            )
        )
        context.insert(
            AppMetadataEntity(
                key: "transactions.coverage.end",
                dateValue: coverage.end
            )
        )
        try context.save()

        let preview = try service.preview(
            result: importResult(
                [unchanged, changedIncoming],
                coverage: coverage
            ),
            fileName: "咔皮记账_20260301_20260331.xlsx"
        )

        XCTAssertEqual(preview.reconciliation.unchanged.count, 1)
        XCTAssertEqual(preview.reconciliation.added.count, 1)
        XCTAssertEqual(preview.reconciliation.removed.count, 1)
        XCTAssertEqual(preview.legacyUpgradeCount, 1)
        XCTAssertEqual(
            preview.reconciliation.possibleModifications.count,
            1
        )
        XCTAssertThrowsError(
            try service.apply(
                preview,
                confirmsCompleteUnfilteredExport: false
            )
        )
        XCTAssertTrue(
            try context.fetch(
                FetchDescriptor<KapiImportBatchEntity>()
            ).isEmpty
        )

        let applied = try service.apply(
            preview,
            confirmsCompleteUnfilteredExport: true
        )
        XCTAssertEqual(applied.receipt.addedCount, 1)
        XCTAssertEqual(applied.receipt.removedCount, 1)

        var current = try context.fetch(
            FetchDescriptor<TransactionEntity>()
        )
        XCTAssertTrue(current.contains { $0.id == unchangedEntity.id })
        XCTAssertFalse(current.contains { $0.id == changedEntity.id })
        XCTAssertTrue(current.contains { $0.id == otherSource.id })
        XCTAssertTrue(current.contains { $0.id == outside.id })
        XCTAssertEqual(
            current.first { $0.id == unchangedEntity.id }?.ledgerName,
            "日常账本"
        )

        let reverted = try service.undoLatest()
        XCTAssertTrue(reverted.isReverted)
        current = try context.fetch(FetchDescriptor<TransactionEntity>())
        XCTAssertTrue(current.contains { $0.id == unchangedEntity.id })
        XCTAssertTrue(current.contains { $0.id == changedEntity.id })
        XCTAssertTrue(current.contains { $0.id == otherSource.id })
        XCTAssertTrue(current.contains { $0.id == outside.id })
        XCTAssertEqual(try service.latestReceipt()?.canUndo, false)
        XCTAssertThrowsError(try service.undoLatest())
    }

    func testDuplicateMultiplicityTwoToOneKeepsOneExistingID() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let service = KapiSyncService(context: context)
        let coverage = TransactionCoverage(
            start: date(2026, 4, 1),
            end: date(2026, 4, 30)
        )
        let first = transaction(
            date: date(2026, 4, 8, 12),
            amount: 45,
            note: "午餐"
        )
        var second = first
        second.id = UUID()

        let firstPreview = try service.preview(
            result: importResult([first, second], coverage: coverage),
            fileName: "咔皮记账_20260401_20260430.xlsx"
        )
        _ = try service.apply(
            firstPreview,
            confirmsCompleteUnfilteredExport: true
        )
        let priorIDs = Set(
            try context.fetch(FetchDescriptor<TransactionEntity>())
                .map(\.id)
        )

        var only = first
        only.id = UUID()
        let secondPreview = try service.preview(
            result: importResult([only], coverage: coverage),
            fileName: "咔皮记账_20260401_20260430.xlsx"
        )
        let duplicateChange = try XCTUnwrap(
            secondPreview.duplicateMultiplicityChanges.first
        )
        XCTAssertEqual(duplicateChange.previousCount, 2)
        XCTAssertEqual(duplicateChange.incomingCount, 1)
        XCTAssertEqual(secondPreview.reconciliation.unchanged.count, 1)
        XCTAssertEqual(secondPreview.reconciliation.removed.count, 1)

        _ = try service.apply(
            secondPreview,
            confirmsCompleteUnfilteredExport: true
        )
        let current = try context.fetch(
            FetchDescriptor<TransactionEntity>()
        )
        XCTAssertEqual(current.count, 1)
        XCTAssertTrue(priorIDs.contains(current[0].id))
    }

    func testStalePreviewIsRejectedWithoutCreatingBatch() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let service = KapiSyncService(context: context)
        let coverage = TransactionCoverage(
            start: date(2026, 5, 1),
            end: date(2026, 5, 31)
        )
        let incoming = transaction(
            date: date(2026, 5, 2),
            amount: 20,
            note: "早餐"
        )
        let preview = try service.preview(
            result: importResult([incoming], coverage: coverage),
            fileName: "咔皮记账_20260501_20260531.xlsx"
        )
        context.insert(
            legacyEntity(
                transaction(
                    date: date(2026, 5, 3),
                    amount: 10,
                    note: "预览后新增"
                )
            )
        )
        try context.save()

        XCTAssertThrowsError(
            try service.apply(
                preview,
                confirmsCompleteUnfilteredExport: true
            )
        ) { error in
            guard case KapiSyncError.stalePreview = error else {
                return XCTFail("应拒绝过期预览，实际为 \(error)")
            }
        }
        XCTAssertTrue(
            try context.fetch(
                FetchDescriptor<KapiImportBatchEntity>()
            ).isEmpty
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<TransactionEntity>()).count,
            1
        )
    }

    func testEncryptedBackupPreservesSyncHistoryAndUndo() throws {
        let sourceContainer = try makeContainer()
        let sourceContext = sourceContainer.mainContext
        let service = KapiSyncService(context: sourceContext)
        let coverage = TransactionCoverage(
            start: date(2026, 6, 1),
            end: date(2026, 6, 30)
        )
        let previous = transaction(
            date: date(2026, 6, 10),
            amount: 100,
            note: "打车"
        )
        let previousEntity = legacyEntity(previous)
        sourceContext.insert(previousEntity)
        try sourceContext.save()

        let incoming = transaction(
            date: previous.occurredAt,
            amount: 120,
            note: "打车"
        )
        let preview = try service.preview(
            result: importResult([incoming], coverage: coverage),
            fileName: "咔皮记账_20260601_20260630.xlsx"
        )
        _ = try service.apply(
            preview,
            confirmsCompleteUnfilteredExport: true
        )

        let keyProvider = LedgerSyncBackupKeyProvider()
        let document = try EncryptedBackupService(
            context: sourceContext,
            keyProvider: keyProvider
        ).createDocument()

        let targetContainer = try makeContainer()
        let targetContext = targetContainer.mainContext
        let backupService = EncryptedBackupService(
            context: targetContext,
            keyProvider: keyProvider
        )
        try backupService.restore(
            backupService.prepareRestore(document: document)
        )

        let restoredSync = KapiSyncService(context: targetContext)
        XCTAssertEqual(try restoredSync.latestReceipt()?.canUndo, true)
        _ = try restoredSync.undoLatest()
        let restoredTransactions = try targetContext.fetch(
            FetchDescriptor<TransactionEntity>()
        )
        XCTAssertEqual(restoredTransactions.count, 1)
        XCTAssertEqual(restoredTransactions[0].id, previousEntity.id)
        XCTAssertEqual(restoredTransactions[0].amount, 100)
    }

    private func importResult(
        _ transactions: [TransactionRecord],
        coverage: TransactionCoverage
    ) -> KapiImportResult {
        KapiImportResult(
            transactions: transactions,
            sheetName: "收支账单",
            exportCoverage: coverage
        )
    }

    private func transaction(
        date: Date,
        amount: Decimal,
        note: String
    ) -> TransactionRecord {
        var value = TransactionRecord(
            occurredAt: date,
            direction: .expense,
            amount: amount,
            primaryCategory: "餐饮",
            secondaryCategory: "",
            merchantNote: note,
            tags: ["日常"],
            accountName: "支付宝",
            ledgerName: "日常账本",
            includedInCashFlow: true,
            includedInBudget: true
        )
        value.fingerprint = TransactionFingerprint.make(for: value)
        return value
    }

    private func legacyEntity(
        _ value: TransactionRecord
    ) -> TransactionEntity {
        TransactionEntity(
            id: value.id,
            fingerprint: value.fingerprint,
            transactionDate: value.occurredAt,
            directionRawValue: "支出",
            amount: value.amount.doubleValue,
            category: value.primaryCategory,
            subcategory: value.secondaryCategory,
            merchant: "",
            note: value.merchantNote,
            account: value.accountName,
            isIncluded: value.includedInCashFlow
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour
            )
        )!
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(FIREModelSchema.models)
        let configuration = ModelConfiguration(
            "KapiSyncTests-\(UUID().uuidString)",
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

private struct LedgerSyncBackupKeyProvider: BackupKeyProviding {
    func key() throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0x71, count: 32))
    }
}
