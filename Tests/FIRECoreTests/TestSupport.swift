import FIRECore
import Foundation

func testDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 12,
    _ minute: Int = 0
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}

func transaction(
    date: Date,
    direction: TransactionDirection = .expense,
    amount: Decimal,
    primary: String = "餐饮",
    secondary: String = "",
    note: String = "",
    included: Bool = true,
    duplicate: Bool = false,
    internalTransfer: Bool = false,
    investmentTrade: Bool = false,
    loanPrincipal: Bool = false,
    refund: Bool = false
) -> TransactionRecord {
    var result = TransactionRecord(
        occurredAt: date,
        direction: direction,
        amount: amount,
        primaryCategory: primary,
        secondaryCategory: secondary,
        merchantNote: note,
        includedInCashFlow: included,
        isInternalTransfer: internalTransfer,
        isInvestmentTrade: investmentTrade,
        isLoanPrincipal: loanPrincipal,
        isRefund: refund,
        suspectedDuplicate: duplicate
    )
    result.fingerprint = TransactionFingerprint.make(for: result)
    return result
}
