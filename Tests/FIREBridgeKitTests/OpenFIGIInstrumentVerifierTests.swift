#if os(macOS)
import Foundation
import XCTest
@testable import FIREBridgeKit

// Product names, identifiers, API responses, and amounts are synthetic test fixtures.
final class OpenFIGIInstrumentVerifierTests: XCTestCase {
    override func tearDown() {
        OpenFIGIMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testHongKongCodeUsesTickerWithoutLeadingZeroAndKeepsCanonicalCode()
        async throws {
        OpenFIGIMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-OPENFIGI-APIKEY"))
            let body = try Self.requestBody(request)
            let jobs = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [[String: String]]
            )
            XCTAssertEqual(jobs.count, 1)
            XCTAssertEqual(jobs[0]["idType"], "TICKER")
            XCTAssertEqual(jobs[0]["idValue"], "9876")
            XCTAssertEqual(jobs[0]["micCode"], "XHKG")
            return try Self.response(
                for: request,
                body: """
                [{
                  "data": [{
                    "figi": "BBG000TEST01",
                    "name": "SYNTHETIC TECHNOLOGY INDEX ETF-H",
                    "ticker": "9876",
                    "exchCode": "HK",
                    "compositeFIGI": "BBG000TEST02",
                    "securityType": "ETP",
                    "marketSector": "Equity",
                    "securityType2": "Mutual Fund"
                  }]
                }]
                """
            )
        }
        let verifier = OpenFIGIInstrumentVerifier(
            session: makeSession(),
            apiKey: nil
        )
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例科技ETF",
            productCode: "09876",
            kind: .fund,
            currency: .CNY,
            originalMarketValue: 123_456,
            confidence: 0.91,
            evidence: "示例科技ETF 09876 123,456"
        )

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertEqual(output.productName, "示例科技ETF")
        XCTAssertEqual(output.productCode, "09876")
        XCTAssertEqual(output.kind, .fund)
        XCTAssertEqual(output.currency, .HKD)
        XCTAssertEqual(output.verification?.status, .verified)
        XCTAssertEqual(output.verification?.sourceName, "OpenFIGI")
        XCTAssertEqual(
            output.verification?.matchedName,
            "SYNTHETIC TECHNOLOGY INDEX ETF-H"
        )
    }

    func testNoOpenFIGIMappingPreservesScreenshotCode() async throws {
        OpenFIGIMockURLProtocol.requestHandler = { request in
            try Self.response(
                for: request,
                body: #"[{"warning":"No identifier found."}]"#
            )
        }
        let verifier = OpenFIGIInstrumentVerifier(
            session: makeSession(),
            apiKey: nil
        )
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例科技ETF",
            productCode: "09876",
            kind: .fund,
            currency: .HKD,
            originalMarketValue: 123_456,
            confidence: 0.91,
            evidence: "示例科技ETF 09876 123,456"
        )

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertEqual(output.productCode, "09876")
        XCTAssertEqual(output.productName, "示例科技ETF")
        XCTAssertEqual(output.verification?.status, .notFound)
    }

    func testAmbiguousHigherTrustResultStopsLowerLayerRewrite()
        async throws {
        let input = RecognizedAssetPositionV1(
            imageIndex: 0,
            productName: "示例科技ETF",
            productCode: nil,
            kind: .fund,
            currency: .CNY,
            originalMarketValue: 123_456,
            confidence: 0.91,
            evidence: "示例科技ETF 123,456"
        )
        let verifier = LayeredInstrumentVerifier(
            verifiers: [
                StubInstrumentVerifier(
                    status: .ambiguous,
                    code: nil,
                    sourceName: "本地候选库"
                ),
                StubInstrumentVerifier(
                    status: .verified,
                    code: "991004",
                    sourceName: "低优先级名称目录"
                ),
            ]
        )

        let outputs = await verifier.verify(positions: [input])
        let output = try XCTUnwrap(outputs.first)

        XCTAssertNil(output.productCode)
        XCTAssertEqual(output.verification?.status, .ambiguous)
        XCTAssertEqual(output.verification?.sourceName, "本地候选库")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenFIGIMockURLProtocol.self]
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

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct StubInstrumentVerifier: InstrumentVerifying {
    let status: InstrumentVerificationStatusV1
    let code: String?
    let sourceName: String

    func verify(
        positions: [RecognizedAssetPositionV1]
    ) async -> [RecognizedAssetPositionV1] {
        positions.map { position in
            RecognizedAssetPositionV1(
                imageIndex: position.imageIndex,
                productName: position.productName,
                productCode: code ?? position.productCode,
                kind: position.kind,
                currency: position.currency,
                originalMarketValue: position.originalMarketValue,
                confidence: position.confidence,
                evidence: position.evidence,
                verification: InstrumentVerificationV1(
                    status: status,
                    sourceName: sourceName,
                    message: sourceName
                )
            )
        }
    }
}

private final class OpenFIGIMockURLProtocol:
    URLProtocol,
    @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
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
