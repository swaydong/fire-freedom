@testable import FIRECore
import Foundation
import XCTest

final class KapiWorkbookImporterTests: XCTestCase {
    func testControlTotalsExcludeRowsMarkedOutOfCashFlow() {
        let result = KapiImportResult(
            transactions: [
                transaction(
                    date: testDate(2026, 3, 1),
                    amount: 100
                ),
                transaction(
                    date: testDate(2026, 3, 2),
                    amount: 73,
                    included: false
                ),
                transaction(
                    date: testDate(2026, 3, 3),
                    direction: .income,
                    amount: 500
                ),
                transaction(
                    date: testDate(2026, 3, 4),
                    direction: .income,
                    amount: 20,
                    included: false
                ),
            ],
            sheetName: "收支账单"
        )

        XCTAssertEqual(result.expenseTotal, 100)
        XCTAssertEqual(result.incomeTotal, 500)
        XCTAssertEqual(result.transactions.count, 4)
        XCTAssertEqual(result.expenseCount, 2)
        XCTAssertEqual(result.incomeCount, 2)
        XCTAssertEqual(result.includedCount, 2)
        XCTAssertEqual(result.excludedCount, 2)
    }

    func testHeaderMappingDoesNotDependOnColumnOrder() throws {
        let map = try KapiHeaderMap(
            headersByColumn: [
                "J": "金额",
                "B": "交易日期",
                "Q": "收支类型",
                "A": "备注",
            ]
        )
        let row = [
            "A": "商户",
            "B": "2026-03-01",
            "J": "12.5",
            "Q": "支出",
        ]

        XCTAssertEqual(map.value(.date, in: row), "2026-03-01")
        XCTAssertEqual(map.value(.direction, in: row), "支出")
        XCTAssertEqual(map.value(.amount, in: row), "12.5")
        XCTAssertEqual(map.value(.note, in: row), "商户")
    }

    func testMissingRequiredHeaderFailsExplicitly() {
        XCTAssertThrowsError(
            try KapiHeaderMap(headersByColumn: ["A": "日期", "B": "类型"])
        ) { error in
            XCTAssertEqual(
                error as? KapiImportError,
                .missingRequiredHeaders(["金额"])
            )
        }
    }
}

final class KapiWorkbookIntegrationTests: XCTestCase {
    func testOptionalKapiWorkbookImportsWithConsistentMetadata() throws {
        guard let path = ProcessInfo.processInfo.environment["FIRE_KAPI_FIXTURE"],
              !path.isEmpty
        else {
            throw XCTSkip("可设置 FIRE_KAPI_FIXTURE 指向本机自行准备的测试账单。请勿提交个人账单。")
        }

        let result = try KapiWorkbookImporter().importWorkbook(
            at: URL(fileURLWithPath: path)
        )

        XCTAssertEqual(result.sheetName, "收支账单")
        XCTAssertTrue(!result.transactions.isEmpty || result.exportCoverage != nil)
        XCTAssertEqual(
            result.expenseCount + result.incomeCount,
            result.transactions.count
        )
        XCTAssertEqual(
            result.includedCount + result.excludedCount,
            result.transactions.count
        )
        XCTAssertEqual(
            Set(result.transactions.map(\.id)).count,
            result.transactions.count
        )
        XCTAssertTrue(
            result.transactions.allSatisfy {
                $0.amount >= 0 && !$0.fingerprint.isEmpty
            }
        )
        let fingerprints = Set(result.transactions.map(\.fingerprint))
        XCTAssertTrue(
            result.transactions.filter(\.suspectedDuplicate).allSatisfy {
                guard let original = $0.duplicateOfFingerprint else { return false }
                return fingerprints.contains(original)
            }
        )
        if let start = result.periodStart, let end = result.periodEnd {
            XCTAssertLessThanOrEqual(start, end)
        } else {
            XCTAssertTrue(result.transactions.isEmpty)
        }
    }
}
