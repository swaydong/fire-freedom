import FIRECore
import Foundation

public enum AnalysisOutputSchema {
    public static let reportV1: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": required([
            "schemaVersion",
            "coreConclusion",
            "dataConfidence",
            "spendingFindings",
            "assetStructureRisks",
            "fireDrivers",
            "actions",
            "evidence",
            "limitations",
        ]),
        "properties": .object([
            "schemaVersion": constantString("1.0"),
            "coreConclusion": string(minLength: 1, maxLength: 60),
            "dataConfidence": confidence(),
            "spendingFindings": findingArray(maxItems: 3),
            "assetStructureRisks": findingArray(),
            "fireDrivers": findingArray(),
            "actions": actionArray(),
            "evidence": evidenceArray(),
            "limitations": stringArray(
                maxItems: 1,
                itemMaxLength: 60
            ),
        ]),
    ])

    public static let answerV1: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": required([
            "schemaVersion",
            "answer",
            "evidenceRefs",
            "limitations",
            "refusedInvestmentInstruction",
        ]),
        "properties": .object([
            "schemaVersion": constantString("1.0"),
            "answer": string(minLength: 1),
            "evidenceRefs": stringArray(),
            "limitations": stringArray(),
            "refusedInvestmentInstruction": .object([
                "type": .string("boolean"),
            ]),
        ]),
    ])

    private static func confidence() -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": required(["level", "explanation", "evidenceRefs"]),
            "properties": .object([
                "level": .object([
                    "type": .string("string"),
                    "enum": .array([
                        "insufficient", "low", "medium", "high",
                    ].map(JSONValue.string)),
                ]),
                "explanation": string(minLength: 1, maxLength: 50),
                "evidenceRefs": stringArray(minItems: 1, maxItems: 2),
            ]),
        ])
    }

    private static func findingArray(maxItems: Int = 1) -> JSONValue {
        .object([
            "type": .string("array"),
            "maxItems": .number(Double(maxItems)),
            "items": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": required(["title", "detail", "evidenceRefs"]),
                "properties": .object([
                    "title": string(minLength: 1, maxLength: 18),
                    "detail": string(minLength: 1, maxLength: 70),
                    "evidenceRefs": stringArray(minItems: 1, maxItems: 2),
                ]),
            ]),
        ])
    }

    private static func actionArray() -> JSONValue {
        .object([
            "type": .string("array"),
            "minItems": .number(1),
            "maxItems": .number(2),
            "items": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": required(["title", "rationale", "evidenceRefs"]),
                "properties": .object([
                    "title": string(minLength: 1, maxLength: 18),
                    "rationale": string(minLength: 1, maxLength: 60),
                    "evidenceRefs": stringArray(minItems: 1, maxItems: 2),
                ]),
            ]),
        ])
    }

    private static func evidenceArray() -> JSONValue {
        .object([
            "type": .string("array"),
            "minItems": .number(1),
            "maxItems": .number(6),
            "items": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": required([
                    "id", "label", "value", "transactionFingerprints",
                ]),
                "properties": .object([
                    "id": string(minLength: 1, maxLength: 40),
                    "label": string(minLength: 1, maxLength: 24),
                    "value": string(minLength: 1, maxLength: 100),
                    "transactionFingerprints": stringArray(),
                ]),
            ]),
        ])
    }

    private static func constantString(_ value: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "const": .string(value),
        ])
    }

    private static func string(
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string")]
        if let minLength {
            schema["minLength"] = .number(Double(minLength))
        }
        if let maxLength {
            schema["maxLength"] = .number(Double(maxLength))
        }
        return .object(schema)
    }

    private static func stringArray(
        minItems: Int? = nil,
        maxItems: Int? = nil,
        itemMaxLength: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("array"),
            "items": string(maxLength: itemMaxLength),
        ]
        if let minItems {
            schema["minItems"] = .number(Double(minItems))
        }
        if let maxItems {
            schema["maxItems"] = .number(Double(maxItems))
        }
        return .object(schema)
    }

    private static func required(_ names: [String]) -> JSONValue {
        .array(names.map(JSONValue.string))
    }
}

extension AnalysisAnswerV1 {
    func validateBridgeContract() throws {
        guard schemaVersion == "1.0" else {
            throw FIREBridgeError.invalidStructuredOutput(
                "追问回答 schemaVersion 必须为 1.0。"
            )
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FIREBridgeError.invalidStructuredOutput("追问回答为空。")
        }
    }
}
