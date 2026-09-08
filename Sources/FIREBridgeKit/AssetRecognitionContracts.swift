import Foundation

public struct AssetOCRBoundingBoxV1: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AssetOCRLineV1: Codable, Equatable, Sendable {
    public let imageIndex: Int
    public let text: String
    public let confidence: Double
    public let boundingBox: AssetOCRBoundingBoxV1

    public init(
        imageIndex: Int,
        text: String,
        confidence: Double,
        boundingBox: AssetOCRBoundingBoxV1
    ) {
        self.imageIndex = imageIndex
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct RecognizeAssetsRequestV1: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let imageCount: Int
    public let lines: [AssetOCRLineV1]

    private enum CodingKeys: String, CodingKey {
        case operationID
        case imageCount
        case lines
    }

    public init(
        operationID: UUID = UUID(),
        imageCount: Int,
        lines: [AssetOCRLineV1]
    ) {
        self.operationID = operationID
        self.imageCount = imageCount
        self.lines = lines
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try container.decodeIfPresent(
            UUID.self,
            forKey: .operationID
        ) ?? UUID()
        imageCount = try container.decode(Int.self, forKey: .imageCount)
        lines = try container.decode([AssetOCRLineV1].self, forKey: .lines)
    }
}

public enum RecognizedAssetKindV1: String, Codable, CaseIterable, Sendable {
    case fund
    case stock
    case cash
}

public enum RecognizedAssetCurrencyV1: String, Codable, CaseIterable, Sendable {
    case CNY
    case USD
    case HKD
}

public enum InstrumentVerificationStatusV1: String, Codable, Sendable {
    case verified
    case ambiguous
    case notFound
    case unavailable
    case notApplicable
}

public struct InstrumentVerificationV1: Codable, Equatable, Sendable {
    public let status: InstrumentVerificationStatusV1
    public let sourceName: String
    public let matchedName: String?
    public let matchedCode: String?
    public let message: String

    public init(
        status: InstrumentVerificationStatusV1,
        sourceName: String,
        matchedName: String? = nil,
        matchedCode: String? = nil,
        message: String
    ) {
        self.status = status
        self.sourceName = sourceName
        self.matchedName = matchedName
        self.matchedCode = matchedCode
        self.message = message
    }
}

public struct RecognizedAssetPositionV1: Codable, Equatable, Sendable {
    public let imageIndex: Int
    public let productName: String
    public let productCode: String?
    public let kind: RecognizedAssetKindV1
    public let currency: RecognizedAssetCurrencyV1
    public let originalMarketValue: Double
    public let confidence: Double
    public let evidence: String
    public let verification: InstrumentVerificationV1?

    public init(
        imageIndex: Int,
        productName: String,
        productCode: String?,
        kind: RecognizedAssetKindV1,
        currency: RecognizedAssetCurrencyV1,
        originalMarketValue: Double,
        confidence: Double,
        evidence: String,
        verification: InstrumentVerificationV1? = nil
    ) {
        self.imageIndex = imageIndex
        self.productName = productName
        self.productCode = productCode
        self.kind = kind
        self.currency = currency
        self.originalMarketValue = originalMarketValue
        self.confidence = confidence
        self.evidence = evidence
        self.verification = verification
    }
}

public struct RecognizeAssetsResponseV1: Codable, Equatable, Sendable {
    public let positions: [RecognizedAssetPositionV1]

    public init(positions: [RecognizedAssetPositionV1]) {
        self.positions = positions
    }
}

enum AssetRecognitionContractValidator {
    static func validate(request: RecognizeAssetsRequestV1) throws {
        guard (1...BridgeWire.maximumAssetImages).contains(request.imageCount) else {
            throw FIREBridgeError.invalidMessage(
                "资产截图数量必须为 1–\(BridgeWire.maximumAssetImages)。"
            )
        }
        guard !request.lines.isEmpty,
              request.lines.count <= BridgeWire.maximumAssetOCRLines else {
            throw FIREBridgeError.invalidMessage(
                "OCR 行数必须为 1–\(BridgeWire.maximumAssetOCRLines)。"
            )
        }
        let totalCharacters = request.lines.reduce(0) { $0 + $1.text.count }
        guard totalCharacters <= BridgeWire.maximumAssetOCRTextCharacters else {
            throw FIREBridgeError.invalidMessage("OCR 文本总长度超过上限。")
        }

        for line in request.lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (0..<request.imageCount).contains(line.imageIndex) else {
                throw FIREBridgeError.invalidMessage("OCR 行包含无效的截图序号。")
            }
            guard !trimmed.isEmpty,
                  line.text.count <= BridgeWire.maximumAssetOCRLineCharacters else {
                throw FIREBridgeError.invalidMessage("OCR 单行文本为空或超过长度上限。")
            }
            guard line.confidence.isFinite,
                  (0...1).contains(line.confidence) else {
                throw FIREBridgeError.invalidMessage("OCR 行置信度必须在 0–1 之间。")
            }
            guard isValid(line.boundingBox) else {
                throw FIREBridgeError.invalidMessage("OCR 行包含无效的归一化坐标。")
            }
        }
    }

    static func validate(
        response: RecognizeAssetsResponseV1,
        imageCount: Int
    ) throws {
        guard response.positions.count <= BridgeWire.maximumRecognizedAssetPositions else {
            throw FIREBridgeError.invalidStructuredOutput("识别结果产品数量超过上限。")
        }
        for position in response.positions {
            let name = position.productName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let code = position.productCode?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let evidence = position.evidence
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (0..<imageCount).contains(position.imageIndex) else {
                throw FIREBridgeError.invalidStructuredOutput(
                    "识别结果包含无效的截图序号。"
                )
            }
            guard !name.isEmpty,
                  name.count <= BridgeWire.maximumRecognizedAssetNameCharacters else {
                throw FIREBridgeError.invalidStructuredOutput(
                    "识别结果产品名称为空或超过长度上限。"
                )
            }
            if let code {
                guard !code.isEmpty,
                      code.count <= BridgeWire.maximumRecognizedAssetCodeCharacters else {
                    throw FIREBridgeError.invalidStructuredOutput(
                        "识别结果产品代码为空或超过长度上限。"
                    )
                }
            }
            guard position.originalMarketValue.isFinite,
                  position.originalMarketValue > 0 else {
                throw FIREBridgeError.invalidStructuredOutput(
                    "识别结果市值必须是大于 0 的有限数值。"
                )
            }
            guard position.confidence.isFinite,
                  (0...1).contains(position.confidence) else {
                throw FIREBridgeError.invalidStructuredOutput(
                    "识别结果置信度必须在 0–1 之间。"
                )
            }
            guard !evidence.isEmpty,
                  evidence.count <= BridgeWire.maximumRecognizedAssetEvidenceCharacters else {
                throw FIREBridgeError.invalidStructuredOutput(
                    "识别结果证据为空或超过长度上限。"
                )
            }
        }
    }

    private static func isValid(_ box: AssetOCRBoundingBoxV1) -> Bool {
        let values = [box.x, box.y, box.width, box.height]
        guard values.allSatisfy(\.isFinite),
              (0...1).contains(box.x),
              (0...1).contains(box.y),
              box.width > 0,
              box.height > 0,
              box.width <= 1,
              box.height <= 1 else {
            return false
        }
        return box.x + box.width <= 1.000_001
            && box.y + box.height <= 1.000_001
    }
}

public enum AssetRecognitionOutputSchema {
    public static let responseV1: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array(["positions"].map(JSONValue.string)),
        "properties": .object([
            "positions": .object([
                "type": .string("array"),
                "maxItems": .number(Double(BridgeWire.maximumRecognizedAssetPositions)),
                "items": position,
            ]),
        ]),
    ])

    private static let position: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([
            "imageIndex",
            "productName",
            "productCode",
            "kind",
            "currency",
            "originalMarketValue",
            "confidence",
            "evidence",
        ].map(JSONValue.string)),
        "properties": .object([
            "imageIndex": integer(minimum: 0),
            "productName": string(
                minLength: 1,
                maxLength: BridgeWire.maximumRecognizedAssetNameCharacters
            ),
            "productCode": .object([
                "anyOf": .array([
                    string(
                        minLength: 1,
                        maxLength: BridgeWire.maximumRecognizedAssetCodeCharacters
                    ),
                    .object(["type": .string("null")]),
                ]),
            ]),
            "kind": enumeration(RecognizedAssetKindV1.allCases.map(\.rawValue)),
            "currency": enumeration(
                RecognizedAssetCurrencyV1.allCases.map(\.rawValue)
            ),
            "originalMarketValue": number(exclusiveMinimum: 0),
            "confidence": number(minimum: 0, maximum: 1),
            "evidence": string(
                minLength: 1,
                maxLength: BridgeWire.maximumRecognizedAssetEvidenceCharacters
            ),
        ]),
    ])

    private static func string(
        minLength: Int,
        maxLength: Int
    ) -> JSONValue {
        .object([
            "type": .string("string"),
            "minLength": .number(Double(minLength)),
            "maxLength": .number(Double(maxLength)),
        ])
    }

    private static func enumeration(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
        ])
    }

    private static func integer(minimum: Double) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .number(minimum),
        ])
    }

    private static func number(
        minimum: Double? = nil,
        maximum: Double? = nil,
        exclusiveMinimum: Double? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("number")]
        if let minimum {
            schema["minimum"] = .number(minimum)
        }
        if let maximum {
            schema["maximum"] = .number(maximum)
        }
        if let exclusiveMinimum {
            schema["exclusiveMinimum"] = .number(exclusiveMinimum)
        }
        return .object(schema)
    }
}
