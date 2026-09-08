import XCTest
@testable import FIREBridgeKit

final class CodexThreadStoreTests: XCTestCase {
    func testStorePersistsReportToThreadMapping() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("threads.json")
        let reportID = UUID()
        let record = StoredCodexThread(
            reportID: reportID,
            threadID: "thread-123",
            isolatedWorkingDirectory: directory.appendingPathComponent("isolated").path
        )

        let store = CodexThreadStore(storeURL: storeURL)
        try await store.upsert(record)
        let reloadedStore = CodexThreadStore(storeURL: storeURL)

        let reloaded = try await reloadedStore.thread(for: reportID)
        XCTAssertEqual(reloaded, record)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: storeURL.path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        try await reloadedStore.remove(reportID: reportID)
        let removed = try await reloadedStore.thread(for: reportID)
        XCTAssertNil(removed)
    }
}
