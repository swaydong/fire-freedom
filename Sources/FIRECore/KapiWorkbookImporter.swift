import CoreXLSX
import Foundation

public struct KapiImportResult: Codable, Equatable, Sendable {
    public var transactions: [TransactionRecord]
    public var sheetName: String
    public var importedAt: Date
    public var warnings: [String]
    public var exportCoverage: TransactionCoverage?
    public var splitDetailsByTransactionID: [UUID: String]

    public init(
        transactions: [TransactionRecord],
        sheetName: String,
        importedAt: Date = Date(),
        warnings: [String] = [],
        exportCoverage: TransactionCoverage? = nil,
        splitDetailsByTransactionID: [UUID: String] = [:]
    ) {
        self.transactions = transactions
        self.sheetName = sheetName
        self.importedAt = importedAt
        self.warnings = warnings
        self.exportCoverage = exportCoverage
        self.splitDetailsByTransactionID = splitDetailsByTransactionID
    }

    public var snapshotItems: [KapiSnapshotItem] {
        transactions.map {
            KapiSnapshotItem(
                transaction: $0,
                splitDetails: splitDetailsByTransactionID[$0.id] ?? ""
            )
        }
    }

    public var expenseCount: Int {
        transactions.filter { $0.direction == .expense }.count
    }

    public var incomeCount: Int {
        transactions.filter { $0.direction == .income }.count
    }

    public var includedCount: Int {
        transactions.filter(\.includedInCashFlow).count
    }

    public var excludedCount: Int {
        transactions.count - includedCount
    }

    public var suspectedDuplicateCount: Int {
        transactions.filter(\.suspectedDuplicate).count
    }

    public var expenseTotal: Decimal {
        transactions
            .filter {
                $0.direction == .expense && $0.includedInCashFlow
            }
            .reduce(0) { $0 + $1.amount }
            .rounded()
    }

    public var incomeTotal: Decimal {
        transactions
            .filter {
                $0.direction == .income && $0.includedInCashFlow
            }
            .reduce(0) { $0 + $1.amount }
            .rounded()
    }

    public var periodStart: Date? {
        transactions.map(\.occurredAt).min()
    }

    public var periodEnd: Date? {
        transactions.map(\.occurredAt).max()
    }
}

public enum KapiImportError: Error, Equatable, Sendable {
    case unreadableWorkbook
    case billSheetNotFound
    case emptyBillSheet
    case missingRequiredHeaders([String])
    case invalidRow(row: Int, reason: String)
}

extension KapiImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadableWorkbook:
            "无法读取该 XLSX 文件；请确认它不是旧版 XLS 或受密码保护的文件。"
        case .billSheetNotFound:
            "没有找到“收支账单”工作表。"
        case .emptyBillSheet:
            "“收支账单”工作表没有数据。"
        case let .missingRequiredHeaders(headers):
            "账单缺少必要表头：\(headers.joined(separator: "、"))。"
        case let .invalidRow(row, reason):
            "第 \(row) 行无法导入：\(reason)"
        }
    }
}

public struct KapiWorkbookImporter {
    public init() {}

    public func importWorkbook(at url: URL) throws -> KapiImportResult {
        guard let file = XLSXFile(filepath: url.path) else {
            throw KapiImportError.unreadableWorkbook
        }

        let sharedStrings = try file.parseSharedStrings()
        for workbook in try file.parseWorkbooks() {
            let sheets = try file.parseWorksheetPathsAndNames(workbook: workbook)
            guard let sheet = sheets.first(where: {
                normalizedHeader($0.name ?? "") == normalizedHeader("收支账单")
            }) else {
                continue
            }

            let worksheet = try file.parseWorksheet(at: sheet.path)
            guard let rows = worksheet.data?.rows, let headerRow = rows.first else {
                throw KapiImportError.emptyBillSheet
            }

            let headers = Dictionary(uniqueKeysWithValues: headerRow.cells.map {
                ($0.reference.column.value, cellText($0, sharedStrings: sharedStrings))
            })
            let map = try KapiHeaderMap(headersByColumn: headers)
            var transactions: [TransactionRecord] = []
            var splitDetailsByTransactionID: [UUID: String] = [:]
            transactions.reserveCapacity(max(rows.count - 1, 0))

            for row in rows.dropFirst() {
                let values = Dictionary(uniqueKeysWithValues: row.cells.map {
                    ($0.reference.column.value, cellText($0, sharedStrings: sharedStrings))
                })
                if values.values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    continue
                }
                let transaction = try transaction(
                    from: values,
                    headers: map,
                    rowNumber: Int(row.reference)
                )
                transactions.append(transaction)
                splitDetailsByTransactionID[transaction.id] = map.value(
                    .splitDetails,
                    in: values
                )
            }

            let coverage = exportCoverage(from: url)
            guard !transactions.isEmpty || coverage != nil else {
                throw KapiImportError.emptyBillSheet
            }

            return KapiImportResult(
                transactions: DuplicateDetector.markSuspectedDuplicates(transactions),
                sheetName: sheet.name ?? "收支账单",
                exportCoverage: coverage,
                splitDetailsByTransactionID: splitDetailsByTransactionID
            )
        }

        throw KapiImportError.billSheetNotFound
    }

    private func transaction(
        from row: [String: String],
        headers: KapiHeaderMap,
        rowNumber: Int
    ) throws -> TransactionRecord {
        let dateText = headers.value(.date, in: row)
        let timeText = headers.value(.time, in: row)
        guard let occurredAt = parseDate(dateText, time: timeText) else {
            throw KapiImportError.invalidRow(row: rowNumber, reason: "日期或时间格式无效")
        }

        let directionText = headers.value(.direction, in: row)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let direction: TransactionDirection
        switch directionText {
        case "收入":
            direction = .income
        case "支出":
            direction = .expense
        default:
            throw KapiImportError.invalidRow(
                row: rowNumber,
                reason: "未知收支类型“\(directionText)”"
            )
        }

        let amountText = headers.value(.amount, in: row)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard let amount = Decimal(
            string: amountText,
            locale: Locale(identifier: "en_US_POSIX")
        ), amount >= 0 else {
            throw KapiImportError.invalidRow(row: rowNumber, reason: "金额格式无效")
        }

        let primaryCategory = headers.value(.primaryCategory, in: row)
        let secondaryCategory = headers.value(.secondaryCategory, in: row)
        let note = headers.value(.note, in: row)
        let accountName = headers.value(.account, in: row)
        let classification = [
            primaryCategory,
            secondaryCategory,
            note,
        ].joined(separator: " ")

        var transaction = TransactionRecord(
            occurredAt: occurredAt,
            direction: direction,
            amount: amount,
            primaryCategory: primaryCategory,
            secondaryCategory: secondaryCategory,
            merchantNote: note,
            tags: parseTags(headers.value(.tags, in: row)),
            accountName: accountName,
            ledgerName: headers.value(.ledger, in: row),
            includedInCashFlow: parseBoolean(
                headers.value(.includedInCashFlow, in: row),
                defaultValue: true
            ),
            includedInBudget: parseBoolean(
                headers.value(.includedInBudget, in: row),
                defaultValue: true
            ),
            isInternalTransfer: containsAny(
                classification,
                ["内部转账", "账户互转", "银行卡转账"]
            ),
            isInvestmentTrade: containsAny(
                classification,
                [
                    "股票买入", "股票卖出", "基金买入", "基金卖出", "证券买入",
                    "证券卖出", "申购", "赎回", "盈米宝充值",
                ]
            ),
            isLoanPrincipal: containsAny(
                classification,
                ["贷款本金", "偿还本金", "贷款还款", "信用卡还款"]
            ) || (
                primaryCategory.contains("资金往来")
                    && secondaryCategory.contains("还款")
            ),
            isRefund: direction == .income
                && containsAny(classification, ["退款", "退货", "返现"]),
            importRow: rowNumber
        )
        transaction.fingerprint = TransactionFingerprint.make(for: transaction)
        return transaction
    }

    private func cellText(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let sharedStrings, let value = cell.stringValue(sharedStrings) {
            return value
        }
        return cell.inlineString?.text ?? cell.value ?? ""
    }

    private func parseDate(_ date: String, time: String) -> Date? {
        let date = date.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = normalizedTime(time)
        for dateFormat in ["yyyy-MM-dd", "yyyy/M/d", "yyyy.MM.dd"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "\(dateFormat) HH:mm:ss"
            if let value = formatter.date(from: "\(date) \(time)") {
                return value
            }
        }
        return nil
    }

    private func normalizedTime(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return "00:00:00"
        }
        if value.contains(":") {
            return value.split(separator: ":").count == 2 ? "\(value):00" : value
        }
        if let fraction = Double(value), fraction >= 0, fraction < 1 {
            let seconds = Int((fraction * 86_400).rounded())
            return String(
                format: "%02d:%02d:%02d",
                seconds / 3_600,
                seconds % 3_600 / 60,
                seconds % 60
            )
        }
        return value
    }

    private func parseBoolean(_ value: String, defaultValue: Bool) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return defaultValue }
        return ["是", "true", "yes", "1", "y"].contains(value)
    }

    private func parseTags(_ value: String) -> [String] {
        value
            .split(whereSeparator: { [",", "，", ";", "；"].contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }

    private func exportCoverage(from url: URL) -> TransactionCoverage? {
        let filename = url.deletingPathExtension().lastPathComponent
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<!\d)(20\d{6})_(20\d{6})(?!\d)"#
        ) else {
            return nil
        }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = expression.firstMatch(in: filename, range: range),
              let startRange = Range(match.range(at: 1), in: filename),
              let endRange = Range(match.range(at: 2), in: filename) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd"
        guard let start = formatter.date(from: String(filename[startRange])),
              let end = formatter.date(from: String(filename[endRange])),
              start <= end else {
            return nil
        }
        return TransactionCoverage(start: start, end: end)
    }
}

struct KapiHeaderMap {
    enum Field: CaseIterable {
        case date
        case time
        case direction
        case amount
        case primaryCategory
        case secondaryCategory
        case tags
        case account
        case includedInCashFlow
        case includedInBudget
        case ledger
        case note
        case splitDetails

        var acceptedHeaders: [String] {
            switch self {
            case .date: ["日期", "交易日期"]
            case .time: ["时间", "交易时间"]
            case .direction: ["类型", "收支类型", "交易类型"]
            case .amount: ["金额", "交易金额"]
            case .primaryCategory: ["一级分类", "分类"]
            case .secondaryCategory: ["二级分类", "子分类"]
            case .tags: ["标签"]
            case .account: ["账户", "账号"]
            case .includedInCashFlow: ["计入收支", "是否计入收支"]
            case .includedInBudget: ["计入预算", "是否计入预算"]
            case .ledger: ["所属账本", "账本"]
            case .note: ["备注", "商户备注", "商户"]
            case .splitDetails: ["分摊明细"]
            }
        }

        var isRequired: Bool {
            [.date, .direction, .amount].contains(self)
        }
    }

    private var columns: [Field: String]

    init(headersByColumn: [String: String]) throws {
        let normalized = Dictionary(uniqueKeysWithValues: headersByColumn.map {
            (normalizedHeader($0.value), $0.key)
        })
        var result: [Field: String] = [:]
        for field in Field.allCases {
            result[field] = field.acceptedHeaders
                .lazy
                .map(normalizedHeader)
                .compactMap { normalized[$0] }
                .first
        }

        let missing = Field.allCases
            .filter { $0.isRequired && result[$0] == nil }
            .map { $0.acceptedHeaders[0] }
        guard missing.isEmpty else {
            throw KapiImportError.missingRequiredHeaders(missing)
        }
        columns = result
    }

    func value(_ field: Field, in row: [String: String]) -> String {
        columns[field].flatMap { row[$0] } ?? ""
    }
}

private func normalizedHeader(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\u{FEFF}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
}
