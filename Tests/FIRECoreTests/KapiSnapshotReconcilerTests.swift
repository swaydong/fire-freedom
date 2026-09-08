@testable import FIRECore
import Foundation
import XCTest

final class KapiSnapshotReconcilerTests: XCTestCase {
    func testSemanticFingerprintNormalizesTextAndTagOrder() {
        var lhs = sourceTransaction()
        lhs.primaryCategory = "  Travel   Expense "
        lhs.merchantNote = "CAFÉ   SHOP"
        lhs.tags = [" Work ", "TRAVEL", "work"]
        lhs.ledgerName = " Main   Ledger "

        var rhs = sourceTransaction()
        rhs.primaryCategory = "travel expense"
        rhs.merchantNote = "cafe\u{301} shop"
        rhs.tags = ["travel", "work"]
        rhs.ledgerName = "main ledger"

        XCTAssertEqual(
            KapiSnapshotFingerprint.make(
                for: lhs,
                splitDetails: " Item   One "
            ),
            KapiSnapshotFingerprint.make(
                for: rhs,
                splitDetails: "item one"
            )
        )
    }

    func testSemanticFingerprintCoversEverySourceSemanticField() {
        let base = KapiSnapshotItem(
            transaction: sourceTransaction(),
            splitDetails: "split-a"
        )
        var variants: [KapiSnapshotItem] = []

        appendVariant(of: base, to: &variants) {
            $0.transaction.occurredAt.addTimeInterval(1)
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.direction = .income
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.amount += 1
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.currency = .usd
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.primaryCategory = "旅行"
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.secondaryCategory = "机票"
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.merchantNote = "新商户"
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.tags = ["新标签"]
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.accountName = "信用卡"
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.ledgerName = "家庭账本"
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.includedInCashFlow.toggle()
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.includedInBudget.toggle()
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.isInternalTransfer.toggle()
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.isInvestmentTrade.toggle()
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.isLoanPrincipal.toggle()
        }
        appendVariant(of: base, to: &variants) {
            $0.transaction.isRefund.toggle()
        }
        appendVariant(of: base, to: &variants) {
            $0.splitDetails = "split-b"
        }

        for variant in variants {
            XCTAssertNotEqual(
                variant.semanticFingerprint,
                base.semanticFingerprint
            )
        }
        XCTAssertEqual(Set(variants.map(\.semanticFingerprint)).count, 17)
    }

    func testReconcilePreservesMultiplicityAndInputOrder() {
        let previousA1 = item(note: "A")
        let previousA2 = item(note: "A")
        let previousB = item(note: "B", amount: 20)
        let removedC = item(note: "C", amount: 30)
        let incomingA1 = item(note: "A")
        let incomingA2 = item(note: "A")
        let addedA3 = item(note: "A")
        let incomingB = item(note: "B", amount: 20)
        let addedD = item(note: "D", amount: 40)

        let result = KapiSnapshotReconciler.reconcile(
            previous: [previousA1, previousA2, previousB, removedC],
            incoming: [incomingA1, incomingA2, addedA3, incomingB, addedD],
            suggestsPossibleModifications: false
        )

        XCTAssertEqual(result.unchanged.count, 3)
        XCTAssertEqual(
            result.unchanged.map(\.previous.transaction.id),
            [
                previousA1.transaction.id,
                previousA2.transaction.id,
                previousB.transaction.id,
            ]
        )
        XCTAssertEqual(
            result.added.map(\.transaction.id),
            [addedA3.transaction.id, addedD.transaction.id]
        )
        XCTAssertEqual(
            result.removed.map(\.transaction.id),
            [removedC.transaction.id]
        )
        XCTAssertEqual(result.multiplicityChanges.count, 3)

        let aChange = result.multiplicityChanges.first {
            $0.semanticFingerprint == previousA1.semanticFingerprint
        }
        XCTAssertEqual(aChange?.previousCount, 2)
        XCTAssertEqual(aChange?.incomingCount, 3)
        XCTAssertEqual(aChange?.unchangedCount, 2)
        XCTAssertEqual(aChange?.addedCount, 1)
        XCTAssertEqual(aChange?.removedCount, 0)
    }

    func testPossibleModificationDoesNotReclassifyAddedOrRemovedItems() {
        let previous = item(note: "咖啡店", category: "餐饮")
        var incoming = previous
        incoming.transaction.id = UUID()
        incoming.transaction.primaryCategory = "休闲娱乐"

        let result = KapiSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [incoming]
        )

        XCTAssertTrue(result.unchanged.isEmpty)
        XCTAssertEqual(result.added, [incoming])
        XCTAssertEqual(result.removed, [previous])
        XCTAssertEqual(result.possibleModifications.count, 1)
        XCTAssertEqual(
            result.possibleModifications[0].previous,
            previous
        )
        XCTAssertEqual(
            result.possibleModifications[0].incoming,
            incoming
        )
        XCTAssertTrue(
            result.possibleModifications[0].matchingFields.contains(.amount)
        )
    }

    func testUnrelatedAddedAndRemovedItemsAreNotSuggestedAsModification() {
        let previous = item(note: "早餐", amount: 20)
        var incoming = item(note: "机票", amount: 2_000)
        incoming.transaction.occurredAt = testDate(2026, 4, 2)

        let result = KapiSnapshotReconciler.reconcile(
            previous: [previous],
            incoming: [incoming]
        )

        XCTAssertEqual(result.added, [incoming])
        XCTAssertEqual(result.removed, [previous])
        XCTAssertTrue(result.possibleModifications.isEmpty)
    }

    private func appendVariant(
        of base: KapiSnapshotItem,
        to values: inout [KapiSnapshotItem],
        mutation: (inout KapiSnapshotItem) -> Void
    ) {
        var value = base
        mutation(&value)
        values.append(value)
    }

    private func sourceTransaction() -> TransactionRecord {
        TransactionRecord(
            occurredAt: testDate(2026, 3, 1, 10, 30),
            direction: .expense,
            amount: Decimal(string: "88.50")!,
            currency: .cny,
            primaryCategory: "餐饮",
            secondaryCategory: "咖啡",
            merchantNote: "咖啡店",
            tags: ["日常", "上班"],
            accountName: "支付宝",
            ledgerName: "日常账本",
            includedInCashFlow: true,
            includedInBudget: true
        )
    }

    private func item(
        note: String,
        amount: Decimal = 10,
        category: String = "餐饮"
    ) -> KapiSnapshotItem {
        KapiSnapshotItem(
            transaction: TransactionRecord(
                occurredAt: testDate(2026, 4, 1),
                direction: .expense,
                amount: amount,
                primaryCategory: category,
                secondaryCategory: "",
                merchantNote: note,
                tags: ["日常"],
                accountName: "支付宝",
                ledgerName: "日常账本",
                includedInCashFlow: true,
                includedInBudget: true
            )
        )
    }
}
