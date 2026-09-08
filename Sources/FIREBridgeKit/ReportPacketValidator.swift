#if os(macOS)
import FIRECore
import Foundation

enum ReportPacketValidator {
    static func normalizeAndValidate(
        report: AnalysisReportV1,
        against packet: AnalysisPacketV1
    ) throws -> AnalysisReportV1 {
        var report = report
        report.dataConfidence.level = packet.fireState.confidence

        var fingerprintByReference: [String: String] = [:]
        for transaction in packet.transactions {
            fingerprintByReference[referenceKey(transaction.fingerprint)] =
                transaction.fingerprint
            fingerprintByReference[referenceKey(transaction.id.uuidString)] =
                transaction.fingerprint
        }
        var seenEvidenceIDs: Set<String> = []
        var evidenceIDMap: [String: String] = [:]
        report.evidence = try report.evidence.enumerated().map {
            index, evidence in
            var evidence = evidence
            let originalID = evidence.id
            let trimmedID = originalID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let baseID = trimmedID.isEmpty
                ? "evidence-\(index + 1)"
                : String(trimmedID.prefix(40))
            let normalizedID = uniqueEvidenceID(
                base: baseID,
                used: &seenEvidenceIDs
            )
            if !trimmedID.isEmpty,
               evidenceIDMap[referenceKey(originalID)] == nil {
                evidenceIDMap[referenceKey(originalID)] = normalizedID
            }
            if evidenceIDMap[referenceKey(normalizedID)] == nil {
                evidenceIDMap[referenceKey(normalizedID)] = normalizedID
            }
            evidence.id = normalizedID
            let originalTransactionReferences =
                evidence.transactionFingerprints
            let normalizedTransactionReferences = unique(
                originalTransactionReferences.compactMap {
                    fingerprintByReference[referenceKey($0)]
                }
            )
            guard originalTransactionReferences.isEmpty
                    || !normalizedTransactionReferences.isEmpty else {
                throw FIREBridgeError.invalidStructuredOutput(
                    "报告中的流水证据无法对应本次数据包。"
                )
            }
            evidence.transactionFingerprints =
                normalizedTransactionReferences
            return evidence
        }

        func normalizedReferences(_ references: [String]) -> [String] {
            unique(references.map { reference in
                evidenceIDMap[referenceKey(reference)]
                    ?? String(
                        reference.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).prefix(40)
                    )
            })
        }

        report.dataConfidence.evidenceRefs = normalizedReferences(
            report.dataConfidence.evidenceRefs
        )
        report.spendingFindings = report.spendingFindings.map { finding in
            var finding = finding
            finding.evidenceRefs = normalizedReferences(finding.evidenceRefs)
            return finding
        }
        report.assetStructureRisks = report.assetStructureRisks.map { finding in
            var finding = finding
            finding.evidenceRefs = normalizedReferences(finding.evidenceRefs)
            return finding
        }
        report.fireDrivers = report.fireDrivers.map { finding in
            var finding = finding
            finding.evidenceRefs = normalizedReferences(finding.evidenceRefs)
            return finding
        }
        report.actions = report.actions.map { action in
            var action = action
            action.evidenceRefs = normalizedReferences(action.evidenceRefs)
            return action
        }

        do {
            try report.validate()
        } catch let error as AnalysisSchemaError {
            throw FIREBridgeError.invalidStructuredOutput(
                describe(error)
            )
        }
        try validate(report: report, against: packet)
        return report
    }

    static func validate(
        report: AnalysisReportV1,
        against packet: AnalysisPacketV1
    ) throws {
        guard report.dataConfidence.level == packet.fireState.confidence else {
            throw FIREBridgeError.invalidStructuredOutput(
                "报告数据可信度与本地计算不一致：本地为 "
                    + packet.fireState.confidence.rawValue
                    + "，报告为 "
                    + report.dataConfidence.level.rawValue
                    + "。"
            )
        }

        let validFingerprints = Set(packet.transactions.map(\.fingerprint))
        let unknownFingerprints = Set(
            report.evidence.flatMap(\.transactionFingerprints)
        ).subtracting(validFingerprints)
        guard unknownFingerprints.isEmpty else {
            throw FIREBridgeError.invalidStructuredOutput(
                "报告引用了数据包中不存在的流水指纹："
                    + unknownFingerprints.sorted().joined(separator: "、")
            )
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func referenceKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func uniqueEvidenceID(
        base: String,
        used: inout Set<String>
    ) -> String {
        if used.insert(base).inserted {
            return base
        }
        var counter = 2
        while true {
            let suffix = "-\(counter)"
            let candidate = String(base.prefix(max(1, 40 - suffix.count)))
                + suffix
            if used.insert(candidate).inserted {
                return candidate
            }
            counter += 1
        }
    }

    private static func describe(_ error: AnalysisSchemaError) -> String {
        switch error {
        case .unsupportedVersion(let version):
            "报告版本不受支持：\(version)。"
        case .invalidActionCount(let count):
            "报告行动建议数量无效：\(count)。"
        case .missingEvidence:
            "报告缺少证据。"
        case .duplicateEvidenceIDs(let ids):
            "报告证据编号重复：\(ids.joined(separator: "、"))。"
        case .emptyEvidenceReferences(let fields):
            "报告字段缺少证据引用：\(fields.joined(separator: "、"))。"
        case .missingEvidenceReferences(let ids):
            "报告引用了不存在的证据：\(ids.joined(separator: "、"))。"
        }
    }
}
#endif
