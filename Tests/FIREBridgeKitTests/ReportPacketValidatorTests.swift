import FIRECore
import Foundation
import XCTest
@testable import FIREBridgeKit

final class ReportPacketValidatorTests: XCTestCase {
    func testRejectsReportConfidenceThatDisagreesWithLocalCalculation() {
        let packet = packet(confidence: .low)
        let report = report(confidence: .high)

        XCTAssertThrowsError(
            try ReportPacketValidator.validate(
                report: report,
                against: packet
            )
        ) { error in
            guard case let FIREBridgeError.invalidStructuredOutput(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("数据可信度"))
            XCTAssertTrue(message.contains("low"))
            XCTAssertTrue(message.contains("high"))
        }
    }

    func testNormalizationUsesLocalConfidenceAndCanonicalTransactionFingerprint()
        throws {
        let transaction = TransactionRecord(
            occurredAt: Date(timeIntervalSince1970: 0),
            direction: .expense,
            amount: 1,
            primaryCategory: "测试",
            fingerprint: "canonical-fingerprint"
        )
        let packet = packet(
            confidence: .low,
            transactions: [transaction]
        )
        var report = report(confidence: .high)
        report.dataConfidence.evidenceRefs = [" E1 "]
        report.actions[0].evidenceRefs = ["E1"]
        report.evidence[0].transactionFingerprints = [
            transaction.id.uuidString.uppercased(),
            "unknown-reference",
        ]
        report.evidence.append(
            AnalysisEvidenceV1(
                id: "e1",
                label: "重复证据",
                value: "应被去重"
            )
        )

        let normalized = try ReportPacketValidator.normalizeAndValidate(
            report: report,
            against: packet
        )

        XCTAssertEqual(normalized.dataConfidence.level, .low)
        XCTAssertEqual(normalized.evidence.map(\.id), ["e1", "e1-2"])
        XCTAssertEqual(
            normalized.evidence[0].transactionFingerprints,
            [transaction.fingerprint]
        )
        XCTAssertEqual(normalized.dataConfidence.evidenceRefs, ["e1"])
        XCTAssertEqual(normalized.actions[0].evidenceRefs, ["e1"])
    }

    func testNormalizationRejectsEvidenceWithOnlyUnknownTransactionReferences() {
        let transaction = TransactionRecord(
            occurredAt: Date(timeIntervalSince1970: 0),
            direction: .expense,
            amount: 1,
            primaryCategory: "测试",
            fingerprint: "canonical-fingerprint"
        )
        let packet = packet(confidence: .low, transactions: [transaction])
        var report = report(confidence: .low)
        report.evidence[0].transactionFingerprints = ["unknown-reference"]

        XCTAssertThrowsError(
            try ReportPacketValidator.normalizeAndValidate(
                report: report,
                against: packet
            )
        ) { error in
            guard case let FIREBridgeError.invalidStructuredOutput(message) =
                    error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("无法对应"))
        }
    }

    func testNormalizationRejectsDanglingEvidenceReferenceWithoutFallback() {
        let packet = packet(confidence: .low)
        var report = report(confidence: .low)
        report.actions[0].evidenceRefs = ["missing-evidence"]

        XCTAssertThrowsError(
            try ReportPacketValidator.normalizeAndValidate(
                report: report,
                against: packet
            )
        ) { error in
            guard case let FIREBridgeError.invalidStructuredOutput(message) =
                    error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("不存在的证据"))
        }
    }

    private func packet(
        confidence: DataConfidence,
        transactions: [TransactionRecord] = []
    ) -> AnalysisPacketV1 {
        let expense = ExpenseAnalysis(
            annualSpending: 0,
            recurringAnnualized: 0,
            irregularObservedOrRolling12: 0,
            refundOffset: 0,
            completeMonthCount: 3,
            confidence: confidence,
            excludedTransactionCount: 0,
            duplicateTransactionCount: 0,
            periodStart: nil,
            periodEnd: nil
        )
        let state = FIREState(
            calculatedAt: Date(timeIntervalSince1970: 0),
            investableNetWorth: 0,
            annualSpending: 0,
            targetAmount: 0,
            progress: 0,
            remainingAmount: 0,
            confirmedMonthlyContribution: nil,
            suggestedMonthlyContribution: MonthlyContributionSuggestion(
                amount: nil,
                monthsUsed: 0,
                confidence: confidence,
                rationale: ""
            ),
            estimatedFreedomDate: nil,
            estimatedMonthsRemaining: nil,
            confidence: confidence,
            assumptions: .balanced,
            expenseAnalysis: expense
        )
        return AnalysisPacketV1(
            periodStart: nil,
            periodEnd: nil,
            transactions: transactions,
            assetSnapshot: AssetSnapshot(
                capturedAt: Date(timeIntervalSince1970: 0),
                positions: [],
                status: .confirmedComplete
            ),
            fireState: state
        )
    }

    private func report(confidence: DataConfidence) -> AnalysisReportV1 {
        AnalysisReportV1(
            coreConclusion: "结论",
            dataConfidence: AnalysisConfidenceV1(
                level: confidence,
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
            evidence: [
                AnalysisEvidenceV1(id: "e1", label: "数据可信度", value: confidence.rawValue),
            ],
            limitations: []
        )
    }
}
