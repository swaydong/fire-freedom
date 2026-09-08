#if os(macOS)
import FIRECore
import Foundation

public struct StoredFollowUpOperation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let questionFingerprint: String
    public let redactedQuestion: String?
    public let answer: AnalysisAnswerV1
    public let completedAt: Date

    public init(
        operationID: UUID,
        questionFingerprint: String,
        redactedQuestion: String? = nil,
        answer: AnalysisAnswerV1,
        completedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.questionFingerprint = questionFingerprint
        self.redactedQuestion = redactedQuestion
        self.answer = answer
        self.completedAt = completedAt
    }
}

public struct StoredCodexThread: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let threadID: String
    public let isolatedWorkingDirectory: String
    public let createdAt: Date
    public var updatedAt: Date
    public var evidenceIDs: [String]?
    public var reportRequestFingerprint: String?
    public var generatedReport: AnalysisReportV1?
    public var completedFollowUps: [StoredFollowUpOperation]?
    public var isEphemeral: Bool?
    public var redactedPacket: AnalysisPacketV1?

    public init(
        reportID: UUID,
        threadID: String,
        isolatedWorkingDirectory: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        evidenceIDs: [String]? = nil,
        reportRequestFingerprint: String? = nil,
        generatedReport: AnalysisReportV1? = nil,
        completedFollowUps: [StoredFollowUpOperation]? = nil,
        isEphemeral: Bool? = nil,
        redactedPacket: AnalysisPacketV1? = nil
    ) {
        self.reportID = reportID
        self.threadID = threadID
        self.isolatedWorkingDirectory = isolatedWorkingDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.evidenceIDs = evidenceIDs
        self.reportRequestFingerprint = reportRequestFingerprint
        self.generatedReport = generatedReport
        self.completedFollowUps = completedFollowUps
        self.isEphemeral = isEphemeral
        self.redactedPacket = redactedPacket
    }
}

public protocol CodexThreadStoring: Sendable {
    func thread(for reportID: UUID) async throws -> StoredCodexThread?
    func upsert(_ thread: StoredCodexThread) async throws
    func remove(reportID: UUID) async throws
    func allThreads() async throws -> [StoredCodexThread]
}

public actor CodexThreadStore: CodexThreadStoring {
    private let storeURL: URL
    private let fileManager: FileManager
    private var cache: [UUID: StoredCodexThread]?

    public init(storeURL: URL, fileManager: FileManager = .default) {
        self.storeURL = storeURL
        self.fileManager = fileManager
    }

    public static func defaultStoreURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("FIREBridge", isDirectory: true)
            .appendingPathComponent("codex-threads.json")
    }

    public func thread(for reportID: UUID) throws -> StoredCodexThread? {
        try loadIfNeeded()[reportID]
    }

    public func upsert(_ thread: StoredCodexThread) throws {
        var threads = try loadIfNeeded()
        threads[thread.reportID] = thread
        try save(threads)
    }

    public func remove(reportID: UUID) throws {
        var threads = try loadIfNeeded()
        threads.removeValue(forKey: reportID)
        try save(threads)
    }

    public func allThreads() throws -> [StoredCodexThread] {
        Array(try loadIfNeeded().values).sorted { $0.createdAt < $1.createdAt }
    }

    private func loadIfNeeded() throws -> [UUID: StoredCodexThread] {
        if let cache {
            return cache
        }
        guard fileManager.fileExists(atPath: storeURL.path) else {
            cache = [:]
            return [:]
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let records: [StoredCodexThread]
        do {
            records = try decoder.decode([StoredCodexThread].self, from: data)
        } catch {
            let legacyDecoder = JSONDecoder()
            legacyDecoder.dateDecodingStrategy = .iso8601
            records = try legacyDecoder.decode(
                [StoredCodexThread].self,
                from: data
            )
        }
        var loaded: [UUID: StoredCodexThread] = [:]
        records.forEach { loaded[$0.reportID] = $0 }
        cache = loaded
        return loaded
    }

    private func save(_ threads: [UUID: StoredCodexThread]) throws {
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        let records = threads.values.sorted { $0.createdAt < $1.createdAt }
        try encoder.encode(records).write(to: storeURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
        cache = threads
    }
}

public struct IsolatedWorkingDirectoryFactory: @unchecked Sendable {
    private let baseURL: URL
    private let fileManager: FileManager

    public init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    public static func defaultFactory(fileManager: FileManager = .default) throws -> Self {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(
            baseURL: applicationSupport
                .appendingPathComponent("FIREBridge", isDirectory: true)
                .appendingPathComponent("IsolatedThreads", isDirectory: true),
            fileManager: fileManager
        )
    }

    public func create() throws -> URL {
        try fileManager.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
        let directory = baseURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard contents.isEmpty else {
            throw FIREBridgeError.processLaunchFailed("隔离工作目录不是空目录。")
        }
        return directory
    }

    public func remove(_ directory: URL) throws {
        let basePath = baseURL.standardizedFileURL.path
        let target = directory.standardizedFileURL
        guard target.deletingLastPathComponent().path == basePath,
              UUID(uuidString: target.lastPathComponent) != nil else {
            throw FIREBridgeError.invalidMessage("拒绝删除隔离目录之外的路径。")
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }
}
#endif
