#if os(macOS)
import CryptoKit
import FIRECore
import Foundation
import OSLog

public actor CodexBridgeRuntime {
    private static let reportLogger = Logger(
        subsystem: "com.local.firefreedom.bridge",
        category: "report"
    )

    private struct PendingReportOperation {
        let requestFingerprint: String
        let task: Task<ReportGeneratedResponseV1, Error>
    }

    private struct PendingFollowUpOperation {
        let reportID: UUID
        let questionFingerprint: String
        let task: Task<AnswerGeneratedResponseV1, Error>
    }

    private struct PendingAssetRecognitionOperation {
        let requestFingerprint: String
        let task: Task<RecognizeAssetsResponseV1, Error>
    }

    private struct AnalysisFollowUpContextV1: Encodable {
        struct PreviousFollowUp: Encodable {
            let question: String
            let answer: AnalysisAnswerV1
        }

        let schemaVersion = "1.0"
        let packet: AnalysisPacketV1
        let report: AnalysisReportV1
        let previousFollowUps: [PreviousFollowUp]
        let currentQuestion: String
    }

    public let health: CodexHealthStatus

    private let client: any CodexAppServerServing
    private let threadStore: any CodexThreadStoring
    private let assetRecognitionStore:
        any AssetRecognitionOperationStoring
    private let instrumentVerifier: any InstrumentVerifying
    private let exchangeRateFetcher: any ReferenceExchangeRateFetching
    private let directoryFactory: IsolatedWorkingDirectoryFactory
    private let serverWorkingDirectory: URL
    private let encoder: JSONEncoder
    private var loadedThreadIDs: Set<String> = []
    private var pendingReports: [UUID: PendingReportOperation] = [:]
    private var pendingFollowUps: [UUID: PendingFollowUpOperation] = [:]
    private var pendingAssetRecognitions:
        [UUID: PendingAssetRecognitionOperation] = [:]
    private var pendingReportDeletions:
        [UUID: Task<ReportDeletedResponseV1, Error>] = [:]
    private var reportDeletionGenerations: [UUID: UInt64] = [:]
    private var reportsBeingDeleted: Set<UUID> = []

    public init(
        health: CodexHealthStatus,
        client: any CodexAppServerServing,
        threadStore: any CodexThreadStoring,
        assetRecognitionStore:
            (any AssetRecognitionOperationStoring)? = nil,
        instrumentVerifier: any InstrumentVerifying = PassthroughInstrumentVerifier(),
        exchangeRateFetcher: (any ReferenceExchangeRateFetching)? = nil,
        directoryFactory: IsolatedWorkingDirectoryFactory,
        serverWorkingDirectory: URL
    ) {
        self.health = health
        self.client = client
        self.threadStore = threadStore
        self.assetRecognitionStore = assetRecognitionStore
            ?? InMemoryAssetRecognitionOperationStore()
        self.instrumentVerifier = instrumentVerifier
        self.exchangeRateFetcher = exchangeRateFetcher
            ?? ECBReferenceRateClient()
        self.directoryFactory = directoryFactory
        self.serverWorkingDirectory = serverWorkingDirectory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> CodexBridgeRuntime {
        let resolver = CodexCLIResolver(environment: environment)
        let health = try CodexHealthChecker(
            resolver: resolver,
            environment: environment
        ).check()
        let directoryFactory = try IsolatedWorkingDirectoryFactory.defaultFactory()
        let serverDirectory = try directoryFactory.create()
        let storeURL = try CodexThreadStore.defaultStoreURL()
        let store = CodexThreadStore(storeURL: storeURL)
        let assetRecognitionStore = AssetRecognitionOperationStore(
            storeURL: try AssetRecognitionOperationStore.defaultStoreURL()
        )
        let connection = ProcessAppServerConnection(
            configuration: .init(
                executableURL: URL(fileURLWithPath: health.executablePath),
                workingDirectoryURL: serverDirectory,
                environment: environment
            )
        )
        let client = CodexAppServerClient(connection: connection)
        do {
            try await client.connect()
        } catch {
            await client.disconnect()
            try? directoryFactory.remove(serverDirectory)
            throw error
        }
        var instrumentVerifiers: [any InstrumentVerifying] = [
            OpenFIGIInstrumentVerifier(
                apiKey: environment["OPENFIGI_API_KEY"]
            ),
        ]
        if let localVerifier = try? LocalInstrumentVerifier.bundled() {
            instrumentVerifiers.append(localVerifier)
        }
        instrumentVerifiers.append(AKShareInstrumentVerifier())
        instrumentVerifiers.append(EastmoneyInstrumentVerifier())
        return CodexBridgeRuntime(
            health: health,
            client: client,
            threadStore: store,
            assetRecognitionStore: assetRecognitionStore,
            instrumentVerifier: LayeredInstrumentVerifier(
                verifiers: instrumentVerifiers
            ),
            directoryFactory: directoryFactory,
            serverWorkingDirectory: serverDirectory
        )
    }

    public func generateReport(
        reportID: UUID,
        packet: AnalysisPacketV1
    ) async throws -> ReportGeneratedResponseV1 {
        let redactedPacket = FIRECore.PIIRedactor.redact(packet: packet)
        let packetData = try encoder.encode(redactedPacket)
        guard packetData.count <= BridgeWire.maximumMessageBytes else {
            throw FIREBridgeError.invalidMessage("分析数据超过 8 MB 上限。")
        }
        guard let packetJSON = String(data: packetData, encoding: .utf8) else {
            throw FIREBridgeError.invalidMessage("无法编码 AnalysisPacketV1。")
        }
        let fingerprintData = try encoder.encode(
            packet.normalizedForOperationFingerprint()
        )
        let requestFingerprint = fingerprint(fingerprintData)

        if let existing = try await threadStore.thread(for: reportID),
           let generatedReport = existing.generatedReport {
            try validateOperationFingerprint(
                existing.reportRequestFingerprint,
                expected: requestFingerprint,
                operationName: "报告"
            )
            return ReportGeneratedResponseV1(
                reportID: reportID,
                threadID: existing.threadID,
                report: generatedReport
            )
        }
        if let pending = pendingReports[reportID] {
            guard pending.requestFingerprint == requestFingerprint else {
                throw FIREBridgeError.invalidMessage(
                    "同一报告操作不能使用不同的分析数据。"
                )
            }
            return try await pending.task.value
        }

        let task = Task {
            try await self.performGenerateReport(
                reportID: reportID,
                redactedPacket: redactedPacket,
                packetJSON: packetJSON,
                requestFingerprint: requestFingerprint
            )
        }
        pendingReports[reportID] = PendingReportOperation(
            requestFingerprint: requestFingerprint,
            task: task
        )
        defer { pendingReports.removeValue(forKey: reportID) }
        return try await task.value
    }

    private func performGenerateReport(
        reportID: UUID,
        redactedPacket: AnalysisPacketV1,
        packetJSON: String,
        requestFingerprint: String
    ) async throws -> ReportGeneratedResponseV1 {
        if var existing = try await threadStore.thread(for: reportID) {
            try validateOperationFingerprint(
                existing.reportRequestFingerprint,
                expected: requestFingerprint,
                operationName: "报告"
            )
            if let generatedReport = existing.generatedReport {
                return ReportGeneratedResponseV1(
                    reportID: reportID,
                    threadID: existing.threadID,
                    report: generatedReport
                )
            }
            if existing.isEphemeral == true {
                return try await generateReportInEphemeralThread(
                    reportID: reportID,
                    redactedPacket: redactedPacket,
                    packetJSON: packetJSON,
                    requestFingerprint: requestFingerprint,
                    replacing: existing
                )
            }
            try await ensureLoaded(existing)
            existing.updatedAt = Date()
            existing.reportRequestFingerprint = requestFingerprint
            try await threadStore.upsert(existing)
            let generatedReport = try await client.generateReport(
                threadID: existing.threadID,
                packetJSON: packetJSON
            )
            let report = try ReportPacketValidator.normalizeAndValidate(
                report: generatedReport,
                against: redactedPacket
            )
            existing.updatedAt = Date()
            existing.evidenceIDs = report.evidence.map(\.id)
            existing.generatedReport = report
            try await threadStore.upsert(existing)
            return ReportGeneratedResponseV1(
                reportID: reportID,
                threadID: existing.threadID,
                report: report
            )
        }
        return try await generateReportInEphemeralThread(
            reportID: reportID,
            redactedPacket: redactedPacket,
            packetJSON: packetJSON,
            requestFingerprint: requestFingerprint,
            replacing: nil
        )
    }

    private func generateReportInEphemeralThread(
        reportID: UUID,
        redactedPacket: AnalysisPacketV1,
        packetJSON: String,
        requestFingerprint: String,
        replacing previousRecord: StoredCodexThread?
    ) async throws -> ReportGeneratedResponseV1 {
        if let previousRecord {
            try? await client.unsubscribeThread(
                threadID: previousRecord.threadID
            )
            try? directoryFactory.remove(
                URL(
                    fileURLWithPath: previousRecord.isolatedWorkingDirectory,
                    isDirectory: true
                )
            )
        }
        let workingDirectory = try directoryFactory.create()
        var threadID: String?
        do {
            let startedThreadID = try await client.startEphemeralThread(
                workingDirectory: workingDirectory,
                purpose: .financialAnalysis
            )
            threadID = startedThreadID
            var record = StoredCodexThread(
                reportID: reportID,
                threadID: startedThreadID,
                isolatedWorkingDirectory: workingDirectory.path,
                reportRequestFingerprint: requestFingerprint,
                isEphemeral: true,
                redactedPacket: redactedPacket
            )
            try await threadStore.upsert(record)
            let generatedReport = try await client.generateReport(
                threadID: startedThreadID,
                packetJSON: packetJSON
            )
            let report = try ReportPacketValidator.normalizeAndValidate(
                report: generatedReport,
                against: redactedPacket
            )
            record.updatedAt = Date()
            record.evidenceIDs = report.evidence.map(\.id)
            record.generatedReport = report
            try await threadStore.upsert(record)
            try? await client.unsubscribeThread(threadID: startedThreadID)
            try? directoryFactory.remove(workingDirectory)
            return ReportGeneratedResponseV1(
                reportID: reportID,
                threadID: startedThreadID,
                report: report
            )
        } catch {
            Self.reportLogger.error(
                "Report generation failed: \(error.localizedDescription, privacy: .private)"
            )
            if let threadID {
                try? await client.unsubscribeThread(threadID: threadID)
            }
            try? await threadStore.remove(reportID: reportID)
            try? directoryFactory.remove(workingDirectory)
            throw error
        }
    }

    public func recognizeAssets(
        request: RecognizeAssetsRequestV1
    ) async throws -> RecognizeAssetsResponseV1 {
        try AssetRecognitionContractValidator.validate(request: request)
        let redactedRequest = RecognizeAssetsRequestV1(
            operationID: request.operationID,
            imageCount: request.imageCount,
            lines: request.lines.map { line in
                AssetOCRLineV1(
                    imageIndex: line.imageIndex,
                    text: FIRECore.PIIRedactor.redact(text: line.text),
                    confidence: line.confidence,
                    boundingBox: line.boundingBox
                )
            }
        )
        try AssetRecognitionContractValidator.validate(request: redactedRequest)
        let requestData = try encoder.encode(redactedRequest)
        let requestFingerprint = fingerprint(requestData)
        guard requestData.count <= BridgeWire.maximumMessageBytes,
              let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw FIREBridgeError.invalidMessage("OCR 识别数据超过 8 MB 上限。")
        }

        if let completed = try await assetRecognitionStore.operation(
            for: request.operationID
        ) {
            try validateOperationFingerprint(
                completed.requestFingerprint,
                expected: requestFingerprint,
                operationName: "资产识别"
            )
            if let response = completed.response {
                return response
            }
        }
        if let pending = pendingAssetRecognitions[request.operationID] {
            guard pending.requestFingerprint == requestFingerprint else {
                throw FIREBridgeError.invalidMessage(
                    "资产识别操作标识已用于其他请求。"
                )
            }
            return try await pending.task.value
        }

        let task = Task {
            try await self.performAssetRecognition(
                request: redactedRequest,
                requestJSON: requestJSON,
                requestFingerprint: requestFingerprint
            )
        }
        pendingAssetRecognitions[request.operationID] =
            PendingAssetRecognitionOperation(
                requestFingerprint: requestFingerprint,
                task: task
            )
        defer {
            pendingAssetRecognitions.removeValue(
                forKey: request.operationID
            )
        }
        return try await task.value
    }

    private func performAssetRecognition(
        request: RecognizeAssetsRequestV1,
        requestJSON: String,
        requestFingerprint: String
    ) async throws -> RecognizeAssetsResponseV1 {
        try await assetRecognitionStore.upsert(
            StoredAssetRecognitionOperation(
                operationID: request.operationID,
                requestFingerprint: requestFingerprint
            )
        )
        let workingDirectory = try directoryFactory.create()
        var threadID: String?
        do {
            let startedThreadID = try await client.startEphemeralThread(
                workingDirectory: workingDirectory,
                purpose: .assetRecognition
            )
            threadID = startedThreadID
            let response = try await client.recognizeAssets(
                threadID: startedThreadID,
                requestJSON: requestJSON
            )
            try AssetRecognitionContractValidator.validate(
                response: response,
                imageCount: request.imageCount
            )
            let verifiedPositions = await instrumentVerifier.verify(
                positions: response.positions
            )
            let verifiedResponse = RecognizeAssetsResponseV1(
                positions: verifiedPositions
            )
            try AssetRecognitionContractValidator.validate(
                response: verifiedResponse,
                imageCount: request.imageCount
            )
            try await assetRecognitionStore.upsert(
                StoredAssetRecognitionOperation(
                    operationID: request.operationID,
                    requestFingerprint: requestFingerprint,
                    response: verifiedResponse
                )
            )
            try? await client.unsubscribeThread(threadID: startedThreadID)
            try? directoryFactory.remove(workingDirectory)
            return verifiedResponse
        } catch {
            if let threadID {
                try? await client.unsubscribeThread(threadID: threadID)
            }
            try? directoryFactory.remove(workingDirectory)
            throw error
        }
    }

    public func followUp(
        operationID: UUID,
        reportID: UUID,
        question: String
    ) async throws -> AnswerGeneratedResponseV1 {
        guard !reportsBeingDeleted.contains(reportID) else {
            throw FIREBridgeError.threadNotFound(reportID: reportID)
        }
        let deletionGeneration = reportDeletionGenerations[
            reportID,
            default: 0
        ]
        guard let record = try await threadStore.thread(for: reportID) else {
            throw FIREBridgeError.threadNotFound(reportID: reportID)
        }
        try ensureReportWasNotDeleted(
            reportID: reportID,
            deletionGeneration: deletionGeneration
        )
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty,
              trimmedQuestion.count <= BridgeWire.maximumQuestionCharacters else {
            throw FIREBridgeError.invalidMessage("追问必须为 1–4000 个字符。")
        }
        let redactedQuestion = FIRECore.PIIRedactor.redact(text: trimmedQuestion)
        let questionFingerprint = fingerprint(Data(redactedQuestion.utf8))
        if let completed = record.completedFollowUps?.first(where: {
            $0.operationID == operationID
        }) {
            guard completed.questionFingerprint == questionFingerprint else {
                throw FIREBridgeError.invalidMessage(
                    "同一追问操作不能使用不同的问题。"
                )
            }
            return AnswerGeneratedResponseV1(
                operationID: operationID,
                reportID: reportID,
                answer: completed.answer
            )
        }
        if let pending = pendingFollowUps[operationID] {
            guard pending.reportID == reportID,
                  pending.questionFingerprint == questionFingerprint else {
                throw FIREBridgeError.invalidMessage(
                    "追问操作标识已用于其他请求。"
                )
            }
            return try await pending.task.value
        }

        let task = Task {
            try await self.performFollowUp(
                operationID: operationID,
                reportID: reportID,
                redactedQuestion: redactedQuestion,
                questionFingerprint: questionFingerprint,
                deletionGeneration: deletionGeneration
            )
        }
        pendingFollowUps[operationID] = PendingFollowUpOperation(
            reportID: reportID,
            questionFingerprint: questionFingerprint,
            task: task
        )
        defer { pendingFollowUps.removeValue(forKey: operationID) }
        return try await task.value
    }

    private func performFollowUp(
        operationID: UUID,
        reportID: UUID,
        redactedQuestion: String,
        questionFingerprint: String,
        deletionGeneration: UInt64
    ) async throws -> AnswerGeneratedResponseV1 {
        try ensureReportWasNotDeleted(
            reportID: reportID,
            deletionGeneration: deletionGeneration
        )
        guard var record = try await threadStore.thread(for: reportID) else {
            throw FIREBridgeError.threadNotFound(reportID: reportID)
        }
        try ensureReportWasNotDeleted(
            reportID: reportID,
            deletionGeneration: deletionGeneration
        )
        if let completed = record.completedFollowUps?.first(where: {
            $0.operationID == operationID
        }) {
            guard completed.questionFingerprint == questionFingerprint else {
                throw FIREBridgeError.invalidMessage(
                    "同一追问操作不能使用不同的问题。"
                )
            }
            return AnswerGeneratedResponseV1(
                operationID: operationID,
                reportID: reportID,
                answer: completed.answer
            )
        }
        if record.isEphemeral == true {
            return try await performEphemeralFollowUp(
                operationID: operationID,
                reportID: reportID,
                redactedQuestion: redactedQuestion,
                questionFingerprint: questionFingerprint,
                deletionGeneration: deletionGeneration,
                record: record
            )
        }
        try await ensureLoaded(record)
        try ensureReportWasNotDeleted(
            reportID: reportID,
            deletionGeneration: deletionGeneration
        )
        let answer = try await client.answer(
            threadID: record.threadID,
            question: redactedQuestion,
            contextJSON: nil
        )
        try ensureReportWasNotDeleted(
            reportID: reportID,
            deletionGeneration: deletionGeneration
        )
        let missingReferences = Set(answer.evidenceRefs)
            .subtracting(record.evidenceIDs ?? [])
        guard missingReferences.isEmpty else {
            throw FIREBridgeError.invalidStructuredOutput(
                "追问引用了本报告不存在的证据：\(missingReferences.sorted().joined(separator: "、"))"
            )
        }
        record.updatedAt = Date()
        var completedFollowUps = record.completedFollowUps ?? []
        completedFollowUps.append(
            StoredFollowUpOperation(
                operationID: operationID,
                questionFingerprint: questionFingerprint,
                redactedQuestion: redactedQuestion,
                answer: answer
            )
        )
        record.completedFollowUps = completedFollowUps
        try await threadStore.upsert(record)
        try ensureReportWasNotDeleted(
            reportID: reportID,
            deletionGeneration: deletionGeneration
        )
        return AnswerGeneratedResponseV1(
            operationID: operationID,
            reportID: reportID,
            answer: answer
        )
    }

    private func performEphemeralFollowUp(
        operationID: UUID,
        reportID: UUID,
        redactedQuestion: String,
        questionFingerprint: String,
        deletionGeneration: UInt64,
        record: StoredCodexThread
    ) async throws -> AnswerGeneratedResponseV1 {
        guard let packet = record.redactedPacket,
              let report = record.generatedReport else {
            throw FIREBridgeError.invalidMessage(
                "这份旧报告缺少可恢复的脱敏上下文，请重新生成月报后再追问。"
            )
        }
        let previousFollowUps = (record.completedFollowUps ?? []).compactMap {
            operation -> AnalysisFollowUpContextV1.PreviousFollowUp? in
            guard let question = operation.redactedQuestion else {
                return nil
            }
            return AnalysisFollowUpContextV1.PreviousFollowUp(
                question: question,
                answer: operation.answer
            )
        }
        let context = AnalysisFollowUpContextV1(
            packet: packet,
            report: report,
            previousFollowUps: previousFollowUps,
            currentQuestion: redactedQuestion
        )
        let contextData = try encoder.encode(context)
        guard contextData.count <= BridgeWire.maximumMessageBytes,
              let contextJSON = String(data: contextData, encoding: .utf8) else {
            throw FIREBridgeError.invalidMessage("追问上下文超过 8 MB 上限。")
        }

        let workingDirectory = try directoryFactory.create()
        var threadID: String?
        do {
            let startedThreadID = try await client.startEphemeralThread(
                workingDirectory: workingDirectory,
                purpose: .financialAnalysis
            )
            threadID = startedThreadID
            let answer = try await client.answer(
                threadID: startedThreadID,
                question: redactedQuestion,
                contextJSON: contextJSON
            )
            try ensureReportWasNotDeleted(
                reportID: reportID,
                deletionGeneration: deletionGeneration
            )
            let missingReferences = Set(answer.evidenceRefs)
                .subtracting(record.evidenceIDs ?? [])
            guard missingReferences.isEmpty else {
                throw FIREBridgeError.invalidStructuredOutput(
                    "追问引用了本报告不存在的证据：\(missingReferences.sorted().joined(separator: "、"))"
                )
            }
            guard var latestRecord = try await threadStore.thread(
                for: reportID
            ) else {
                throw FIREBridgeError.threadNotFound(reportID: reportID)
            }
            try ensureReportWasNotDeleted(
                reportID: reportID,
                deletionGeneration: deletionGeneration
            )
            latestRecord.updatedAt = Date()
            var completedFollowUps = latestRecord.completedFollowUps ?? []
            completedFollowUps.append(
                StoredFollowUpOperation(
                    operationID: operationID,
                    questionFingerprint: questionFingerprint,
                    redactedQuestion: redactedQuestion,
                    answer: answer
                )
            )
            latestRecord.completedFollowUps = completedFollowUps
            try await threadStore.upsert(latestRecord)
            try? await client.unsubscribeThread(threadID: startedThreadID)
            try? directoryFactory.remove(workingDirectory)
            return AnswerGeneratedResponseV1(
                operationID: operationID,
                reportID: reportID,
                answer: answer
            )
        } catch {
            if let threadID {
                try? await client.unsubscribeThread(threadID: threadID)
            }
            try? directoryFactory.remove(workingDirectory)
            throw error
        }
    }

    public func deleteReport(reportID: UUID) async throws -> ReportDeletedResponseV1 {
        if let pending = pendingReportDeletions[reportID] {
            return try await pending.value
        }
        let task = Task {
            try await self.performDeleteReport(reportID: reportID)
        }
        pendingReportDeletions[reportID] = task
        defer { pendingReportDeletions.removeValue(forKey: reportID) }
        return try await task.value
    }

    private func performDeleteReport(
        reportID: UUID
    ) async throws -> ReportDeletedResponseV1 {
        reportsBeingDeleted.insert(reportID)
        reportDeletionGenerations[reportID, default: 0] &+= 1
        defer { reportsBeingDeleted.remove(reportID) }

        if let pending = pendingReports[reportID] {
            pending.task.cancel()
            _ = await pending.task.result
            pendingReports.removeValue(forKey: reportID)
        }
        let followUps = pendingFollowUps.filter {
            $0.value.reportID == reportID
        }
        followUps.values.forEach { $0.task.cancel() }
        for operation in followUps.values {
            _ = await operation.task.result
        }
        for operationID in followUps.keys {
            pendingFollowUps.removeValue(forKey: operationID)
        }
        guard let record = try await threadStore.thread(for: reportID) else {
            return ReportDeletedResponseV1(reportID: reportID)
        }
        if record.isEphemeral != true {
            do {
                try await client.deleteThread(threadID: record.threadID)
            } catch {
                guard isMissingThread(error) else { throw error }
            }
        }
        loadedThreadIDs.remove(record.threadID)
        try await threadStore.remove(reportID: reportID)
        try? directoryFactory.remove(
            URL(
                fileURLWithPath: record.isolatedWorkingDirectory,
                isDirectory: true
            )
        )
        return ReportDeletedResponseV1(reportID: reportID)
    }

    public func handle(_ envelope: BridgeEnvelopeV1) async -> BridgeEnvelopeV1 {
        do {
            switch envelope.type {
            case .ping:
                _ = try envelope.decodePayload(PingPayloadV1.self)
                return try BridgeEnvelopeV1(
                    id: envelope.id,
                    type: .pong,
                    payload: PongPayloadV1(
                        codexReady: true,
                        capabilities: [
                            BridgeWire.exchangeRatesCapability,
                            BridgeWire.durableAssetRecognitionCapability,
                        ]
                    )
                )
            case .generateReport:
                let request = try envelope.decodePayload(GenerateReportRequestV1.self)
                let response = try await generateReport(
                    reportID: request.reportID,
                    packet: request.packet
                )
                return try BridgeEnvelopeV1(
                    id: envelope.id,
                    type: .reportGenerated,
                    payload: response
                )
            case .recognizeAssets:
                let request = try envelope.decodePayload(
                    RecognizeAssetsRequestV1.self
                )
                let response = try await recognizeAssets(request: request)
                return try BridgeEnvelopeV1(
                    id: envelope.id,
                    type: .assetsRecognized,
                    payload: response
                )
            case .fetchExchangeRates:
                let request = try envelope.decodePayload(
                    FetchExchangeRatesRequestV1.self
                )
                let response = try await exchangeRateFetcher.fetchRates(
                    for: request.snapshotDate,
                    currencies: request.currencies
                )
                return try BridgeEnvelopeV1(
                    id: envelope.id,
                    type: .exchangeRatesFetched,
                    payload: response
                )
            case .followUp:
                let request = try envelope.decodePayload(FollowUpRequestV1.self)
                let response = try await followUp(
                    operationID: request.operationID,
                    reportID: request.reportID,
                    question: request.question
                )
                return try BridgeEnvelopeV1(
                    id: envelope.id,
                    type: .answerGenerated,
                    payload: response
                )
            case .deleteReport:
                let request = try envelope.decodePayload(DeleteReportRequestV1.self)
                let response = try await deleteReport(reportID: request.reportID)
                return try BridgeEnvelopeV1(
                    id: envelope.id,
                    type: .reportDeleted,
                    payload: response
                )
            case .pong, .reportGenerated, .assetsRecognized,
                 .exchangeRatesFetched,
                 .answerGenerated, .reportDeleted,
                 .error, .pairingChallenge, .pairingConfirmation,
                 .credentialProvision, .credentialReceipt,
                 .reconnectChallenge, .reconnectResponse,
                 .authenticationComplete, .tcpReconnectHello,
                 .tcpReconnectInvitation, .tcpReconnectChallenge,
                 .tcpReconnectResponse, .tcpAuthenticationComplete,
                 .secureMessage:
                throw FIREBridgeError.invalidMessage(
                    "Mac 端不接受 \(envelope.type.rawValue) 请求。"
                )
            }
        } catch {
            return errorEnvelope(id: envelope.id, error: error)
        }
    }

    public func shutdown() async {
        await client.disconnect()
        try? directoryFactory.remove(serverWorkingDirectory)
    }

    private func ensureLoaded(_ record: StoredCodexThread) async throws {
        guard !loadedThreadIDs.contains(record.threadID) else { return }
        try await client.resumeThread(
            threadID: record.threadID,
            workingDirectory: URL(
                fileURLWithPath: record.isolatedWorkingDirectory,
                isDirectory: true
            )
        )
        loadedThreadIDs.insert(record.threadID)
    }

    private func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func validateOperationFingerprint(
        _ stored: String?,
        expected: String,
        operationName: String
    ) throws {
        guard stored == nil || stored == expected else {
            throw FIREBridgeError.invalidMessage(
                "同一\(operationName)操作不能复用到不同内容。"
            )
        }
    }

    private func ensureReportWasNotDeleted(
        reportID: UUID,
        deletionGeneration: UInt64
    ) throws {
        try Task.checkCancellation()
        guard !reportsBeingDeleted.contains(reportID),
              reportDeletionGenerations[reportID, default: 0]
                == deletionGeneration else {
            throw FIREBridgeError.threadNotFound(reportID: reportID)
        }
    }

    private func isMissingThread(_ error: Error) -> Bool {
        if case FIREBridgeError.threadNotFound = error {
            return true
        }
        guard case let FIREBridgeError.appServerRejected(_, message) = error else {
            return false
        }
        let normalized = message.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return normalized.contains("thread_not_found")
            || (normalized.contains("thread") && normalized.contains("not_found"))
    }

    private func errorEnvelope(id: UUID, error: Error) -> BridgeEnvelopeV1 {
        let response = BridgeErrorResponseV1(
            code: errorCode(error),
            message: error.localizedDescription,
            retryable: isRetryable(error)
        )
        return (try? BridgeEnvelopeV1(id: id, type: .error, payload: response))
            ?? BridgeEnvelopeV1(id: id, type: .error)
    }

    private func errorCode(_ error: Error) -> String {
        if let rateError = error as? ReferenceExchangeRateError {
            switch rateError {
            case .invalidCurrencies:
                return "invalid_request"
            case .requestFailed, .invalidResponse, .missingCurrency:
                return "exchange_rate_unavailable"
            }
        }
        guard let bridgeError = error as? FIREBridgeError else {
            return "unexpected"
        }
        switch bridgeError {
        case .codexNotFound:
            return "codex_not_found"
        case .codexAuthenticationRequired:
            return "chatgpt_auth_required"
        case .processLaunchFailed, .processExited, .appServerDisconnected:
            return "codex_unavailable"
        case .appServerProtocolError, .invalidStructuredOutput:
            return "invalid_codex_output"
        case .appServerRejected:
            return "codex_rejected"
        case .threadNotFound:
            return "thread_not_found"
        case .pairingRejected:
            return "pairing_rejected"
        case .keychainFailure:
            return "keychain_failure"
        case .invalidMessage:
            return "invalid_request"
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let rateError = error as? ReferenceExchangeRateError {
            switch rateError {
            case .invalidCurrencies:
                return false
            case .requestFailed, .invalidResponse, .missingCurrency:
                return true
            }
        }
        guard let bridgeError = error as? FIREBridgeError else { return false }
        switch bridgeError {
        case .processExited, .appServerDisconnected, .appServerRejected:
            return true
        default:
            return false
        }
    }
}
#endif
