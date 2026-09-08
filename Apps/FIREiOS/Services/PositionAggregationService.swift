import Foundation

struct PositionSavePlan {
    let positions: [AggregatedPosition]
    let uncodedResolutions: [String: UncodedPositionResolution]
}

enum AssetRecognitionCandidateAccumulator {
    static func merging(
        existing: [OCRPositionCandidate],
        additions: [OCRPositionCandidate],
        imageIndexOffset: Int?
    ) -> [OCRPositionCandidate] {
        guard let imageIndexOffset else {
            return additions
        }

        let shiftedAdditions = additions.map { candidate in
            var shifted = candidate
            shifted.sourceImageIndex += imageIndexOffset
            return shifted
        }
        return existing + shiftedAdditions
    }
}

struct PositionAggregationService {
    func aggregate(_ candidates: [OCRPositionCandidate]) -> [AggregatedPosition] {
        let groups = Dictionary(grouping: candidates) { candidate -> String in
            if let code = candidate.productCode?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased(),
               !code.isEmpty {
                return "\(candidate.kind.rawValue)::\(candidate.currency.uppercased())::CODE::\(code)"
            }
            // 首版不按名称自动合并。即使名称相同，也必须保持为可逐条核对的候选。
            return "\(candidate.kind.rawValue)::\(candidate.currency.uppercased())::CANDIDATE::\(candidate.id.uuidString)"
        }

        return groups.map { key, values in
            let first = values[0]
            let hasCode = first.productCode?.isEmpty == false
            return AggregatedPosition(
                id: key,
                code: first.productCode,
                name: first.productName,
                kind: first.kind,
                currency: first.currency,
                originalMarketValue: values.reduce(0) { $0 + $1.originalMarketValue },
                sourceCount: values.count,
                confidence: values.map(\.confidence).min() ?? 0,
                requiresConfirmation: !hasCode
                    || values.count > 1
                    || values.contains { $0.requiresMergeConfirmation },
                verification: aggregateVerification(
                    values.map(\.verification)
                ),
                candidateIDs: values.map(\.id)
            )
        }
        .sorted {
            if $0.requiresConfirmation != $1.requiresConfirmation {
                return !$0.requiresConfirmation
            }
            return $0.originalMarketValue > $1.originalMarketValue
        }
    }

    func sameBatchMergeTargets(
        for position: AggregatedPosition,
        in positions: [AggregatedPosition]
    ) -> [AggregatedPosition] {
        guard position.code == nil else { return [] }
        return positions.filter {
            $0.id != position.id
                && $0.code == nil
                && $0.kind == position.kind
                && $0.currency.uppercased() == position.currency.uppercased()
                && normalizedName($0.name) == normalizedName(position.name)
        }
    }

    func makeSavePlan(
        positions: [AggregatedPosition],
        uncodedResolutions: [String: UncodedPositionResolution]
    ) throws -> PositionSavePlan {
        let positionsByID = Dictionary(
            uniqueKeysWithValues: positions.map { ($0.id, $0) }
        )
        var canonicalIDByPositionID: [String: String] = [:]

        for position in positions where position.code == nil {
            switch uncodedResolutions[position.id] {
            case let .batchCanonical(targetID)?:
                guard let target = positionsByID[targetID],
                      target.code == nil,
                      target.id != position.id,
                      target.kind == position.kind,
                      target.currency.uppercased() == position.currency.uppercased(),
                      normalizedName(target.name) == normalizedName(position.name),
                      let targetResolution = uncodedResolutions[target.id],
                      !targetResolution.isBatchCanonical else {
                    throw AssetOCRError.invalidBatchMerge
                }
                canonicalIDByPositionID[position.id] = target.id
            case .existingInstrument?, .createNewInstrument?:
                canonicalIDByPositionID[position.id] = position.id
            case nil:
                throw AssetOCRError.invalidInstrumentResolution
            }
        }

        let grouped = Dictionary(grouping: positions) { position in
            canonicalIDByPositionID[position.id] ?? position.id
        }
        var plannedPositions: [AggregatedPosition] = []
        var plannedResolutions: [String: UncodedPositionResolution] = [:]

        for (canonicalID, group) in grouped {
            guard let canonical = positionsByID[canonicalID] else {
                throw AssetOCRError.invalidBatchMerge
            }
            if canonical.code != nil || group.count == 1 {
                plannedPositions.append(canonical)
            } else {
                plannedPositions.append(
                    AggregatedPosition(
                        id: canonical.id,
                        code: nil,
                        name: canonical.name,
                        kind: canonical.kind,
                        currency: canonical.currency,
                        originalMarketValue: group.reduce(0) {
                            $0 + $1.originalMarketValue
                        },
                        sourceCount: group.reduce(0) { $0 + $1.sourceCount },
                        confidence: group.map(\.confidence).min() ?? 0,
                        requiresConfirmation: true,
                        verification: aggregateVerification(
                            group.map(\.verification)
                        ),
                        candidateIDs: group.flatMap(\.candidateIDs)
                    )
                )
            }
            if canonical.code == nil,
               let resolution = uncodedResolutions[canonical.id] {
                plannedResolutions[canonical.id] = resolution
            }
        }

        plannedPositions.sort {
            if $0.requiresConfirmation != $1.requiresConfirmation {
                return !$0.requiresConfirmation
            }
            return $0.originalMarketValue > $1.originalMarketValue
        }
        return PositionSavePlan(
            positions: plannedPositions,
            uncodedResolutions: plannedResolutions
        )
    }

    func isSameBatchMergeValid(
        sourceID: String,
        targetID: String,
        positions: [AggregatedPosition]
    ) -> Bool {
        guard let source = positions.first(where: { $0.id == sourceID }) else {
            return false
        }
        return sameBatchMergeTargets(for: source, in: positions)
            .contains { $0.id == targetID }
    }

    private func normalizedName(_ value: String) -> String {
        value
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func aggregateVerification(
        _ states: [AssetProductVerification]
    ) -> AssetProductVerification {
        let uniqueStates = Set(states)
        if uniqueStates == [.verified] { return .verified }
        if uniqueStates == [.manual] { return .manual }
        if uniqueStates.contains(.ambiguous) { return .ambiguous }
        if uniqueStates.contains(.notFound) { return .notFound }
        if uniqueStates.contains(.unavailable) { return .unavailable }
        if uniqueStates == [.notApplicable] { return .notApplicable }
        return .localOnly
    }
}

private extension UncodedPositionResolution {
    var isBatchCanonical: Bool {
        if case .batchCanonical = self {
            return true
        }
        return false
    }
}
