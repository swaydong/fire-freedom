#if os(macOS)
import Foundation

public struct StoredAssetRecognitionOperation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let requestFingerprint: String
    public let response: RecognizeAssetsResponseV1?
    public let completedAt: Date

    public init(
        operationID: UUID,
        requestFingerprint: String,
        response: RecognizeAssetsResponseV1? = nil,
        completedAt: Date = Date()
    ) {
        self.operationID = operationID
        self.requestFingerprint = requestFingerprint
        self.response = response
        self.completedAt = completedAt
    }
}

public protocol AssetRecognitionOperationStoring: Sendable {
    func operation(
        for operationID: UUID
    ) async throws -> StoredAssetRecognitionOperation?
    func upsert(_ operation: StoredAssetRecognitionOperation) async throws
    func allOperations() async throws -> [StoredAssetRecognitionOperation]
}

public actor AssetRecognitionOperationStore:
    AssetRecognitionOperationStoring {
    public static let defaultMaximumOperationCount = 100
    public static let defaultRetentionInterval: TimeInterval =
        90 * 24 * 60 * 60

    private let storeURL: URL
    private let fileManager: FileManager
    private let maximumOperationCount: Int
    private let retentionInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [UUID: StoredAssetRecognitionOperation]?

    public init(
        storeURL: URL,
        fileManager: FileManager = .default,
        maximumOperationCount: Int = defaultMaximumOperationCount,
        retentionInterval: TimeInterval = defaultRetentionInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
        self.maximumOperationCount = max(1, maximumOperationCount)
        self.retentionInterval = max(0, retentionInterval)
        self.now = now
    }

    public static func defaultStoreURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("FIREBridge", isDirectory: true)
            .appendingPathComponent(
                "asset-recognition-operations.json"
            )
    }

    public func operation(
        for operationID: UUID
    ) throws -> StoredAssetRecognitionOperation? {
        try loadIfNeeded()[operationID]
    }

    public func upsert(
        _ operation: StoredAssetRecognitionOperation
    ) throws {
        var operations = try loadIfNeeded()
        operations[operation.operationID] = operation
        try save(bounded(operations))
    }

    public func allOperations() throws -> [StoredAssetRecognitionOperation] {
        try loadIfNeeded().values.sorted {
            $0.completedAt < $1.completedAt
        }
    }

    private func loadIfNeeded() throws
        -> [UUID: StoredAssetRecognitionOperation] {
        if let cache {
            return cache
        }
        guard fileManager.fileExists(atPath: storeURL.path) else {
            cache = [:]
            return [:]
        }

        let data = try Data(contentsOf: storeURL)
        try restrictStoreFilePermissions()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let records = try decoder.decode(
            [StoredAssetRecognitionOperation].self,
            from: data
        )
        var loaded: [UUID: StoredAssetRecognitionOperation] = [:]
        records.forEach { loaded[$0.operationID] = $0 }
        loaded = bounded(loaded)
        if loaded.count != records.count {
            try save(loaded)
            return loaded
        }
        cache = loaded
        return loaded
    }

    private func save(
        _ operations: [UUID: StoredAssetRecognitionOperation]
    ) throws {
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        let records = operations.values.sorted {
            $0.completedAt < $1.completedAt
        }
        try encoder.encode(records).write(to: storeURL, options: .atomic)
        try restrictStoreFilePermissions()
        cache = operations
    }

    private func bounded(
        _ operations: [UUID: StoredAssetRecognitionOperation]
    ) -> [UUID: StoredAssetRecognitionOperation] {
        let cutoff = now().addingTimeInterval(-retentionInterval)
        let retained = operations.values
            .filter { $0.completedAt >= cutoff }
            .sorted { $0.completedAt < $1.completedAt }
            .suffix(maximumOperationCount)
        return Dictionary(
            uniqueKeysWithValues: retained.map {
                ($0.operationID, $0)
            }
        )
    }

    private func restrictStoreFilePermissions() throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storeURL.path
        )
    }
}

actor InMemoryAssetRecognitionOperationStore:
    AssetRecognitionOperationStoring {
    private var operations: [UUID: StoredAssetRecognitionOperation] = [:]

    func operation(
        for operationID: UUID
    ) -> StoredAssetRecognitionOperation? {
        operations[operationID]
    }

    func upsert(_ operation: StoredAssetRecognitionOperation) {
        operations[operation.operationID] = operation
    }

    func allOperations() -> [StoredAssetRecognitionOperation] {
        operations.values.sorted { $0.completedAt < $1.completedAt }
    }
}
#endif
