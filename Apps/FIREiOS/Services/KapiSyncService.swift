import CryptoKit
import FIRECore
import Foundation
import SwiftData

enum KapiSyncError: LocalizedError {
    case missingCoverage
    case transactionOutsideCoverage(row: Int?)
    case completeExportNotConfirmed
    case stalePreview
    case noReversibleSync
    case syncChangedAfterApply
    case corruptHistory

    var errorDescription: String? {
        switch self {
        case .missingCoverage:
            "无法从文件名读取导出日期区间。请直接使用咔皮生成的原始文件名重新导入。"
        case let .transactionOutsideCoverage(row):
            if let row {
                "第 \(row) 行流水不在文件名声明的日期区间内，本次同步已停止。"
            } else {
                "存在不在文件名声明日期区间内的流水，本次同步已停止。"
            }
        case .completeExportNotConfirmed:
            "请先确认这是全部账本且未经过筛选的完整导出。"
        case .stalePreview:
            "预览后账本已经发生变化，请重新选择文件生成差异。"
        case .noReversibleSync:
            "当前没有可以撤回的最近一次账单同步。"
        case .syncChangedAfterApply:
            "同步后的账单已经发生变化，无法安全撤回。"
        case .corruptHistory:
            "账单同步历史无法读取，为避免覆盖现有数据，本次操作已停止。"
        }
    }
}

struct KapiSyncApplicationResult {
    let summary: ImportSummary
    let receipt: KapiSyncReceipt
}

@MainActor
final class KapiSyncService {
    static let sourceScopeID = "kapi-all"

    private enum MetadataKey {
        static let coverageStart = "transactions.coverage.start"
        static let coverageEnd = "transactions.coverage.end"
    }

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func previewWorkbook(at url: URL) throws -> KapiSyncPreview {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let result = try KapiWorkbookImporter().importWorkbook(at: url)
        let fileData = try Data(contentsOf: url, options: .mappedIfSafe)
        return try preview(
            result: result,
            fileName: url.lastPathComponent,
            fileSHA256: Self.sha256(fileData)
        )
    }

    func preview(
        result: KapiImportResult,
        fileName: String,
        fileSHA256: String = ""
    ) throws -> KapiSyncPreview {
        guard let coverage = result.exportCoverage else {
            throw KapiSyncError.missingCoverage
        }
        try validate(result.snapshotItems, coverage: coverage)
        let existing = try managedTransactions(in: coverage)
        return makePreview(
            id: UUID(),
            fileName: fileName,
            fileSHA256: fileSHA256,
            coverage: coverage,
            importedAt: result.importedAt,
            incomingItems: result.snapshotItems,
            existing: existing
        )
    }

    func apply(
        _ preview: KapiSyncPreview,
        confirmsCompleteUnfilteredExport: Bool
    ) throws -> KapiSyncApplicationResult {
        guard confirmsCompleteUnfilteredExport else {
            throw KapiSyncError.completeExportNotConfirmed
        }

        let existing = try managedTransactions(in: preview.coverage)
        let currentToken = try versionToken(for: existing)
        guard currentToken == preview.baselineVersionToken else {
            throw KapiSyncError.stalePreview
        }
        let currentPreview = makePreview(
            id: preview.id,
            fileName: preview.fileName,
            fileSHA256: preview.fileSHA256,
            coverage: preview.coverage,
            importedAt: preview.importedAt,
            incomingItems: preview.incomingItems,
            existing: existing
        )
        guard currentPreview.baselineVersionToken
                == preview.baselineVersionToken else {
            throw KapiSyncError.stalePreview
        }

        let batchID = UUID()
        let appliedAt = Date()
        let previousCoverage = try storedCoverage()
        let replacedRowsData = try Self.encodeRows(existing)
        let existingByID = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, $0) }
        )
        var appliedEntities: [TransactionEntity] = []
        let summary = StoredKapiDiffSummary(
            unchangedCount: currentPreview.reconciliation.unchanged.count,
            addedCount: currentPreview.reconciliation.added.count,
            removedCount: currentPreview.reconciliation.removed.count
        )
        let diffSummaryData = try Self.encoder.encode(summary)
        var coverageHadGap = false

        do {
            try context.transaction {
                for match in currentPreview.reconciliation.unchanged {
                    guard let entity = existingByID[
                        match.previous.transaction.id
                    ] else {
                        throw KapiSyncError.stalePreview
                    }
                    try update(
                        entity,
                        from: match.incoming,
                        batchID: batchID,
                        preservesDuplicateDecision: true
                    )
                    appliedEntities.append(entity)
                }

                for item in currentPreview.reconciliation.removed {
                    guard let entity = existingByID[item.transaction.id] else {
                        throw KapiSyncError.stalePreview
                    }
                    context.delete(entity)
                }

                for item in currentPreview.reconciliation.added {
                    let entity = try makeEntity(
                        from: item,
                        batchID: batchID
                    )
                    context.insert(entity)
                    appliedEntities.append(entity)
                }

                coverageHadGap = try mergeCoverage(preview.coverage)
                let appliedRowsData = try Self.encodeRows(appliedEntities)
                let appliedVersionToken = try versionToken(
                    for: appliedEntities
                )
                context.insert(
                    KapiImportBatchEntity(
                        id: batchID,
                        sourceScopeID: Self.sourceScopeID,
                        fileName: preview.fileName,
                        fileSHA256: preview.fileSHA256,
                        coverageStart: preview.coverage.start,
                        coverageEnd: preview.coverage.end,
                        previousCoverageStart: previousCoverage?.start,
                        previousCoverageEnd: previousCoverage?.end,
                        importedAt: preview.importedAt,
                        appliedAt: appliedAt,
                        baseVersionToken: preview.baselineVersionToken,
                        appliedVersionToken: appliedVersionToken,
                        appliedRowsData: appliedRowsData,
                        replacedRowsData: replacedRowsData,
                        diffSummaryData: diffSummaryData,
                        rowCount: preview.incomingItems.count,
                        incomeTotal: preview.incomingIncomeTotal,
                        expenseTotal: preview.incomingExpenseTotal
                    )
                )
            }
        } catch {
            context.rollback()
            throw error
        }

        let receipt = KapiSyncReceipt(
            batchID: batchID,
            coverage: preview.coverage,
            appliedAt: appliedAt,
            unchangedCount: summary.unchangedCount,
            addedCount: summary.addedCount,
            removedCount: summary.removedCount,
            isReverted: false
        )
        let firstDate = preview.incomingItems
            .map(\.transaction.occurredAt)
            .min()
        let lastDate = preview.incomingItems
            .map(\.transaction.occurredAt)
            .max()
        return KapiSyncApplicationResult(
            summary: ImportSummary(
                importedCount: summary.addedCount,
                duplicateCount: preview.incomingItems.filter {
                    $0.transaction.suspectedDuplicate
                }.count,
                firstDate: firstDate,
                lastDate: lastDate,
                incomeTotal: preview.incomingIncomeTotal,
                expenseTotal: preview.incomingExpenseTotal,
                coverageWarning: coverageHadGap
                    ? "这次账单与已有日期不连续；FIRE 仅按较新的连续区间判断完整月份，避免把缺失月份当成零支出。"
                    : nil
            ),
            receipt: receipt
        )
    }

    func latestReceipt() throws -> KapiSyncReceipt? {
        guard let batch = try latestBatch() else { return nil }
        guard let summary = try? Self.decoder.decode(
            StoredKapiDiffSummary.self,
            from: batch.diffSummaryData
        ) else {
            throw KapiSyncError.corruptHistory
        }
        return KapiSyncReceipt(
            batchID: batch.id,
            coverage: TransactionCoverage(
                start: batch.coverageStart,
                end: batch.coverageEnd
            ),
            appliedAt: batch.appliedAt,
            unchangedCount: summary.unchangedCount,
            addedCount: summary.addedCount,
            removedCount: summary.removedCount,
            isReverted: batch.stateRawValue == "reverted"
        )
    }

    func undoLatest() throws -> KapiSyncReceipt {
        guard let batch = try latestBatch(),
              batch.stateRawValue == "applied" else {
            throw KapiSyncError.noReversibleSync
        }
        let coverage = TransactionCoverage(
            start: batch.coverageStart,
            end: batch.coverageEnd
        )
        let current = try managedTransactions(in: coverage)
        guard try versionToken(for: current)
                == batch.appliedVersionToken else {
            throw KapiSyncError.syncChangedAfterApply
        }
        let previous = try Self.decodeRows(batch.replacedRowsData)
        guard let summary = try? Self.decoder.decode(
            StoredKapiDiffSummary.self,
            from: batch.diffSummaryData
        ) else {
            throw KapiSyncError.corruptHistory
        }
        let revertedAt = Date()

        do {
            try context.transaction {
                for entity in current {
                    context.delete(entity)
                }
                for value in previous {
                    context.insert(try value.makeEntity())
                }
                try restoreCoverage(
                    start: batch.previousCoverageStart,
                    end: batch.previousCoverageEnd
                )
                batch.stateRawValue = "reverted"
                batch.revertedAt = revertedAt
            }
        } catch {
            context.rollback()
            throw error
        }

        return KapiSyncReceipt(
            batchID: batch.id,
            coverage: coverage,
            appliedAt: batch.appliedAt,
            unchangedCount: summary.unchangedCount,
            addedCount: summary.addedCount,
            removedCount: summary.removedCount,
            isReverted: true
        )
    }

    private func makePreview(
        id: UUID,
        fileName: String,
        fileSHA256: String,
        coverage: TransactionCoverage,
        importedAt: Date,
        incomingItems: [KapiSnapshotItem],
        existing: [TransactionEntity]
    ) -> KapiSyncPreview {
        let sortedExisting = existing.sorted(by: Self.preferredExistingOrder)
        let incomingByLegacyFingerprint = Dictionary(
            grouping: incomingItems.indices,
            by: { incomingItems[$0].transaction.fingerprint }
        )
        var legacyOffsets: [String: Int] = [:]
        var comparisonPrevious: [KapiSnapshotItem] = []
        var legacyUpgradeCount = 0

        for entity in sortedExisting {
            if entity.semanticHash == nil {
                let fingerprint = entity.fingerprint
                let offset = legacyOffsets[fingerprint, default: 0]
                if let candidates = incomingByLegacyFingerprint[fingerprint],
                   offset < candidates.count {
                    var item = incomingItems[candidates[offset]]
                    item.transaction.id = entity.id
                    item.transaction.suspectedDuplicate =
                        entity.isSuspectedDuplicate
                    comparisonPrevious.append(item)
                    legacyOffsets[fingerprint] = offset + 1
                    legacyUpgradeCount += 1
                    continue
                }
            }
            comparisonPrevious.append(entity.sourceSnapshotItem)
        }

        let reconciliation = KapiSnapshotReconciler.reconcile(
            previous: comparisonPrevious,
            incoming: incomingItems
        )
        let previousItems = existing.map(\.sourceSnapshotItem)
        return KapiSyncPreview(
            id: id,
            fileName: fileName,
            fileSHA256: fileSHA256,
            coverage: coverage,
            importedAt: importedAt,
            baselineVersionToken:
                (try? versionToken(for: existing)) ?? "",
            incomingItems: incomingItems,
            reconciliation: reconciliation,
            legacyUpgradeCount: legacyUpgradeCount,
            previousIncomeTotal: Self.total(
                previousItems,
                direction: .income
            ),
            previousExpenseTotal: Self.total(
                previousItems,
                direction: .expense
            ),
            incomingIncomeTotal: Self.total(
                incomingItems,
                direction: .income
            ),
            incomingExpenseTotal: Self.total(
                incomingItems,
                direction: .expense
            )
        )
    }

    private func validate(
        _ items: [KapiSnapshotItem],
        coverage: TransactionCoverage
    ) throws {
        let endExclusive = Self.calendar.date(
            byAdding: .day,
            value: 1,
            to: coverage.end
        ) ?? coverage.end.addingTimeInterval(86_400)
        for item in items {
            let date = item.transaction.occurredAt
            guard date >= coverage.start, date < endExclusive else {
                throw KapiSyncError.transactionOutsideCoverage(
                    row: item.transaction.importRow
                )
            }
        }
    }

    private func managedTransactions(
        in coverage: TransactionCoverage
    ) throws -> [TransactionEntity] {
        let all = try context.fetch(FetchDescriptor<TransactionEntity>())
        let endExclusive = Self.calendar.date(
            byAdding: .day,
            value: 1,
            to: coverage.end
        ) ?? coverage.end.addingTimeInterval(86_400)
        return all.filter {
            Self.isManagedKapiTransaction($0)
                && $0.transactionDate >= coverage.start
                && $0.transactionDate < endExclusive
        }
    }

    private static func isManagedKapiTransaction(
        _ entity: TransactionEntity
    ) -> Bool {
        switch entity.sourceRawValue {
        case nil, "legacy":
            true
        case "kapi":
            entity.sourceScopeID == nil
                || entity.sourceScopeID == sourceScopeID
        default:
            false
        }
    }

    private static func preferredExistingOrder(
        _ lhs: TransactionEntity,
        _ rhs: TransactionEntity
    ) -> Bool {
        let lhsIsModern = lhs.semanticHash != nil
        let rhsIsModern = rhs.semanticHash != nil
        if lhsIsModern != rhsIsModern {
            return lhsIsModern
        }
        if lhs.isSuspectedDuplicate != rhs.isSuspectedDuplicate {
            return !lhs.isSuspectedDuplicate
        }
        if lhs.transactionDate != rhs.transactionDate {
            return lhs.transactionDate < rhs.transactionDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func makeEntity(
        from item: KapiSnapshotItem,
        batchID: UUID
    ) throws -> TransactionEntity {
        let value = item.transaction
        return TransactionEntity(
            id: value.id,
            fingerprint: value.fingerprint,
            semanticHash: item.semanticFingerprint,
            sourceRawValue: "kapi",
            sourceScopeID: Self.sourceScopeID,
            importBatchID: batchID,
            logicalTransactionID: value.id,
            sourceRow: value.importRow,
            transactionDate: value.occurredAt,
            directionRawValue: value.direction == .income ? "收入" : "支出",
            amount: value.amount.doubleValue,
            category: value.primaryCategory,
            subcategory: value.secondaryCategory,
            merchant: "",
            note: value.merchantNote,
            account: value.accountName,
            currency: value.currency.rawValue,
            tagsJSON: try Self.encoder.encode(value.tags),
            ledgerName: value.ledgerName,
            sourceIncludedInCashFlow: value.includedInCashFlow,
            includedInBudget: value.includedInBudget,
            allocationDetails: item.splitDetails,
            rawSourceJSON: try Self.encoder.encode(item),
            isIncluded: value.includedInCashFlow,
            isSuspectedDuplicate: value.suspectedDuplicate,
            isInternalTransfer: value.isInternalTransfer,
            isInvestmentTrade: value.isInvestmentTrade,
            isLoanPrincipal: value.isLoanPrincipal,
            importedAt: .now
        )
    }

    private func update(
        _ entity: TransactionEntity,
        from item: KapiSnapshotItem,
        batchID: UUID,
        preservesDuplicateDecision: Bool
    ) throws {
        let value = item.transaction
        let duplicateDecision = entity.isSuspectedDuplicate
        entity.fingerprint = value.fingerprint
        entity.semanticHash = item.semanticFingerprint
        entity.sourceRawValue = "kapi"
        entity.sourceScopeID = Self.sourceScopeID
        entity.importBatchID = batchID
        entity.logicalTransactionID = entity.logicalTransactionID ?? entity.id
        entity.sourceRow = value.importRow
        entity.transactionDate = value.occurredAt
        entity.directionRawValue =
            value.direction == .income ? "收入" : "支出"
        entity.amount = value.amount.doubleValue
        entity.category = value.primaryCategory
        entity.subcategory = value.secondaryCategory
        entity.merchant = ""
        entity.note = value.merchantNote
        entity.account = value.accountName
        entity.currency = value.currency.rawValue
        entity.tagsJSON = try Self.encoder.encode(value.tags)
        entity.ledgerName = value.ledgerName
        entity.sourceIncludedInCashFlow = value.includedInCashFlow
        entity.includedInBudget = value.includedInBudget
        entity.allocationDetails = item.splitDetails
        entity.rawSourceJSON = try Self.encoder.encode(item)
        entity.isIncluded = value.includedInCashFlow
        entity.isSuspectedDuplicate = preservesDuplicateDecision
            ? duplicateDecision
            : value.suspectedDuplicate
        entity.isInternalTransfer = value.isInternalTransfer
        entity.isInvestmentTrade = value.isInvestmentTrade
        entity.isLoanPrincipal = value.isLoanPrincipal
    }

    private func versionToken(
        for entities: [TransactionEntity]
    ) throws -> String {
        Self.sha256(try Self.encodeRows(entities))
    }

    private static func total(
        _ items: [KapiSnapshotItem],
        direction: TransactionDirection
    ) -> Double {
        items
            .filter {
                $0.transaction.direction == direction
                    && $0.transaction.includedInCashFlow
            }
            .reduce(Decimal.zero) {
                $0 + $1.transaction.amount
            }
            .doubleValue
    }

    private func storedCoverage() throws -> TransactionCoverage? {
        let metadata = try context.fetch(FetchDescriptor<AppMetadataEntity>())
        guard let start = metadata.first(where: {
            $0.key == MetadataKey.coverageStart
        })?.dateValue,
        let end = metadata.first(where: {
            $0.key == MetadataKey.coverageEnd
        })?.dateValue,
        start <= end else {
            return nil
        }
        return TransactionCoverage(start: start, end: end)
    }

    private func mergeCoverage(_ incoming: TransactionCoverage) throws -> Bool {
        let merged = TransactionCoverageMerger.merge(
            existing: try storedCoverage(),
            incoming: incoming
        )
        try restoreCoverage(
            start: merged.coverage.start,
            end: merged.coverage.end
        )
        return merged.hadGap
    }

    private func restoreCoverage(start: Date?, end: Date?) throws {
        let metadata = try context.fetch(FetchDescriptor<AppMetadataEntity>())
        let startEntity = metadata.first {
            $0.key == MetadataKey.coverageStart
        }
        let endEntity = metadata.first {
            $0.key == MetadataKey.coverageEnd
        }

        guard let start, let end else {
            if let startEntity { context.delete(startEntity) }
            if let endEntity { context.delete(endEntity) }
            return
        }

        let resolvedStart: AppMetadataEntity
        if let startEntity {
            resolvedStart = startEntity
        } else {
            resolvedStart = AppMetadataEntity(key: MetadataKey.coverageStart)
            context.insert(resolvedStart)
        }
        resolvedStart.dateValue = start

        let resolvedEnd: AppMetadataEntity
        if let endEntity {
            resolvedEnd = endEntity
        } else {
            resolvedEnd = AppMetadataEntity(key: MetadataKey.coverageEnd)
            context.insert(resolvedEnd)
        }
        resolvedEnd.dateValue = end
    }

    private func latestBatch() throws -> KapiImportBatchEntity? {
        try context.fetch(FetchDescriptor<KapiImportBatchEntity>())
            .filter { $0.sourceScopeID == Self.sourceScopeID }
            .max { $0.appliedAt < $1.appliedAt }
    }

    private static func encodeRows(
        _ entities: [TransactionEntity]
    ) throws -> Data {
        let rows = entities
            .map(StoredKapiTransaction.init)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return try encoder.encode(
            StoredKapiRowsEnvelope(version: 1, rows: rows)
        )
    }

    private static func decodeRows(
        _ data: Data
    ) throws -> [StoredKapiTransaction] {
        guard let envelope = try? decoder.decode(
            StoredKapiRowsEnvelope.self,
            from: data
        ),
        envelope.version == 1 else {
            throw KapiSyncError.corruptHistory
        }
        return envelope.rows
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated fileprivate static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated fileprivate static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
}

private struct StoredKapiRowsEnvelope: Codable {
    let version: Int
    let rows: [StoredKapiTransaction]
}

private struct StoredKapiDiffSummary: Codable {
    let unchangedCount: Int
    let addedCount: Int
    let removedCount: Int
}

private struct StoredKapiTransaction: Codable {
    let id: UUID
    let fingerprint: String
    let semanticHash: String?
    let sourceRawValue: String?
    let sourceScopeID: String?
    let importBatchID: UUID?
    let logicalTransactionID: UUID?
    let sourceRow: Int?
    let transactionDate: Date
    let directionRawValue: String
    let amount: Double
    let category: String
    let subcategory: String
    let merchant: String
    let note: String
    let account: String
    let currency: String
    let tags: [String]
    let ledgerName: String?
    let sourceIncludedInCashFlow: Bool?
    let includedInBudget: Bool?
    let allocationDetails: String?
    let rawSourceJSON: Data?
    let isIncluded: Bool
    let isSuspectedDuplicate: Bool
    let isInternalTransfer: Bool
    let isInvestmentTrade: Bool
    let isLoanPrincipal: Bool
    let importedAt: Date

    init(_ entity: TransactionEntity) {
        id = entity.id
        fingerprint = entity.fingerprint
        semanticHash = entity.semanticHash
        sourceRawValue = entity.sourceRawValue
        sourceScopeID = entity.sourceScopeID
        importBatchID = entity.importBatchID
        logicalTransactionID = entity.logicalTransactionID
        sourceRow = entity.sourceRow
        transactionDate = entity.transactionDate
        directionRawValue = entity.directionRawValue
        amount = entity.amount
        category = entity.category
        subcategory = entity.subcategory
        merchant = entity.merchant
        note = entity.note
        account = entity.account
        currency = entity.currency
        tags = entity.sourceTags
        ledgerName = entity.ledgerName
        sourceIncludedInCashFlow = entity.sourceIncludedInCashFlow
        includedInBudget = entity.includedInBudget
        allocationDetails = entity.allocationDetails
        rawSourceJSON = entity.rawSourceJSON
        isIncluded = entity.isIncluded
        isSuspectedDuplicate = entity.isSuspectedDuplicate
        isInternalTransfer = entity.isInternalTransfer
        isInvestmentTrade = entity.isInvestmentTrade
        isLoanPrincipal = entity.isLoanPrincipal
        importedAt = entity.importedAt
    }

    func makeEntity() throws -> TransactionEntity {
        TransactionEntity(
            id: id,
            fingerprint: fingerprint,
            semanticHash: semanticHash,
            sourceRawValue: sourceRawValue,
            sourceScopeID: sourceScopeID,
            importBatchID: importBatchID,
            logicalTransactionID: logicalTransactionID,
            sourceRow: sourceRow,
            transactionDate: transactionDate,
            directionRawValue: directionRawValue,
            amount: amount,
            category: category,
            subcategory: subcategory,
            merchant: merchant,
            note: note,
            account: account,
            currency: currency,
            tagsJSON: try KapiSyncService.encoder.encode(tags),
            ledgerName: ledgerName,
            sourceIncludedInCashFlow: sourceIncludedInCashFlow,
            includedInBudget: includedInBudget,
            allocationDetails: allocationDetails,
            rawSourceJSON: rawSourceJSON,
            isIncluded: isIncluded,
            isSuspectedDuplicate: isSuspectedDuplicate,
            isInternalTransfer: isInternalTransfer,
            isInvestmentTrade: isInvestmentTrade,
            isLoanPrincipal: isLoanPrincipal,
            importedAt: importedAt
        )
    }
}

private extension TransactionEntity {
    var sourceTags: [String] {
        guard let tagsJSON,
              let tags = try? KapiSyncService.decoder.decode(
                [String].self,
                from: tagsJSON
              ) else {
            return []
        }
        return tags
    }

    var sourceSnapshotItem: KapiSnapshotItem {
        if let rawSourceJSON,
           var item = try? KapiSyncService.decoder.decode(
                KapiSnapshotItem.self,
                from: rawSourceJSON
           ) {
            item.transaction.id = id
            item.transaction.suspectedDuplicate = isSuspectedDuplicate
            return item
        }

        return KapiSnapshotItem(
            transaction: TransactionRecord(
                id: id,
                occurredAt: transactionDate,
                direction: directionRawValue.contains("收入")
                    ? .income
                    : .expense,
                amount: Decimal(amount),
                currency: CurrencyCode(rawValue: currency) ?? .cny,
                primaryCategory: category,
                secondaryCategory: subcategory,
                merchantNote: merchant == note
                    ? merchant
                    : [merchant, note]
                        .filter { !$0.isEmpty }
                        .joined(separator: " "),
                tags: sourceTags,
                accountName: account,
                ledgerName: ledgerName ?? "",
                includedInCashFlow:
                    sourceIncludedInCashFlow ?? isIncluded,
                includedInBudget: includedInBudget ?? isIncluded,
                isInternalTransfer: isInternalTransfer,
                isInvestmentTrade: isInvestmentTrade,
                isLoanPrincipal: isLoanPrincipal,
                isRefund: directionRawValue.contains("收入")
                    && [category, subcategory, merchant, note]
                        .joined(separator: " ")
                        .contains("退款"),
                fingerprint: fingerprint,
                suspectedDuplicate: isSuspectedDuplicate,
                importRow: sourceRow
            ),
            splitDetails: allocationDetails ?? ""
        )
    }
}
