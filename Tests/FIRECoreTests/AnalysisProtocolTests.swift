import FIRECore
import Foundation
import XCTest

final class AnalysisProtocolTests: XCTestCase {
    func testReportRejectsDuplicateEvidenceIdentifiers() {
        let duplicate = AnalysisEvidenceV1(id: "e1", label: "支出", value: "100")
        let report = AnalysisReportV1(
            coreConclusion: "结论",
            dataConfidence: AnalysisConfidenceV1(
                level: .low,
                explanation: "样本不足",
                evidenceRefs: ["e1"]
            ),
            spendingFindings: [],
            assetStructureRisks: [],
            fireDrivers: [],
            actions: [
                AnalysisActionV1(title: "一", rationale: "一", evidenceRefs: ["e1"]),
                AnalysisActionV1(title: "二", rationale: "二", evidenceRefs: ["e1"]),
                AnalysisActionV1(title: "三", rationale: "三", evidenceRefs: ["e1"]),
            ],
            evidence: [duplicate, duplicate],
            limitations: []
        )

        XCTAssertThrowsError(try report.validate()) { error in
            XCTAssertEqual(
                error as? AnalysisSchemaError,
                .duplicateEvidenceIDs(["e1"])
            )
        }
    }

    func testPIIRedactorKeepsMerchantAndRemovesSensitiveIdentifiers() {
        let source = "示例生鲜订单，手机号 13812345678，邮箱 me@example.com，卡号 6222 0202 1234 5678"
        let redacted = PIIRedactor.redact(text: source)

        XCTAssertTrue(redacted.contains("示例生鲜订单"))
        XCTAssertFalse(redacted.contains("13812345678"))
        XCTAssertFalse(redacted.contains("me@example.com"))
        XCTAssertFalse(redacted.contains("6222 0202 1234 5678"))
    }

    func testPIIRedactorRemovesPeerNamesButKeepsTransferMeaningAndCompanyMerchant() {
        // All names and identifiers in these redaction examples are fictional.
        let source = "微信红包发给张小明，付款给李雷；转给王五。示例生鲜有限公司"
        let redacted = PIIRedactor.redact(text: source)

        XCTAssertTrue(redacted.contains("红包发给[已移除]"))
        XCTAssertTrue(redacted.contains("付款给[已移除]"))
        XCTAssertTrue(redacted.contains("转给[已移除]"))
        XCTAssertFalse(redacted.contains("张小明"))
        XCTAssertFalse(redacted.contains("李雷"))
        XCTAssertFalse(redacted.contains("王五"))
        XCTAssertTrue(redacted.contains("示例生鲜有限公司"))
    }

    func testPIIRedactorRemovesNamesFromCommonTransferNotes() {
        let source = "微信转账-张三；支付宝转账给李雷；收到王五的转账；收款人：赵敏。示例生鲜有限公司"
        let redacted = PIIRedactor.redact(text: source)

        XCTAssertTrue(redacted.contains("微信转账[已移除]"))
        XCTAssertTrue(redacted.contains("支付宝转账给[已移除]"))
        XCTAssertTrue(redacted.contains("收到[已移除]的转账"))
        XCTAssertTrue(redacted.contains("收款人：[已移除]"))
        XCTAssertFalse(redacted.contains("张三"))
        XCTAssertFalse(redacted.contains("李雷"))
        XCTAssertFalse(redacted.contains("王五"))
        XCTAssertFalse(redacted.contains("赵敏"))
        XCTAssertTrue(redacted.contains("示例生鲜有限公司"))
    }

    func testPacketRedactionDropsAccountAndSourceImportIdentifier() {
        var record = TransactionRecord(
            occurredAt: testDate(2026, 1, 1),
            direction: .expense,
            amount: 10,
            primaryCategory: "餐饮",
            merchantNote: "商户 13812345678",
            accountName: "尾号 1234"
        )
        record.fingerprint = TransactionFingerprint.make(for: record)
        let sourceFingerprint = record.fingerprint
        let instrument = Instrument(
            code: "000001",
            name: "示例基金",
            kind: .fund,
            currency: .cny
        )
        let position = PositionSnapshot(
            instrument: instrument,
            originalMarketValue: 100,
            marketValueInCNY: 100,
            capturedAt: testDate(2026, 1, 31),
            sourceImportID: "platform-account-123"
        )
        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 1, 31),
            positions: [position],
            liabilities: [
                Liability(
                    name: "向张三借款",
                    currency: .cny,
                    remainingPrincipal: 50,
                    remainingPrincipalInCNY: 50,
                    updatedAt: testDate(2026, 1, 31)
                ),
            ],
            status: .confirmedComplete
        )
        let expense = ExpenseAnalyzer.analyze([record])
        let state = FIREState(
            calculatedAt: testDate(2026, 1, 31),
            investableNetWorth: 100,
            annualSpending: 0,
            targetAmount: 0,
            progress: 0,
            remainingAmount: 0,
            confirmedMonthlyContribution: nil,
            suggestedMonthlyContribution: MonthlyContributionSuggestion(
                amount: nil,
                monthsUsed: 0,
                confidence: .insufficient,
                rationale: ""
            ),
            estimatedFreedomDate: nil,
            estimatedMonthsRemaining: nil,
            confidence: .insufficient,
            assumptions: .balanced,
            expenseAnalysis: expense
        )
        let packet = AnalysisPacketV1(
            periodStart: record.occurredAt,
            periodEnd: record.occurredAt,
            transactions: [record],
            assetSnapshot: snapshot,
            fireState: state
        )

        let redacted = PIIRedactor.redact(packet: packet)

        XCTAssertEqual(redacted.transactions[0].accountName, "[已移除]")
        XCTAssertFalse(redacted.transactions[0].merchantNote.contains("13812345678"))
        XCTAssertEqual(
            redacted.transactions[0].fingerprint,
            record.id.uuidString.lowercased()
        )
        XCTAssertNotEqual(redacted.transactions[0].fingerprint, sourceFingerprint)
        XCTAssertNil(redacted.assetSnapshot.positions[0].sourceImportID)
        XCTAssertEqual(redacted.assetSnapshot.liabilities[0].name, "[负债]")
    }

    func testPacketRedactionRewritesDuplicateFingerprintReferences() {
        var original = TransactionRecord(
            occurredAt: testDate(2026, 1, 1),
            direction: .expense,
            amount: 10,
            primaryCategory: "餐饮",
            merchantNote: "商户",
            accountName: "尾号 1234"
        )
        original.fingerprint = TransactionFingerprint.make(for: original)
        var duplicate = original
        duplicate.id = UUID()
        duplicate.suspectedDuplicate = true
        duplicate.duplicateOfFingerprint = original.fingerprint

        let snapshot = AssetSnapshot(
            capturedAt: testDate(2026, 1, 31),
            positions: [],
            status: .confirmedComplete
        )
        let expense = ExpenseAnalyzer.analyze([original, duplicate])
        let state = FIREState(
            calculatedAt: testDate(2026, 1, 31),
            investableNetWorth: 0,
            annualSpending: 0,
            targetAmount: 0,
            progress: 0,
            remainingAmount: 0,
            confirmedMonthlyContribution: nil,
            suggestedMonthlyContribution: MonthlyContributionSuggestion(
                amount: nil,
                monthsUsed: 0,
                confidence: .insufficient,
                rationale: ""
            ),
            estimatedFreedomDate: nil,
            estimatedMonthsRemaining: nil,
            confidence: .insufficient,
            assumptions: .balanced,
            expenseAnalysis: expense
        )
        let packet = AnalysisPacketV1(
            periodStart: original.occurredAt,
            periodEnd: original.occurredAt,
            transactions: [original, duplicate],
            assetSnapshot: snapshot,
            fireState: state
        )

        let redacted = PIIRedactor.redact(packet: packet)

        XCTAssertEqual(
            redacted.transactions[1].duplicateOfFingerprint,
            original.id.uuidString.lowercased()
        )
        XCTAssertEqual(
            Set(redacted.transactions.map(\.fingerprint)).count,
            2
        )
    }

    func testReportAcceptsCompactActionsAndValidEvidenceReferences() throws {
        let evidence = AnalysisEvidenceV1(id: "e1", label: "FIRE 进度", value: "30%")
        let report = AnalysisReportV1(
            coreConclusion: "距离目标仍有明显差距。",
            dataConfidence: AnalysisConfidenceV1(
                level: .medium,
                explanation: "已有 8 个完整月份。",
                evidenceRefs: ["e1"]
            ),
            spendingFindings: [],
            assetStructureRisks: [],
            fireDrivers: [],
            actions: [
                AnalysisActionV1(title: "一", rationale: "原因", evidenceRefs: ["e1"]),
                AnalysisActionV1(title: "二", rationale: "原因", evidenceRefs: ["e1"]),
                AnalysisActionV1(title: "三", rationale: "原因", evidenceRefs: ["e1"]),
            ],
            evidence: [evidence],
            limitations: []
        )

        XCTAssertNoThrow(try report.validate())

        var compact = report
        compact.actions = Array(compact.actions.prefix(2))
        XCTAssertNoThrow(try compact.validate())
        compact.actions = Array(compact.actions.prefix(1))
        XCTAssertNoThrow(try compact.validate())

        var invalid = report
        invalid.actions = []
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? AnalysisSchemaError, .invalidActionCount(0))
        }

        invalid = report
        invalid.actions[0].evidenceRefs = ["missing"]
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(
                error as? AnalysisSchemaError,
                .missingEvidenceReferences(["missing"])
            )
        }
    }

    func testReportRejectsMissingEvidence() {
        var report = validReport()
        report.evidence = []

        XCTAssertThrowsError(try report.validate()) { error in
            XCTAssertEqual(error as? AnalysisSchemaError, .missingEvidence)
        }
    }

    func testReportRequiresReferencesForConfidenceFindingsAndActions() {
        var report = validReport()
        report.dataConfidence.evidenceRefs = []
        report.spendingFindings = [
            AnalysisFindingV1(title: "支出", detail: "说明", evidenceRefs: []),
        ]
        report.assetStructureRisks = [
            AnalysisFindingV1(title: "资产", detail: "说明", evidenceRefs: []),
        ]
        report.fireDrivers = [
            AnalysisFindingV1(title: "驱动", detail: "说明", evidenceRefs: []),
        ]
        report.actions[1].evidenceRefs = []

        XCTAssertThrowsError(try report.validate()) { error in
            XCTAssertEqual(
                error as? AnalysisSchemaError,
                .emptyEvidenceReferences([
                    "dataConfidence",
                    "spendingFindings[0]",
                    "assetStructureRisks[0]",
                    "fireDrivers[0]",
                    "actions[1]",
                ])
            )
        }
    }

    func testExistingVerboseReportRemainsValid() throws {
        var report = validReport()
        report.coreConclusion = String(repeating: "较长的历史结论。", count: 20)
        report.spendingFindings = (1...3).map {
            AnalysisFindingV1(
                title: "支出发现\($0)",
                detail: String(repeating: "历史详情。", count: 20),
                evidenceRefs: ["e1"]
            )
        }
        report.assetStructureRisks = report.spendingFindings
        report.fireDrivers = report.spendingFindings
        report.limitations = (1...6).map { "历史限制\($0)" }

        XCTAssertNoThrow(try report.validate())
        let encoded = try JSONEncoder().encode(report)
        XCTAssertEqual(
            try JSONDecoder().decode(AnalysisReportV1.self, from: encoded),
            report
        )
    }

    private func validReport() -> AnalysisReportV1 {
        let evidence = AnalysisEvidenceV1(
            id: "e1",
            label: "FIRE 进度",
            value: "30%"
        )
        return AnalysisReportV1(
            coreConclusion: "结论",
            dataConfidence: AnalysisConfidenceV1(
                level: .medium,
                explanation: "说明",
                evidenceRefs: ["e1"]
            ),
            spendingFindings: [],
            assetStructureRisks: [],
            fireDrivers: [],
            actions: [
                AnalysisActionV1(title: "一", rationale: "原因", evidenceRefs: ["e1"]),
                AnalysisActionV1(title: "二", rationale: "原因", evidenceRefs: ["e1"]),
                AnalysisActionV1(title: "三", rationale: "原因", evidenceRefs: ["e1"]),
            ],
            evidence: [evidence],
            limitations: []
        )
    }
}
