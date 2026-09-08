#if os(macOS)
import Foundation
import XCTest
@testable import FIREBridgeKit

// Product names, identifiers, API responses, and amounts are synthetic test fixtures.
final class InstrumentVerificationServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFundVerificationUsesFundOnlySearchAndNeverSendsAmount() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            XCTAssertEqual(query["m"], "9")
            XCTAssertEqual(query["key"], "示例稳健混合A")
            XCTAssertFalse(request.url?.absoluteString.contains("8765") == true)
            return try Self.response(
                for: request,
                body: """
                {
                  "ErrCode": 0,
                  "Datas": [{
                    "CODE": "991001",
                    "NAME": "示例稳健混合A",
                    "CATEGORYDESC": "基金",
                    "STOCKMARKET": null,
                    "NEWTEXCH": null
                  }]
                }
                """
            )
        }
        let verifier = EastmoneyInstrumentVerifier(session: makeSession())
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例稳健混合A",
            productCode: nil,
            kind: .fund,
            currency: .CNY,
            originalMarketValue: 8_765.43,
            confidence: 0.93,
            evidence: "示例稳健混合A · 8,765.43"
        )

        let verified = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(verified.first)

        XCTAssertEqual(output.productCode, "991001")
        XCTAssertEqual(output.productName, "示例稳健混合A")
        XCTAssertEqual(output.verification?.status, .verified)
    }

    func testStockVerificationFiltersNonStockResultsAndInfersHongKongCurrency() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            XCTAssertEqual(query["m"], "1")
            XCTAssertEqual(query["key"], "09875")
            return try Self.response(
                for: request,
                body: """
                {
                  "ErrCode": 0,
                  "Datas": [
                    {
                      "CODE": "09875",
                      "NAME": "示例基金",
                      "CATEGORYDESC": "基金",
                      "STOCKMARKET": null,
                      "NEWTEXCH": null
                    },
                    {
                      "CODE": "09875",
                      "NAME": "示例控股",
                      "CATEGORYDESC": "港股",
                      "STOCKMARKET": "5",
                      "NEWTEXCH": "116"
                    }
                  ]
                }
                """
            )
        }
        let verifier = EastmoneyInstrumentVerifier(session: makeSession())
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例控股",
            productCode: "09875",
            kind: .stock,
            currency: .CNY,
            originalMarketValue: 10_000,
            confidence: 0.9,
            evidence: "示例控股 09875 10,000"
        )

        let verified = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(verified.first)

        XCTAssertEqual(output.productName, "示例控股")
        XCTAssertEqual(output.productCode, "09875")
        XCTAssertEqual(output.currency, .HKD)
        XCTAssertEqual(output.verification?.status, .verified)
    }

    func testNetworkFailureKeepsCandidateAndMarksVerificationUnavailable() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let verifier = EastmoneyInstrumentVerifier(session: makeSession())
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例稳健混合A",
            productCode: nil,
            kind: .fund,
            currency: .CNY,
            originalMarketValue: 8_765.43,
            confidence: 0.93,
            evidence: "示例稳健混合A · 8,765.43"
        )

        let verified = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(verified.first)

        XCTAssertEqual(output.productName, input.productName)
        XCTAssertEqual(output.originalMarketValue, input.originalMarketValue)
        XCTAssertEqual(output.verification?.status, .unavailable)
    }

    func testTruncatedLegacyFundNameCanMatchAUniqueCatalogAlias() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            XCTAssertEqual(
                query["key"],
                "示例环球创新科技指数（QDII"
            )
            return try Self.response(
                for: request,
                body: """
                {
                  "ErrCode": 0,
                  "Datas": [
                    {
                      "CODE": "991002",
                      "NAME": "示例环球科技指数(LOF)A",
                      "CATEGORYDESC": "基金",
                      "FundBaseInfo": {
                        "OTHERNAME": "示例环球创新科技指数QDII,环球科技"
                      }
                    },
                    {
                      "CODE": "991003",
                      "NAME": "示例环球科技指数(LOF)C",
                      "CATEGORYDESC": "基金",
                      "FundBaseInfo": {"OTHERNAME": ""}
                    }
                  ]
                }
                """
            )
        }
        let verifier = EastmoneyInstrumentVerifier(session: makeSession())
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例环球创新科技指数（QDII-⋯",
            productCode: nil,
            kind: .fund,
            currency: .CNY,
            originalMarketValue: 23_456.78,
            confidence: 0.68,
            evidence: "示例环球创新科技指数（QDII-⋯ · 23,456.78"
        )

        let verified = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(verified.first)

        XCTAssertEqual(output.productCode, "991002")
        XCTAssertEqual(output.productName, "示例环球科技指数(LOF)A")
        XCTAssertEqual(output.verification?.status, .verified)
    }

    func testGenericAliasCannotHideOtherPrefixCandidates() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            XCTAssertEqual(query["m"], "9")
            XCTAssertEqual(query["key"], "示例科技ETF")
            return try Self.response(
                for: request,
                body: """
                {
                  "ErrCode": 0,
                  "Datas": [
                    {
                      "CODE": "991004",
                      "NAME": "示例科技ETF甲类",
                      "CATEGORYDESC": "基金",
                      "FundBaseInfo": {"OTHERNAME": "示例科技ETF"}
                    },
                    {
                      "CODE": "991005",
                      "NAME": "示例科技ETF乙类",
                      "CATEGORYDESC": "基金",
                      "FundBaseInfo": {"OTHERNAME": ""}
                    }
                  ]
                }
                """
            )
        }
        let verifier = EastmoneyInstrumentVerifier(session: makeSession())
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例科技ETF",
            productCode: nil,
            kind: .fund,
            currency: .CNY,
            originalMarketValue: 50_000,
            confidence: 0.8,
            evidence: "示例科技ETF · 50,000"
        )

        let verified = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(verified.first)

        XCTAssertNil(output.productCode)
        XCTAssertEqual(output.productName, "示例科技ETF")
        XCTAssertEqual(output.verification?.status, .ambiguous)
    }

    func testSuppliedCodeIsNeverReplacedByANameOnlyMatch() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            XCTAssertEqual(query["key"], "999999")
            return try Self.response(
                for: request,
                body: #"{"ErrCode":0,"Datas":[]}"#
            )
        }
        let verifier = EastmoneyInstrumentVerifier(session: makeSession())
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例稳健混合A",
            productCode: "999999",
            kind: .fund,
            currency: .CNY,
            originalMarketValue: 8_765.43,
            confidence: 0.93,
            evidence: "示例稳健混合A · 8,765.43"
        )

        let verified = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(verified.first)

        XCTAssertEqual(output.productCode, "999999")
        XCTAssertEqual(output.productName, "示例稳健混合A")
        XCTAssertEqual(output.verification?.status, .notFound)
        XCTAssertEqual(
            output.verification?.message,
            "公开产品目录未匹配截图中的代码；已保留原代码，不会按名称改写。"
        )
    }

    func testCorrectsKindWhenExactNameExistsOnlyInOtherDirectory() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            if query["m"] == "1" {
                return try Self.response(
                    for: request,
                    body: #"{"ErrCode":0,"Datas":[]}"#
                )
            }
            XCTAssertEqual(query["m"], "9")
            return try Self.response(
                for: request,
                body: """
                {
                  "ErrCode": 0,
                  "Datas": [{
                    "CODE": "991001",
                    "NAME": "示例稳健混合A",
                    "CATEGORYDESC": "基金"
                  }]
                }
                """
            )
        }
        let verifier = EastmoneyInstrumentVerifier(session: makeSession())
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例稳健混合A",
            productCode: nil,
            kind: .stock,
            currency: .CNY,
            originalMarketValue: 8_765.43,
            confidence: 0.93,
            evidence: "示例稳健混合A · 8,765.43"
        )

        let verified = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(verified.first)

        XCTAssertEqual(output.kind, .fund)
        XCTAssertEqual(output.productCode, "991001")
        XCTAssertEqual(output.verification?.status, .verified)
    }

    func testCompatibilityNormalizesFullWidthProductCode() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                }
            )
            XCTAssertEqual(query["key"], "991001")
            return try Self.response(
                for: request,
                body: """
                {
                  "ErrCode": 0,
                  "Datas": [{
                    "CODE": "991001",
                    "NAME": "示例稳健混合A",
                    "CATEGORYDESC": "基金"
                  }]
                }
                """
            )
        }
        let verifier = EastmoneyInstrumentVerifier(session: makeSession())
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例稳健混合A",
            productCode: "９９１００１",
            kind: .fund,
            currency: .CNY,
            originalMarketValue: 8_765.43,
            confidence: 0.93,
            evidence: "示例稳健混合A · ９９１００１ · 8,765.43"
        )

        let verified = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(verified.first)

        XCTAssertEqual(output.productCode, "991001")
        XCTAssertEqual(output.verification?.status, .verified)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        for request: URLRequest,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, Data(body.utf8))
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
#endif
