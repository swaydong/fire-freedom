#if os(macOS)
import Foundation
import XCTest
@testable import FIREBridgeKit

final class AssetRecognitionOperationStoreTests: XCTestCase {
    func testCompletedOperationSurvivesStoreRecreation() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let storeURL = rootDirectory.appendingPathComponent("operations.json")
        let operation = StoredAssetRecognitionOperation(
            operationID: UUID(),
            requestFingerprint: "fingerprint",
            response: RecognizeAssetsResponseV1(
                positions: [
                    RecognizedAssetPositionV1(
                        imageIndex: 0,
                        productName: "示例基金",
                        productCode: "000001",
                        kind: .fund,
                        currency: .CNY,
                        originalMarketValue: 12_345.67,
                        confidence: 0.92,
                        evidence: "示例基金 000001 · 市值 12,345.67"
                    ),
                ]
            )
        )
        let firstStore = AssetRecognitionOperationStore(storeURL: storeURL)
        try await firstStore.upsert(operation)

        let reopenedStore = AssetRecognitionOperationStore(storeURL: storeURL)
        let recovered = try await reopenedStore.operation(
            for: operation.operationID
        )

        XCTAssertEqual(recovered, operation)
    }

    func testStorePrunesOldAndExcessOperationsAndUsesPrivatePermissions()
        async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let storeURL = rootDirectory.appendingPathComponent("operations.json")
        let now = Date(timeIntervalSince1970: 10_000_000)
        let store = AssetRecognitionOperationStore(
            storeURL: storeURL,
            maximumOperationCount: 2,
            retentionInterval: 100,
            now: { now }
        )
        let expired = operation(completedAt: now.addingTimeInterval(-101))
        let recent = [
            operation(completedAt: now.addingTimeInterval(-3)),
            operation(completedAt: now.addingTimeInterval(-2)),
            operation(completedAt: now.addingTimeInterval(-1)),
        ]

        try await store.upsert(expired)
        for operation in recent {
            try await store.upsert(operation)
        }

        let retained = try await store.allOperations()
        XCTAssertEqual(
            retained.map(\.operationID),
            recent.suffix(2).map(\.operationID)
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: storeURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    private func operation(
        completedAt: Date
    ) -> StoredAssetRecognitionOperation {
        StoredAssetRecognitionOperation(
            operationID: UUID(),
            requestFingerprint: UUID().uuidString,
            completedAt: completedAt
        )
    }
}
#endif
