import CryptoKit
import Foundation
import Security
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum BackupError: LocalizedError {
    case keychain(OSStatus)
    case corruptArchive
    case unsupportedVersion(Int)
    case invalidData(String)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "无法访问本机加密密钥（\(status)）。"
        case .corruptArchive: "这不是有效的 F.I.R.E 本机备份。"
        case .unsupportedVersion(let version):
            "此备份版本（\(version)）不受当前 App 支持。"
        case .invalidData(let reason):
            "备份校验失败：\(reason)"
        case .restoreFailed(let reason):
            "恢复失败，原有数据未被替换：\(reason)"
        }
    }
}

struct FIREBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(exportedAs: "com.local.fire.backup")]
    }

    let encryptedData: Data

    init(encryptedData: Data) {
        self.encryptedData = encryptedData
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw BackupError.corruptArchive
        }
        encryptedData = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: encryptedData)
    }
}

protocol BackupKeyProviding {
    func key() throws -> SymmetricKey
}

struct KeychainBackupKeyProvider: BackupKeyProviding {
    func key() throws -> SymmetricKey {
        let service = "com.local.fire.backup-key"
        let account = "primary"
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            throw BackupError.keychain(status)
        }

        let generatedKey = SymmetricKey(size: .bits256)
        let data = generatedKey.withUnsafeBytes { Data($0) }
        let insert: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw BackupError.keychain(insertStatus)
        }
        return SymmetricKey(data: data)
    }
}

@MainActor
final class EncryptedBackupService {
    private static let magic = Data("FIREBACKUP1".utf8)
    private static let currentVersion = 3
    private static let supportedVersions = 1...3
    private let context: ModelContext
    private let keyProvider: any BackupKeyProviding

    init(
        context: ModelContext,
        keyProvider: any BackupKeyProviding = KeychainBackupKeyProvider()
    ) {
        self.context = context
        self.keyProvider = keyProvider
    }

    func createDocument() throws -> FIREBackupDocument {
        let snapshot = try makeSnapshot()
        try validate(snapshot)
        let plaintext = try JSONEncoder.fireBackup.encode(snapshot)
        let sealed = try AES.GCM.seal(plaintext, using: try keyProvider.key())
        guard let combined = sealed.combined else {
            throw BackupError.corruptArchive
        }
        return FIREBackupDocument(encryptedData: Self.magic + Data(combined))
    }

    func decode(document: FIREBackupDocument) throws -> BackupSnapshot {
        do {
            guard document.encryptedData.starts(with: Self.magic) else {
                throw BackupError.corruptArchive
            }
            let combined = document.encryptedData.dropFirst(Self.magic.count)
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(
                sealed,
                using: try keyProvider.key()
            )
            return try JSONDecoder.fireBackup.decode(BackupSnapshot.self, from: plaintext)
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.corruptArchive
        }
    }

    func prepareRestore(document: FIREBackupDocument) throws -> BackupRestorePlan {
        let snapshot = try decode(document: document)
        try validate(snapshot)
        return BackupRestorePlan(snapshot: snapshot)
    }

    func restore(_ plan: BackupRestorePlan) throws {
        do {
            try validate(plan.snapshot)
            try context.transaction {
                try deleteAllStoredData()
                try insert(plan.snapshot)
            }
        } catch let error as BackupError {
            throw error
        } catch {
            context.rollback()
            throw BackupError.restoreFailed(error.localizedDescription)
        }
    }

    private func makeSnapshot() throws -> BackupSnapshot {
        BackupSnapshot(
            version: Self.currentVersion,
            createdAt: .now,
            transactions: try context.fetch(FetchDescriptor<TransactionEntity>())
                .map { BackupTransaction($0) },
            importBatches: try context.fetch(
                FetchDescriptor<KapiImportBatchEntity>()
            ).map { BackupKapiImportBatch($0) },
            instruments: try context.fetch(FetchDescriptor<InstrumentEntity>())
                .map { BackupInstrument($0) },
            positions: try context.fetch(FetchDescriptor<PositionSnapshotEntity>())
                .map { BackupPosition($0) },
            assetSnapshots: try context.fetch(FetchDescriptor<AssetSnapshotEntity>())
                .map { BackupAssetSnapshot($0) },
            liabilities: try context.fetch(FetchDescriptor<LiabilityEntity>())
                .map { BackupLiability($0) },
            reports: try context.fetch(FetchDescriptor<AnalysisReportEntity>())
                .map { BackupReport($0) },
            answers: try context.fetch(FetchDescriptor<AnalysisAnswerEntity>())
                .map { BackupAnswer($0) },
            settings: try context.fetch(FetchDescriptor<FIRESettingsEntity>())
                .map { BackupSettings($0) },
            exchangeRates: try context.fetch(FetchDescriptor<ExchangeRateCacheEntity>())
                .map { BackupExchangeRate($0) },
            metadata: try context.fetch(FetchDescriptor<AppMetadataEntity>())
                .map { BackupMetadata($0) }
        )
    }

    private func validate(_ snapshot: BackupSnapshot) throws {
        guard Self.supportedVersions.contains(snapshot.version) else {
            throw BackupError.unsupportedVersion(snapshot.version)
        }

        try requireUnique(snapshot.transactions.map(\.id), label: "流水 ID 重复")
        try requireUnique(
            snapshot.importBatches.map(\.id),
            label: "账单同步批次 ID 重复"
        )
        try requireUnique(snapshot.instruments.map(\.id), label: "产品 ID 重复")
        try requireUnique(snapshot.positions.map(\.id), label: "持仓 ID 重复")
        try requireUnique(snapshot.assetSnapshots.map(\.id), label: "资产快照 ID 重复")
        try requireUnique(snapshot.liabilities.map(\.id), label: "负债 ID 重复")
        try requireUnique(snapshot.reports.map(\.id), label: "报告 ID 重复")
        try requireUnique(snapshot.answers.map(\.id), label: "追问 ID 重复")
        try requireUnique(snapshot.settings.map(\.id), label: "设置 ID 重复")
        try requireUnique(
            snapshot.exchangeRates.map {
                "\($0.sourceCurrency.uppercased())-\($0.targetCurrency.uppercased())"
            },
            label: "汇率缓存键重复"
        )
        try requireUnique(snapshot.metadata.map(\.key), label: "元数据键重复")

        let importBatchIDs = Set(snapshot.importBatches.map(\.id))
        for transaction in snapshot.transactions {
            if let importBatchID = transaction.importBatchID,
               !importBatchIDs.contains(importBatchID) {
                throw BackupError.invalidData("流水引用了不存在的账单同步批次。")
            }
        }
        for batch in snapshot.importBatches {
            guard batch.coverageStart <= batch.coverageEnd,
                  ["applied", "reverted"].contains(batch.stateRawValue),
                  batch.rowCount >= 0,
                  batch.incomeTotal.isFinite,
                  batch.expenseTotal.isFinite,
                  batch.incomeTotal >= 0,
                  batch.expenseTotal >= 0,
                  !batch.baseVersionToken.isEmpty,
                  !batch.appliedVersionToken.isEmpty else {
                throw BackupError.invalidData("账单同步批次包含无效数据。")
            }
            try requireJSONObject(
                batch.appliedRowsData,
                label: "同步后账单快照"
            )
            try requireJSONObject(
                batch.replacedRowsData,
                label: "同步前账单快照"
            )
            try requireJSONObject(
                batch.diffSummaryData,
                label: "账单同步差异"
            )
        }

        let instrumentIDs = Set(snapshot.instruments.map(\.id))
        let assetSnapshotIDs = Set(snapshot.assetSnapshots.map(\.id))
        for position in snapshot.positions {
            guard instrumentIDs.contains(position.instrumentID) else {
                throw BackupError.invalidData("持仓引用了不存在的产品。")
            }
            guard assetSnapshotIDs.contains(position.assetSnapshotID) else {
                throw BackupError.invalidData("持仓引用了不存在的资产快照。")
            }
            guard [
                position.originalMarketValue,
                position.cnyMarketValue,
                position.recognitionConfidence
            ].allSatisfy({ $0.isFinite }),
            position.originalMarketValue >= 0,
            position.cnyMarketValue >= 0,
            (0...1).contains(position.recognitionConfidence),
            position.sourceCount >= 0,
            position.quantity?.isFinite != false,
            position.unitPrice?.isFinite != false else {
                throw BackupError.invalidData("持仓包含无效数值。")
            }
        }

        let reportIDs = Set(snapshot.reports.map(\.id))
        for answer in snapshot.answers {
            guard reportIDs.contains(answer.reportID) else {
                throw BackupError.invalidData("追问引用了不存在的报告。")
            }
            try requireJSONObject(answer.answerJSON, label: "追问内容")
        }

        for transaction in snapshot.transactions {
            guard transaction.amount.isFinite, transaction.amount >= 0 else {
                throw BackupError.invalidData("流水包含无效金额。")
            }
        }
        for instrument in snapshot.instruments {
            guard AssetKind(rawValue: instrument.kind) != nil,
                  !instrument.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !instrument.currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BackupError.invalidData("产品类型、名称或币种无效。")
            }
        }
        for assetSnapshot in snapshot.assetSnapshots {
            let optionalRates = [
                assetSnapshot.usdToCNY,
                assetSnapshot.hkdToCNY,
            ].compactMap { $0 }
            guard ExchangeRateState(rawValue: assetSnapshot.exchangeRateState) != nil,
                  [
                    assetSnapshot.cashCNY,
                    assetSnapshot.cashUSD,
                    assetSnapshot.cashHKD,
                    assetSnapshot.effectiveCashValueInCNY,
                    assetSnapshot.liabilityPrincipalCNY,
                    assetSnapshot.positionsCNY
                  ].allSatisfy({ $0.isFinite && $0 >= 0 }),
                  optionalRates.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw BackupError.invalidData("资产快照包含无效数值或汇率状态。")
            }
        }
        for liability in snapshot.liabilities {
            guard liability.remainingPrincipal.isFinite,
                  liability.cnyRemainingPrincipal.isFinite,
                  liability.remainingPrincipal >= 0,
                  liability.cnyRemainingPrincipal >= 0 else {
                throw BackupError.invalidData("负债包含无效金额。")
            }
        }
        for report in snapshot.reports {
            try requireJSONObject(report.reportJSON, label: "报告内容")
        }
        for settings in snapshot.settings {
            let values = [
                settings.withdrawalRate,
                settings.expectedReturn,
                settings.inflation,
                settings.suggestedMonthlyContribution
            ] + [settings.confirmedMonthlyContribution].compactMap { $0 }
            let confirmedContributionIsValid =
                settings.confirmedMonthlyContribution.map {
                    PlanAmountValue.decimal(from: $0) != nil
                } ?? true
            guard values.allSatisfy({ $0.isFinite }),
                  settings.withdrawalRate > 0,
                  settings.suggestedMonthlyContribution >= 0,
                  confirmedContributionIsValid else {
                throw BackupError.invalidData("FIRE 设置包含无效数值。")
            }
        }
        for rate in snapshot.exchangeRates {
            guard rate.rate.isFinite,
                  rate.rate > 0,
                  !rate.sourceCurrency.isEmpty,
                  !rate.targetCurrency.isEmpty else {
                throw BackupError.invalidData("汇率缓存包含无效数据。")
            }
        }
        for item in snapshot.metadata {
            guard !item.key.isEmpty,
                  item.doubleValue?.isFinite != false else {
                throw BackupError.invalidData("App 元数据无效。")
            }
            if item.key == AppMetadataKey.plannedAnnualSpending {
                guard PlannedAnnualSpendingValue.decimal(
                    from: item.doubleValue
                ) != nil else {
                    throw BackupError.invalidData("规划年度支出无效。")
                }
            }
            if item.key
                == AppMetadataKey.confirmedAnnualBonusContribution,
               PlanAmountValue.decimal(from: item.doubleValue) == nil {
                throw BackupError.invalidData("年度奖金结余无效。")
            }
        }

        if let incomePlan = try validatedPlanPair(
            in: snapshot.metadata,
            firstKey: AppMetadataKey.plannedMonthlyIncome,
            secondKey: AppMetadataKey.plannedAnnualIncome,
            label: "收入规划"
        ) {
            guard PlanAmountValue.annualExpenseTotal(
                monthlyExpense: incomePlan.first,
                annualIrregularExpense: incomePlan.second
            ) != nil else {
                throw BackupError.invalidData("收入规划年度合计无效。")
            }
        }
        if let expensePlan = try validatedPlanPair(
            in: snapshot.metadata,
            firstKey: AppMetadataKey.plannedMonthlyExpense,
            secondKey: AppMetadataKey.plannedAnnualIrregularExpense,
            label: "支出规划"
        ) {
            guard let total = PlanAmountValue.annualExpenseTotal(
                monthlyExpense: expensePlan.first,
                annualIrregularExpense: expensePlan.second
            ),
            total > 0 else {
                throw BackupError.invalidData("支出规划年度合计必须大于 0。")
            }
        }
    }

    private func validatedPlanPair(
        in metadata: [BackupMetadata],
        firstKey: String,
        secondKey: String,
        label: String
    ) throws -> (first: Decimal, second: Decimal)? {
        let first = metadata.first { $0.key == firstKey }
        let second = metadata.first { $0.key == secondKey }
        guard (first == nil) == (second == nil) else {
            throw BackupError.invalidData("\(label)数据必须成对保存。")
        }
        guard let first, let second else {
            return nil
        }
        guard first.dateValue == second.dateValue else {
            throw BackupError.invalidData(
                "\(label)的月度与年度金额不是同一次保存。"
            )
        }
        guard let firstValue = PlanAmountValue.decimal(
            from: first.doubleValue
        ),
        let secondValue = PlanAmountValue.decimal(
            from: second.doubleValue
        ) else {
            throw BackupError.invalidData("\(label)包含无效金额。")
        }
        return (firstValue, secondValue)
    }

    private func requireUnique<Value: Hashable>(
        _ values: [Value],
        label: String
    ) throws {
        guard Set(values).count == values.count else {
            throw BackupError.invalidData(label)
        }
    }

    private func requireJSONObject(_ data: Data, label: String) throws {
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BackupError.invalidData("\(label)不是有效 JSON。")
        }
    }

    private func deleteAllStoredData() throws {
        try context.delete(model: AnalysisAnswerEntity.self)
        try context.delete(model: PositionSnapshotEntity.self)
        try context.delete(model: AnalysisReportEntity.self)
        try context.delete(model: AssetSnapshotEntity.self)
        try context.delete(model: InstrumentEntity.self)
        try context.delete(model: TransactionEntity.self)
        try context.delete(model: KapiImportBatchEntity.self)
        try context.delete(model: LiabilityEntity.self)
        try context.delete(model: ExchangeRateCacheEntity.self)
        try context.delete(model: FIRESettingsEntity.self)
        try context.delete(model: AppMetadataEntity.self)
    }

    private func insert(_ snapshot: BackupSnapshot) throws {
        for value in snapshot.importBatches {
            context.insert(value.makeEntity())
        }

        for value in snapshot.transactions {
            context.insert(
                TransactionEntity(
                    id: value.id,
                    fingerprint: value.fingerprint,
                    semanticHash: value.semanticHash,
                    sourceRawValue: value.sourceRawValue,
                    sourceScopeID: value.sourceScopeID,
                    importBatchID: value.importBatchID,
                    logicalTransactionID: value.logicalTransactionID,
                    sourceRow: value.sourceRow,
                    transactionDate: value.transactionDate,
                    directionRawValue: value.direction,
                    amount: value.amount,
                    category: value.category,
                    subcategory: value.subcategory,
                    merchant: value.merchant,
                    note: value.note,
                    account: value.account,
                    currency: value.currency,
                    tagsJSON: value.tagsJSON,
                    ledgerName: value.ledgerName,
                    sourceIncludedInCashFlow:
                        value.sourceIncludedInCashFlow,
                    includedInBudget: value.includedInBudget,
                    allocationDetails: value.allocationDetails,
                    rawSourceJSON: value.rawSourceJSON,
                    isIncluded: value.isIncluded,
                    isSuspectedDuplicate: value.isSuspectedDuplicate,
                    isInternalTransfer: value.isInternalTransfer,
                    isInvestmentTrade: value.isInvestmentTrade,
                    isLoanPrincipal: value.isLoanPrincipal,
                    importedAt: value.importedAt ?? snapshot.createdAt
                )
            )
        }

        for value in snapshot.instruments {
            guard let kind = AssetKind(rawValue: value.kind) else {
                throw BackupError.invalidData("产品类型无效。")
            }
            let entity = InstrumentEntity(
                id: value.id,
                code: value.code,
                name: value.name,
                kind: kind,
                currency: value.currency
            )
            entity.normalizedIdentity = value.normalizedIdentity
                ?? InstrumentEntity.identity(
                    code: value.code,
                    name: value.name,
                    kind: kind,
                    currency: value.currency
                )
            entity.isActive = value.isActive ?? true
            entity.closedAt = value.closedAt
            entity.createdAt = value.createdAt ?? snapshot.createdAt
            context.insert(entity)
        }

        for value in snapshot.assetSnapshots {
            guard let state = ExchangeRateState(rawValue: value.exchangeRateState) else {
                throw BackupError.invalidData("资产快照汇率状态无效。")
            }
            let entity = AssetSnapshotEntity(
                id: value.id,
                capturedAt: value.capturedAt,
                cashCNY: value.cashCNY,
                cashUSD: value.cashUSD,
                cashHKD: value.cashHKD,
                cashValueInCNY: value.effectiveCashValueInCNY,
                liabilityPrincipalCNY: value.liabilityPrincipalCNY,
                positionsCNY: value.positionsCNY,
                isComplete: value.isComplete,
                exchangeRateState: state,
                exchangeRateAsOf: value.exchangeRateAsOf,
                exchangeRateFetchedAt: value.exchangeRateFetchedAt,
                exchangeRateSource: value.exchangeRateSource ?? "",
                usdToCNY: value.usdToCNY,
                hkdToCNY: value.hkdToCNY
            )
            entity.createdAt = value.createdAt ?? snapshot.createdAt
            context.insert(entity)
        }

        for value in snapshot.positions {
            context.insert(
                PositionSnapshotEntity(
                    id: value.id,
                    assetSnapshotID: value.assetSnapshotID,
                    instrumentID: value.instrumentID,
                    originalMarketValue: value.originalMarketValue,
                    cnyMarketValue: value.cnyMarketValue,
                    quantity: value.quantity,
                    unitPrice: value.unitPrice,
                    capturedAt: value.capturedAt,
                    recognitionConfidence: value.recognitionConfidence,
                    sourceCount: value.sourceCount,
                    wasManuallyConfirmed: value.wasManuallyConfirmed
                )
            )
        }

        for value in snapshot.liabilities {
            context.insert(
                LiabilityEntity(
                    id: value.id,
                    name: value.name,
                    currency: value.currency,
                    remainingPrincipal: value.remainingPrincipal,
                    cnyRemainingPrincipal: value.cnyRemainingPrincipal,
                    updatedAt: value.updatedAt
                )
            )
        }

        for value in snapshot.reports {
            context.insert(
                AnalysisReportEntity(
                    id: value.id,
                    bridgeReportID: value.bridgeReportID,
                    codexThreadID: value.codexThreadID,
                    title: value.title,
                    reportJSON: value.reportJSON,
                    createdAt: value.createdAt,
                    statusRawValue: value.status
                )
            )
        }

        for value in snapshot.answers {
            context.insert(
                AnalysisAnswerEntity(
                    id: value.id,
                    reportID: value.reportID,
                    question: value.question,
                    answerJSON: value.answerJSON,
                    createdAt: value.createdAt
                )
            )
        }

        for value in snapshot.settings {
            context.insert(
                FIRESettingsEntity(
                    id: value.id,
                    withdrawalRate: value.withdrawalRate,
                    expectedReturn: value.expectedReturn,
                    inflation: value.inflation,
                    suggestedMonthlyContribution: value.suggestedMonthlyContribution,
                    confirmedMonthlyContribution: value.confirmedMonthlyContribution,
                    contributionConfirmedAt: value.contributionConfirmedAt,
                    updatedAt: value.updatedAt
                )
            )
        }

        for value in snapshot.exchangeRates {
            context.insert(
                ExchangeRateCacheEntity(
                    sourceCurrency: value.sourceCurrency,
                    targetCurrency: value.targetCurrency,
                    rate: value.rate,
                    observationDate: value.observationDate,
                    fetchedAt: value.fetchedAt,
                    isManual: value.isManual
                )
            )
        }

        for value in snapshot.metadata {
            context.insert(
                AppMetadataEntity(
                    key: value.key,
                    dateValue: value.dateValue,
                    stringValue: value.stringValue,
                    doubleValue: value.doubleValue
                )
            )
        }
    }

}

struct BackupRestorePlan {
    let version: Int
    let createdAt: Date
    let transactionCount: Int
    let importBatchCount: Int
    let assetSnapshotCount: Int
    let reportCount: Int
    fileprivate let snapshot: BackupSnapshot

    fileprivate init(snapshot: BackupSnapshot) {
        version = snapshot.version
        createdAt = snapshot.createdAt
        transactionCount = snapshot.transactions.count
        importBatchCount = snapshot.importBatches.count
        assetSnapshotCount = snapshot.assetSnapshots.count
        reportCount = snapshot.reports.count
        self.snapshot = snapshot
    }
}

struct BackupSnapshot: Codable {
    let version: Int
    let createdAt: Date
    let transactions: [BackupTransaction]
    let importBatches: [BackupKapiImportBatch]
    let instruments: [BackupInstrument]
    let positions: [BackupPosition]
    let assetSnapshots: [BackupAssetSnapshot]
    let liabilities: [BackupLiability]
    let reports: [BackupReport]
    let answers: [BackupAnswer]
    let settings: [BackupSettings]
    let exchangeRates: [BackupExchangeRate]
    let metadata: [BackupMetadata]

    init(
        version: Int,
        createdAt: Date,
        transactions: [BackupTransaction],
        importBatches: [BackupKapiImportBatch] = [],
        instruments: [BackupInstrument],
        positions: [BackupPosition],
        assetSnapshots: [BackupAssetSnapshot],
        liabilities: [BackupLiability],
        reports: [BackupReport],
        answers: [BackupAnswer],
        settings: [BackupSettings],
        exchangeRates: [BackupExchangeRate],
        metadata: [BackupMetadata]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.transactions = transactions
        self.importBatches = importBatches
        self.instruments = instruments
        self.positions = positions
        self.assetSnapshots = assetSnapshots
        self.liabilities = liabilities
        self.reports = reports
        self.answers = answers
        self.settings = settings
        self.exchangeRates = exchangeRates
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case createdAt
        case transactions
        case importBatches
        case instruments
        case positions
        case assetSnapshots
        case liabilities
        case reports
        case answers
        case settings
        case exchangeRates
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        transactions = try container.decodeIfPresent(
            [BackupTransaction].self,
            forKey: .transactions
        ) ?? []
        importBatches = try container.decodeIfPresent(
            [BackupKapiImportBatch].self,
            forKey: .importBatches
        ) ?? []
        instruments = try container.decodeIfPresent(
            [BackupInstrument].self,
            forKey: .instruments
        ) ?? []
        positions = try container.decodeIfPresent(
            [BackupPosition].self,
            forKey: .positions
        ) ?? []
        assetSnapshots = try container.decodeIfPresent(
            [BackupAssetSnapshot].self,
            forKey: .assetSnapshots
        ) ?? []
        liabilities = try container.decodeIfPresent(
            [BackupLiability].self,
            forKey: .liabilities
        ) ?? []
        reports = try container.decodeIfPresent(
            [BackupReport].self,
            forKey: .reports
        ) ?? []
        answers = try container.decodeIfPresent(
            [BackupAnswer].self,
            forKey: .answers
        ) ?? []
        settings = try container.decodeIfPresent(
            [BackupSettings].self,
            forKey: .settings
        ) ?? []
        exchangeRates = try container.decodeIfPresent(
            [BackupExchangeRate].self,
            forKey: .exchangeRates
        ) ?? []
        metadata = try container.decodeIfPresent(
            [BackupMetadata].self,
            forKey: .metadata
        ) ?? []
    }
}

struct BackupTransaction: Codable {
    let id: UUID
    let fingerprint: String
    let semanticHash: String?
    let sourceRawValue: String?
    let sourceScopeID: String?
    let importBatchID: UUID?
    let logicalTransactionID: UUID?
    let sourceRow: Int?
    let transactionDate: Date
    let direction: String
    let amount: Double
    let category: String
    let subcategory: String
    let merchant: String
    let note: String
    let account: String
    let currency: String
    let tagsJSON: Data?
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
    let importedAt: Date?

    init(_ value: TransactionEntity) {
        id = value.id
        fingerprint = value.fingerprint
        semanticHash = value.semanticHash
        sourceRawValue = value.sourceRawValue
        sourceScopeID = value.sourceScopeID
        importBatchID = value.importBatchID
        logicalTransactionID = value.logicalTransactionID
        sourceRow = value.sourceRow
        transactionDate = value.transactionDate
        direction = value.directionRawValue
        amount = value.amount
        category = value.category
        subcategory = value.subcategory
        merchant = value.merchant
        note = value.note
        account = value.account
        currency = value.currency
        tagsJSON = value.tagsJSON
        ledgerName = value.ledgerName
        sourceIncludedInCashFlow = value.sourceIncludedInCashFlow
        includedInBudget = value.includedInBudget
        allocationDetails = value.allocationDetails
        rawSourceJSON = value.rawSourceJSON
        isIncluded = value.isIncluded
        isSuspectedDuplicate = value.isSuspectedDuplicate
        isInternalTransfer = value.isInternalTransfer
        isInvestmentTrade = value.isInvestmentTrade
        isLoanPrincipal = value.isLoanPrincipal
        importedAt = value.importedAt
    }
}

struct BackupKapiImportBatch: Codable {
    let id: UUID
    let sourceScopeID: String
    let fileName: String
    let fileSHA256: String
    let coverageStart: Date
    let coverageEnd: Date
    let previousCoverageStart: Date?
    let previousCoverageEnd: Date?
    let importedAt: Date
    let appliedAt: Date
    let revertedAt: Date?
    let stateRawValue: String
    let baseVersionToken: String
    let appliedVersionToken: String
    let appliedRowsData: Data
    let replacedRowsData: Data
    let diffSummaryData: Data
    let rowCount: Int
    let incomeTotal: Double
    let expenseTotal: Double

    init(_ value: KapiImportBatchEntity) {
        id = value.id
        sourceScopeID = value.sourceScopeID
        fileName = value.fileName
        fileSHA256 = value.fileSHA256
        coverageStart = value.coverageStart
        coverageEnd = value.coverageEnd
        previousCoverageStart = value.previousCoverageStart
        previousCoverageEnd = value.previousCoverageEnd
        importedAt = value.importedAt
        appliedAt = value.appliedAt
        revertedAt = value.revertedAt
        stateRawValue = value.stateRawValue
        baseVersionToken = value.baseVersionToken
        appliedVersionToken = value.appliedVersionToken
        appliedRowsData = value.appliedRowsData
        replacedRowsData = value.replacedRowsData
        diffSummaryData = value.diffSummaryData
        rowCount = value.rowCount
        incomeTotal = value.incomeTotal
        expenseTotal = value.expenseTotal
    }

    func makeEntity() -> KapiImportBatchEntity {
        KapiImportBatchEntity(
            id: id,
            sourceScopeID: sourceScopeID,
            fileName: fileName,
            fileSHA256: fileSHA256,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            previousCoverageStart: previousCoverageStart,
            previousCoverageEnd: previousCoverageEnd,
            importedAt: importedAt,
            appliedAt: appliedAt,
            revertedAt: revertedAt,
            stateRawValue: stateRawValue,
            baseVersionToken: baseVersionToken,
            appliedVersionToken: appliedVersionToken,
            appliedRowsData: appliedRowsData,
            replacedRowsData: replacedRowsData,
            diffSummaryData: diffSummaryData,
            rowCount: rowCount,
            incomeTotal: incomeTotal,
            expenseTotal: expenseTotal
        )
    }
}

struct BackupInstrument: Codable {
    let id: UUID
    let code: String?
    let name: String
    let kind: String
    let currency: String
    let normalizedIdentity: String?
    let isActive: Bool?
    let closedAt: Date?
    let createdAt: Date?

    init(_ value: InstrumentEntity) {
        id = value.id
        code = value.code
        name = value.name
        kind = value.kindRawValue
        currency = value.currency
        normalizedIdentity = value.normalizedIdentity
        isActive = value.isActive
        closedAt = value.closedAt
        createdAt = value.createdAt
    }
}

struct BackupPosition: Codable {
    let id: UUID
    let assetSnapshotID: UUID
    let instrumentID: UUID
    let originalMarketValue: Double
    let cnyMarketValue: Double
    let quantity: Double?
    let unitPrice: Double?
    let capturedAt: Date
    let recognitionConfidence: Double
    let sourceCount: Int
    let wasManuallyConfirmed: Bool

    init(_ value: PositionSnapshotEntity) {
        id = value.id
        assetSnapshotID = value.assetSnapshotID
        instrumentID = value.instrumentID
        originalMarketValue = value.originalMarketValue
        cnyMarketValue = value.cnyMarketValue
        quantity = value.quantity
        unitPrice = value.unitPrice
        capturedAt = value.capturedAt
        recognitionConfidence = value.recognitionConfidence
        sourceCount = value.sourceCount
        wasManuallyConfirmed = value.wasManuallyConfirmed
    }
}

struct BackupAssetSnapshot: Codable {
    let id: UUID
    let capturedAt: Date
    let cashCNY: Double
    let cashUSD: Double
    let cashHKD: Double
    let cashValueInCNY: Double?
    let liabilityPrincipalCNY: Double
    let positionsCNY: Double
    let isComplete: Bool
    let exchangeRateState: String
    let exchangeRateAsOf: Date?
    let exchangeRateFetchedAt: Date?
    let exchangeRateSource: String?
    let usdToCNY: Double?
    let hkdToCNY: Double?
    let createdAt: Date?

    var effectiveCashValueInCNY: Double {
        cashValueInCNY ?? cashCNY
    }

    init(_ value: AssetSnapshotEntity) {
        id = value.id
        capturedAt = value.capturedAt
        cashCNY = value.cashCNY
        cashUSD = value.cashUSD
        cashHKD = value.cashHKD
        cashValueInCNY = value.cashValueInCNY
        liabilityPrincipalCNY = value.liabilityPrincipalCNY
        positionsCNY = value.positionsCNY
        isComplete = value.isComplete
        exchangeRateState = value.exchangeRateStateRawValue
        exchangeRateAsOf = value.exchangeRateAsOf
        exchangeRateFetchedAt = value.exchangeRateFetchedAt
        exchangeRateSource = value.exchangeRateSource
        usdToCNY = value.usdToCNY
        hkdToCNY = value.hkdToCNY
        createdAt = value.createdAt
    }
}

struct BackupLiability: Codable {
    let id: UUID
    let name: String
    let currency: String
    let remainingPrincipal: Double
    let cnyRemainingPrincipal: Double
    let updatedAt: Date

    init(_ value: LiabilityEntity) {
        id = value.id
        name = value.name
        currency = value.currency
        remainingPrincipal = value.remainingPrincipal
        cnyRemainingPrincipal = value.cnyRemainingPrincipal
        updatedAt = value.updatedAt
    }
}

struct BackupReport: Codable {
    let id: UUID
    let bridgeReportID: String
    let codexThreadID: String
    let title: String
    let reportJSON: Data
    let createdAt: Date
    let status: String

    init(_ value: AnalysisReportEntity) {
        id = value.id
        bridgeReportID = value.bridgeReportID
        codexThreadID = value.codexThreadID
        title = value.title
        reportJSON = value.reportJSON
        createdAt = value.createdAt
        status = value.statusRawValue
    }
}

struct BackupAnswer: Codable {
    let id: UUID
    let reportID: UUID
    let question: String
    let answerJSON: Data
    let createdAt: Date

    init(_ value: AnalysisAnswerEntity) {
        id = value.id
        reportID = value.reportID
        question = value.question
        answerJSON = value.answerJSON
        createdAt = value.createdAt
    }
}

struct BackupSettings: Codable {
    let id: UUID
    let withdrawalRate: Double
    let expectedReturn: Double
    let inflation: Double
    let suggestedMonthlyContribution: Double
    let confirmedMonthlyContribution: Double?
    let contributionConfirmedAt: Date?
    let updatedAt: Date

    init(_ value: FIRESettingsEntity) {
        id = value.id
        withdrawalRate = value.withdrawalRate
        expectedReturn = value.expectedReturn
        inflation = value.inflation
        suggestedMonthlyContribution = value.suggestedMonthlyContribution
        confirmedMonthlyContribution = value.confirmedMonthlyContribution
        contributionConfirmedAt = value.contributionConfirmedAt
        updatedAt = value.updatedAt
    }
}

struct BackupExchangeRate: Codable {
    let sourceCurrency: String
    let targetCurrency: String
    let rate: Double
    let observationDate: Date
    let fetchedAt: Date
    let isManual: Bool

    init(_ value: ExchangeRateCacheEntity) {
        sourceCurrency = value.sourceCurrency
        targetCurrency = value.targetCurrency
        rate = value.rate
        observationDate = value.observationDate
        fetchedAt = value.fetchedAt
        isManual = value.isManual
    }
}

struct BackupMetadata: Codable {
    let key: String
    let dateValue: Date?
    let stringValue: String?
    let doubleValue: Double?

    init(_ value: AppMetadataEntity) {
        key = value.key
        dateValue = value.dateValue
        stringValue = value.stringValue
        doubleValue = value.doubleValue
    }
}

private extension JSONEncoder {
    static var fireBackup: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var fireBackup: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
