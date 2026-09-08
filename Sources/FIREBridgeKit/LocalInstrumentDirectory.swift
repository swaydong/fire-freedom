import Foundation

public enum LocalInstrumentDirectorySourceKind: String, Codable, Hashable, Sendable {
    case financeDatabase
    case officialOverlay
}

public struct LocalInstrumentDirectorySource: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: LocalInstrumentDirectorySourceKind
    public let displayName: String
    public let sourceURL: String
    public let version: String?
    public let license: String?
    public let asOf: String
    public let notes: String

    public init(
        id: String,
        kind: LocalInstrumentDirectorySourceKind,
        displayName: String,
        sourceURL: String,
        version: String? = nil,
        license: String? = nil,
        asOf: String,
        notes: String
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.version = version
        self.license = license
        self.asOf = asOf
        self.notes = notes
    }
}

public struct LocalInstrumentCandidate: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let code: String
    public let alternateCodes: [String]
    public let name: String
    public let searchAliases: [String]
    public let kind: RecognizedAssetKindV1
    public let currency: RecognizedAssetCurrencyV1
    public let exchange: String
    public let sourceIDs: [String]

    public init(
        id: String,
        code: String,
        alternateCodes: [String] = [],
        name: String,
        searchAliases: [String] = [],
        kind: RecognizedAssetKindV1,
        currency: RecognizedAssetCurrencyV1,
        exchange: String,
        sourceIDs: [String]
    ) {
        self.id = id
        self.code = code
        self.alternateCodes = alternateCodes
        self.name = name
        self.searchAliases = searchAliases
        self.kind = kind
        self.currency = currency
        self.exchange = exchange
        self.sourceIDs = sourceIDs
    }
}

public enum LocalInstrumentDirectoryError: Error, Equatable, Sendable {
    case missingBundledSeed
    case unsupportedSchemaVersion(Int)
    case duplicateSourceID(String)
    case duplicateInstrumentID(String)
    case invalidInstrument(String)
    case unknownSource(sourceID: String, instrumentID: String)
}

public struct LocalInstrumentDirectory: Sendable {
    private struct Document: Decodable {
        let schemaVersion: Int
        let sources: [LocalInstrumentDirectorySource]
        let instruments: [LocalInstrumentCandidate]
    }

    public let sources: [LocalInstrumentDirectorySource]
    public let instruments: [LocalInstrumentCandidate]

    private let sourcesByID: [String: LocalInstrumentDirectorySource]

    public init(data: Data, decoder: JSONDecoder = JSONDecoder()) throws {
        let document = try decoder.decode(Document.self, from: data)
        guard document.schemaVersion == 1 else {
            throw LocalInstrumentDirectoryError.unsupportedSchemaVersion(
                document.schemaVersion
            )
        }

        var sourceIndex: [String: LocalInstrumentDirectorySource] = [:]
        for source in document.sources {
            guard sourceIndex.updateValue(source, forKey: source.id) == nil else {
                throw LocalInstrumentDirectoryError.duplicateSourceID(source.id)
            }
        }

        var instrumentIDs = Set<String>()
        for instrument in document.instruments {
            guard instrumentIDs.insert(instrument.id).inserted else {
                throw LocalInstrumentDirectoryError.duplicateInstrumentID(
                    instrument.id
                )
            }
            guard !Self.normalizedCode(instrument.code).isEmpty,
                  !Self.normalizedName(instrument.name).isEmpty,
                  !instrument.sourceIDs.isEmpty else {
                throw LocalInstrumentDirectoryError.invalidInstrument(
                    instrument.id
                )
            }
            for sourceID in instrument.sourceIDs where sourceIndex[sourceID] == nil {
                throw LocalInstrumentDirectoryError.unknownSource(
                    sourceID: sourceID,
                    instrumentID: instrument.id
                )
            }
        }

        sources = document.sources
        instruments = document.instruments
        sourcesByID = sourceIndex
    }

    public static func bundled() throws -> LocalInstrumentDirectory {
        guard let url = Bundle.module.url(
            forResource: "local-instrument-directory-seed",
            withExtension: "json"
        ) else {
            throw LocalInstrumentDirectoryError.missingBundledSeed
        }
        return try LocalInstrumentDirectory(data: Data(contentsOf: url))
    }

    public func candidates(
        code: String? = nil,
        name: String? = nil,
        currency: RecognizedAssetCurrencyV1? = nil
    ) -> [LocalInstrumentCandidate] {
        let normalizedCode = code.map(Self.normalizedCode).flatMap {
            $0.isEmpty ? nil : $0
        }
        let normalizedName = name.map(Self.normalizedName).flatMap {
            $0.isEmpty ? nil : $0
        }

        return instruments
            .filter { candidate in
                if let normalizedCode,
                   !candidateCodes(candidate).contains(normalizedCode) {
                    return false
                }
                if let normalizedName,
                   !matches(name: normalizedName, candidate: candidate) {
                    return false
                }
                if let currency, candidate.currency != currency {
                    return false
                }
                return true
            }
            .sorted { $0.id < $1.id }
    }

    public func sources(
        for candidate: LocalInstrumentCandidate
    ) -> [LocalInstrumentDirectorySource] {
        candidate.sourceIDs.compactMap { sourcesByID[$0] }
    }

    private func candidateCodes(
        _ candidate: LocalInstrumentCandidate
    ) -> Set<String> {
        Set(([candidate.code] + candidate.alternateCodes).map(Self.normalizedCode))
    }

    private func matches(
        name normalizedQuery: String,
        candidate: LocalInstrumentCandidate
    ) -> Bool {
        let candidateNames = ([candidate.name] + candidate.searchAliases)
            .map(Self.normalizedName)
            .filter { !$0.isEmpty }

        if candidateNames.contains(normalizedQuery) {
            return true
        }
        guard normalizedQuery.count >= 4 else {
            return false
        }
        return candidateNames.contains { $0.contains(normalizedQuery) }
    }

    private static func normalizedCode(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .uppercased()
            .filter { !$0.isWhitespace }
    }

    private static func normalizedName(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
