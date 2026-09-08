import FIRECore
import Foundation

public enum BridgeWire {
    public static let protocolVersion = "1"
    public static let serviceType = "fire-freedom"
    public static let tcpServiceType = "fire-bridge"
    public static let transportDomain = "bonjour-tcp-v1"
    public static let exchangeRatesCapability = "exchange-rates-ecb-v1"
    public static let durableAssetRecognitionCapability =
        "asset-recognition-durable-v1"
    public static let maximumMessageBytes = 8 * 1_024 * 1_024
    public static let maximumQuestionCharacters = 4_000
    public static let maximumAssetImages = 30
    public static let maximumAssetOCRLines = 2_000
    public static let maximumAssetOCRLineCharacters = 500
    public static let maximumAssetOCRTextCharacters = 100_000
    public static let maximumRecognizedAssetPositions = 500
    public static let maximumRecognizedAssetNameCharacters = 200
    public static let maximumRecognizedAssetCodeCharacters = 40
    public static let maximumRecognizedAssetEvidenceCharacters = 2_000

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum BridgeEnvelopeTypeV1: String, Codable, Sendable {
    case ping
    case pong
    case generateReport
    case reportGenerated
    case followUp
    case answerGenerated
    case deleteReport
    case reportDeleted
    case recognizeAssets
    case assetsRecognized
    case fetchExchangeRates
    case exchangeRatesFetched
    case error
    case pairingChallenge
    case pairingConfirmation
    case credentialProvision
    case credentialReceipt
    case reconnectChallenge
    case reconnectResponse
    case authenticationComplete
    case tcpReconnectHello
    case tcpReconnectInvitation
    case tcpReconnectChallenge
    case tcpReconnectResponse
    case tcpAuthenticationComplete
    case secureMessage
}

public struct BridgeEnvelopeV1: Codable, Equatable, Sendable {
    public let version: String
    public let id: UUID
    public let type: BridgeEnvelopeTypeV1
    public let payload: Data

    public init(
        id: UUID = UUID(),
        type: BridgeEnvelopeTypeV1,
        payload: Data = Data(),
        version: String = BridgeWire.protocolVersion
    ) {
        self.version = version
        self.id = id
        self.type = type
        self.payload = payload
    }

    public init<Payload: Encodable>(
        id: UUID = UUID(),
        type: BridgeEnvelopeTypeV1,
        payload: Payload,
        encoder: JSONEncoder? = nil
    ) throws {
        self.init(
            id: id,
            type: type,
            payload: try (encoder ?? BridgeWire.makeEncoder()).encode(payload)
        )
    }

    public func decodePayload<Payload: Decodable>(
        _ type: Payload.Type,
        decoder: JSONDecoder? = nil
    ) throws -> Payload {
        guard version == BridgeWire.protocolVersion else {
            throw FIREBridgeError.invalidMessage("不支持协议版本 \(version)。")
        }
        do {
            return try (decoder ?? BridgeWire.makeDecoder()).decode(
                Payload.self,
                from: payload
            )
        } catch {
            throw FIREBridgeError.invalidMessage(error.localizedDescription)
        }
    }
}

public struct GenerateReportRequestV1: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let packet: AnalysisPacketV1

    public init(reportID: UUID, packet: AnalysisPacketV1) {
        self.reportID = reportID
        self.packet = packet
    }
}

public struct FollowUpRequestV1: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let reportID: UUID
    public let question: String

    public init(operationID: UUID, reportID: UUID, question: String) {
        self.operationID = operationID
        self.reportID = reportID
        self.question = question
    }
}

public struct DeleteReportRequestV1: Codable, Equatable, Sendable {
    public let reportID: UUID

    public init(reportID: UUID) {
        self.reportID = reportID
    }
}

public struct ReportGeneratedResponseV1: Codable, Equatable, Sendable {
    public let reportID: UUID
    public let threadID: String
    public let report: AnalysisReportV1

    public init(reportID: UUID, threadID: String, report: AnalysisReportV1) {
        self.reportID = reportID
        self.threadID = threadID
        self.report = report
    }
}

public struct AnswerGeneratedResponseV1: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let reportID: UUID
    public let answer: AnalysisAnswerV1

    public init(
        operationID: UUID,
        reportID: UUID,
        answer: AnalysisAnswerV1
    ) {
        self.operationID = operationID
        self.reportID = reportID
        self.answer = answer
    }
}

public struct ReportDeletedResponseV1: Codable, Equatable, Sendable {
    public let reportID: UUID

    public init(reportID: UUID) {
        self.reportID = reportID
    }
}

public struct BridgeErrorResponseV1: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct FetchExchangeRatesRequestV1: Codable, Equatable, Sendable {
    public let snapshotDate: Date
    public let currencies: [String]

    public init(snapshotDate: Date, currencies: [String]) {
        self.snapshotDate = snapshotDate
        self.currencies = currencies
            .map { $0.uppercased() }
            .sorted()
    }
}

public struct ExchangeRatesFetchedResponseV1: Codable, Equatable, Sendable {
    public let observationDate: Date
    public let fetchedAt: Date
    public let ratesToCNY: [String: Double]
    public let source: String

    public init(
        observationDate: Date,
        fetchedAt: Date = .now,
        ratesToCNY: [String: Double],
        source: String = "ECB（Mac 桥接）"
    ) {
        self.observationDate = observationDate
        self.fetchedAt = fetchedAt
        self.ratesToCNY = ratesToCNY
        self.source = source
    }
}

public struct PingPayloadV1: Codable, Equatable, Sendable {
    public let sentAt: Date

    public init(sentAt: Date = Date()) {
        self.sentAt = sentAt
    }
}

public struct PongPayloadV1: Codable, Equatable, Sendable {
    public let sentAt: Date
    public let codexReady: Bool
    public let capabilities: [String]?

    public init(
        sentAt: Date = Date(),
        codexReady: Bool,
        capabilities: [String]? = nil
    ) {
        self.sentAt = sentAt
        self.codexReady = codexReady
        self.capabilities = capabilities
    }
}
