import Foundation
import XCTest
@testable import FIREBridgeKit

final class AssetRecognitionContractTests: XCTestCase {
    func testRequestRejectsOversizedTextAndTooManyLines() {
        let oversizedText = RecognizeAssetsRequestV1(
            imageCount: 1,
            lines: [
                line(
                    text: String(
                        repeating: "字",
                        count: BridgeWire.maximumAssetOCRLineCharacters + 1
                    )
                ),
            ]
        )
        XCTAssertThrowsError(
            try AssetRecognitionContractValidator.validate(request: oversizedText)
        )

        let tooManyLines = RecognizeAssetsRequestV1(
            imageCount: 1,
            lines: Array(
                repeating: line(text: "资产"),
                count: BridgeWire.maximumAssetOCRLines + 1
            )
        )
        XCTAssertThrowsError(
            try AssetRecognitionContractValidator.validate(request: tooManyLines)
        )
    }

    func testUnsupportedKindAndCurrencyCannotDecode() throws {
        let valid = """
        {
          "positions": [{
            "imageIndex": 0,
            "productName": "示例",
            "productCode": null,
            "kind": "fund",
            "currency": "CNY",
            "originalMarketValue": 100,
            "confidence": 0.8,
            "evidence": "示例 100"
          }]
        }
        """
        let decoder = JSONDecoder()
        XCTAssertThrowsError(
            try decoder.decode(
                RecognizeAssetsResponseV1.self,
                from: Data(valid.replacingOccurrences(
                    of: #""kind": "fund""#,
                    with: #""kind": "bond""#
                ).utf8)
            )
        )
        XCTAssertThrowsError(
            try decoder.decode(
                RecognizeAssetsResponseV1.self,
                from: Data(valid.replacingOccurrences(
                    of: #""currency": "CNY""#,
                    with: #""currency": "EUR""#
                ).utf8)
            )
        )
    }

    func testLegacyRequestWithoutOperationIDStillDecodes() throws {
        let legacyJSON = """
        {
          "imageCount": 1,
          "lines": [{
            "imageIndex": 0,
            "text": "示例基金",
            "confidence": 0.9,
            "boundingBox": {
              "x": 0,
              "y": 0,
              "width": 0.5,
              "height": 0.1
            }
          }]
        }
        """

        let request = try JSONDecoder().decode(
            RecognizeAssetsRequestV1.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(request.imageCount, 1)
        XCTAssertEqual(request.lines.first?.text, "示例基金")
    }

    private func line(text: String) -> AssetOCRLineV1 {
        AssetOCRLineV1(
            imageIndex: 0,
            text: text,
            confidence: 0.9,
            boundingBox: .init(x: 0, y: 0, width: 0.5, height: 0.1)
        )
    }
}
