import Foundation
@testable import FIREBridgeKit

/// Entirely fictional records for exercising directory matching and source schema.
/// These are not FinanceDatabase extracts or official market data.
enum SyntheticInstrumentDirectory {
    static func make() throws -> LocalInstrumentDirectory {
        try LocalInstrumentDirectory(data: Data(document.utf8))
    }

    private static let document = #"""
    {
      "schemaVersion": 1,
      "sources": [
        {
          "id": "synthetic-database",
          "kind": "financeDatabase",
          "displayName": "Synthetic database fixture",
          "sourceURL": "https://example.invalid/synthetic-database",
          "version": "test-only",
          "license": "MIT",
          "asOf": "2020-01-01",
          "notes": "Fictional test data exercising the FinanceDatabase source schema; not extracted market data."
        },
        {
          "id": "synthetic-overlay",
          "kind": "officialOverlay",
          "displayName": "Synthetic overlay fixture",
          "sourceURL": "https://example.invalid/synthetic-overlay",
          "version": "test-only",
          "license": "MIT",
          "asOf": "2020-01-02",
          "notes": "Fictional test data exercising the overlay schema; not an official product source."
        }
      ],
      "instruments": [
        {
          "id": "NASDAQ:DEMO",
          "code": "DEMO",
          "alternateCodes": [],
          "name": "Synthetic Example Company",
          "searchAliases": ["示例公司"],
          "kind": "stock",
          "currency": "USD",
          "exchange": "NASDAQ",
          "sourceIDs": ["synthetic-database"]
        },
        {
          "id": "HKEX:09875",
          "code": "9875.HK",
          "alternateCodes": ["09875", "9875"],
          "name": "Synthetic Example Company",
          "searchAliases": ["示例公司"],
          "kind": "stock",
          "currency": "HKD",
          "exchange": "HKEX",
          "sourceIDs": ["synthetic-database"]
        },
        {
          "id": "HKEX:09876",
          "code": "09876",
          "alternateCodes": ["9876", "09876.HK", "9876.HK"],
          "name": "Synthetic Technology Index ETF",
          "searchAliases": ["示例科技ETF"],
          "kind": "fund",
          "currency": "HKD",
          "exchange": "HKEX",
          "sourceIDs": ["synthetic-overlay"]
        }
      ]
    }
    """#
}
