import FIREBridgeKit
import FIRECore
import Foundation

enum PendingOperationStoreError: LocalizedError {
    case cannotSaveReport

    var errorDescription: String? {
        switch self {
        case .cannotSaveReport:
            "无法保存月报生成断点，请检查设备存储空间后重试。"
        }
    }
}

struct PendingOCRPositionCandidateV1: Codable, Equatable {
    let id: UUID
    let sourceImageIndex: Int
    let productName: String
    let productCode: String?
    let kind: AssetKind
    let currency: String
    let originalMarketValue: Double
    let confidence: Double
    let requiresMergeConfirmation: Bool
    let verification: String

    init(candidate: OCRPositionCandidate) {
        id = candidate.id
        sourceImageIndex = candidate.sourceImageIndex
        productName = PIIRedactor.redact(text: candidate.productName)
        productCode = candidate.productCode
        kind = candidate.kind
        currency = candidate.currency
        originalMarketValue = candidate.originalMarketValue
        confidence = candidate.confidence
        requiresMergeConfirmation = candidate.requiresMergeConfirmation
        verification = candidate.verification.rawValue
    }

    func candidate() -> OCRPositionCandidate {
        OCRPositionCandidate(
            id: id,
            sourceImageIndex: sourceImageIndex,
            productName: productName,
            productCode: productCode,
            kind: kind,
            currency: currency,
            originalMarketValue: originalMarketValue,
            confidence: confidence,
            requiresMergeConfirmation: requiresMergeConfirmation,
            rawEvidence: "从未完成的本机识别任务恢复",
            verification: AssetProductVerification(rawValue: verification)
                ?? .localOnly
        )
    }
}

struct PendingAssetRecognitionRecordV1: Codable, Equatable {
    let operationID: UUID
    let batchID: UUID
    let imageCount: Int
    let imageIndexOffset: Int?
    let lines: [AssetOCRLineV1]
    let fallbackCandidates: [PendingOCRPositionCandidateV1]
    let retainedCandidates: [PendingOCRPositionCandidateV1]

    init(
        operationID: UUID,
        batchID: UUID,
        imageCount: Int,
        imageIndexOffset: Int?,
        lines: [AssetOCRLineV1],
        fallbackCandidates: [OCRPositionCandidate],
        retainedCandidates: [OCRPositionCandidate]
    ) {
        self.operationID = operationID
        self.batchID = batchID
        self.imageCount = imageCount
        self.imageIndexOffset = imageIndexOffset
        self.lines = lines.map {
            AssetOCRLineV1(
                imageIndex: $0.imageIndex,
                text: PIIRedactor.redact(text: $0.text),
                confidence: $0.confidence,
                boundingBox: $0.boundingBox
            )
        }
        self.fallbackCandidates = fallbackCandidates.map(
            PendingOCRPositionCandidateV1.init(candidate:)
        )
        self.retainedCandidates = retainedCandidates.map(
            PendingOCRPositionCandidateV1.init(candidate:)
        )
    }

    var recognitionResult: AssetOCRRecognitionResult {
        AssetOCRRecognitionResult(
            imageCount: imageCount,
            lines: lines,
            fallbackCandidates: fallbackCandidates.map { $0.candidate() }
        )
    }
}

struct PendingReportOperationRecordV1: Codable, Equatable {
    let reportID: UUID
    let packetSignature: Data
    let reportMonth: Date?

    init(
        reportID: UUID,
        packetSignature: Data,
        reportMonth: Date? = nil
    ) {
        self.reportID = reportID
        self.packetSignature = packetSignature
        self.reportMonth = reportMonth
    }
}

struct PendingFollowUpOperationRecordV1: Codable, Equatable {
    let operationID: UUID
    let reportID: UUID
    let question: String

    init(operationID: UUID, reportID: UUID, question: String) {
        self.operationID = operationID
        self.reportID = reportID
        self.question = PIIRedactor.redact(text: question)
    }
}

private struct PendingOperationsEnvelopeV1: Codable {
    var schemaVersion = 1
    var assetRecognition: PendingAssetRecognitionRecordV1?
    var reportGeneration: PendingReportOperationRecordV1?
    var followUp: PendingFollowUpOperationRecordV1?
}

final class PendingOperationStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) -> PendingOperationStore {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return PendingOperationStore(
            fileURL: baseURL
                .appendingPathComponent("F.I.R.E", isDirectory: true)
                .appendingPathComponent("pending-operations-v1.json"),
            fileManager: fileManager
        )
    }

    func loadAssetRecognition() throws -> PendingAssetRecognitionRecordV1? {
        try loadEnvelope().assetRecognition
    }

    func saveAssetRecognition(
        _ record: PendingAssetRecognitionRecordV1
    ) throws {
        try updateEnvelope { envelope in
            envelope.assetRecognition = record
        }
    }

    func clearAssetRecognition() throws {
        try updateEnvelope { envelope in
            envelope.assetRecognition = nil
        }
    }

    func loadReportOperation() throws -> PendingReportOperationRecordV1? {
        try loadEnvelope().reportGeneration
    }

    func saveReportOperation(_ record: PendingReportOperationRecordV1) throws {
        try updateEnvelope { envelope in
            envelope.reportGeneration = record
        }
    }

    func clearReportOperation() throws {
        try updateEnvelope { envelope in
            envelope.reportGeneration = nil
        }
    }

    func loadFollowUpOperation() throws -> PendingFollowUpOperationRecordV1? {
        try loadEnvelope().followUp
    }

    func saveFollowUpOperation(
        _ record: PendingFollowUpOperationRecordV1
    ) throws {
        try updateEnvelope { envelope in
            envelope.followUp = record
        }
    }

    func clearFollowUpOperation() throws {
        try updateEnvelope { envelope in
            envelope.followUp = nil
        }
    }

    private func loadEnvelope() throws -> PendingOperationsEnvelopeV1 {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return PendingOperationsEnvelopeV1()
        }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(
            PendingOperationsEnvelopeV1.self,
            from: data
        )
        guard envelope.schemaVersion == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return envelope
    }

    private func updateEnvelope(
        _ update: (inout PendingOperationsEnvelopeV1) -> Void
    ) throws {
        var envelope = (try? loadEnvelope()) ?? PendingOperationsEnvelopeV1()
        update(&envelope)

        guard envelope.assetRecognition != nil
                || envelope.reportGeneration != nil
                || envelope.followUp != nil else {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomic])
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedURL = fileURL
        try protectedURL.setResourceValues(resourceValues)
#endif
    }
}
