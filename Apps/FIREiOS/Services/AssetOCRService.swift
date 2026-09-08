import Foundation
import FIREBridgeKit
import FIRECore
import ImageIO
import PhotosUI
import SwiftUI
import Vision

enum AssetOCRError: LocalizedError {
    case unreadableImage
    case noText
    case invalidInstrumentResolution
    case invalidBatchMerge

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "无法读取这张截图。"
        case .noText: "截图中没有识别到可用的产品和市值。"
        case .invalidInstrumentResolution: "无代码产品关联的已有产品已失效，请重新选择归属。"
        case .invalidBatchMerge: "同批产品合并关系已失效，请重新选择同名主项。"
        }
    }
}

struct AssetOCRRecognitionResult: Sendable {
    let imageCount: Int
    let lines: [AssetOCRLineV1]
    let fallbackCandidates: [OCRPositionCandidate]
}

final class AssetOCRCancellationCoordinator<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, Error>?
    private var completion: Result<Success, Error>?
    private var cancellationAction: (@Sendable () -> Void)?
    private var cancellationRequested = false

    @discardableResult
    func installContinuation(
        _ newContinuation: CheckedContinuation<Success, Error>
    ) -> Bool {
        let storedCompletion: Result<Success, Error>?
        lock.lock()
        if let completion {
            storedCompletion = completion
        } else {
            continuation = newContinuation
            storedCompletion = nil
        }
        lock.unlock()

        if let storedCompletion {
            newContinuation.resume(with: storedCompletion)
            return false
        }
        return true
    }

    @discardableResult
    func installCancellationAction(
        _ action: @escaping @Sendable () -> Void
    ) -> Bool {
        let shouldCancel: Bool
        let shouldStart: Bool
        lock.lock()
        if completion == nil {
            cancellationAction = action
            shouldCancel = false
            shouldStart = true
        } else {
            shouldCancel = cancellationRequested
            shouldStart = false
        }
        lock.unlock()

        if shouldCancel {
            action()
        }
        return shouldStart
    }

    @discardableResult
    func finish(_ result: Result<Success, Error>) -> Bool {
        let installedContinuation: CheckedContinuation<Success, Error>?
        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return false
        }
        completion = result
        installedContinuation = continuation
        continuation = nil
        cancellationAction = nil
        lock.unlock()

        installedContinuation?.resume(with: result)
        return true
    }

    func cancel() {
        let installedContinuation: CheckedContinuation<Success, Error>?
        let action: (@Sendable () -> Void)?
        let result: Result<Success, Error> = .failure(CancellationError())

        lock.lock()
        guard completion == nil else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        completion = result
        installedContinuation = continuation
        continuation = nil
        action = cancellationAction
        cancellationAction = nil
        lock.unlock()

        action?()
        installedContinuation?.resume(with: result)
    }
}

private final class AssetOCRVisionRequest: @unchecked Sendable {
    let request: VNRecognizeTextRequest

    init(_ request: VNRecognizeTextRequest) {
        self.request = request
    }

    func cancel() {
        request.cancel()
    }
}

actor AssetOCRService {
    private let codePattern = try? NSRegularExpression(
        pattern: #"(?<!\d)(?:\d{6}|\d{4,5}(?:\.HK)?|[A-Z]{1,5}\d{0,5})(?!\d)"#
    )
    private let amountPattern = try? NSRegularExpression(
        pattern: #"(?:¥|￥|RMB|CNY|HK\$|HKD|\$|USD)?\s*(-?\d[\d,]*(?:\.\d{1,2})?)\s*(万|萬|k|K)?"#
    )

    func recognize(items: [PhotosPickerItem]) async throws -> AssetOCRRecognitionResult {
        var allLines: [AssetOCRLineV1] = []
        var allCandidates: [OCRPositionCandidate] = []

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            guard let data = try await item.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AssetOCRError.unreadableImage
            }

            let lines = try await recognizeText(in: image)
            try Task.checkCancellation()
            let redactedLines = lines.map {
                RecognizedLine(
                    text: Self.redactPersonalInformation(in: $0.text),
                    confidence: $0.confidence,
                    boundingBox: $0.boundingBox
                )
            }
            allLines.append(
                contentsOf: redactedLines.map {
                    AssetOCRLineV1(
                        imageIndex: index,
                        text: $0.text,
                        confidence: $0.confidence,
                        boundingBox: $0.boundingBox
                    )
                }
            )
            allCandidates.append(
                contentsOf: parse(redactedLines, imageIndex: index)
            )
        }

        guard !allLines.isEmpty else {
            throw AssetOCRError.noText
        }
        return AssetOCRRecognitionResult(
            imageCount: items.count,
            lines: allLines,
            fallbackCandidates: allCandidates
        )
    }

    private func recognizeText(in image: CGImage) async throws -> [RecognizedLine] {
        let coordinator = AssetOCRCancellationCoordinator<[RecognizedLine]>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard coordinator.installContinuation(continuation) else {
                    return
                }
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        coordinator.finish(.failure(error))
                        return
                    }
                    let observations = request.results
                        as? [VNRecognizedTextObservation] ?? []
                    let lines = observations.compactMap {
                        observation -> RecognizedLine? in
                        guard let candidate = observation.topCandidates(1).first else {
                            return nil
                        }
                        let box = observation.boundingBox
                        return RecognizedLine(
                            text: candidate.string,
                            confidence: Double(candidate.confidence),
                            boundingBox: AssetOCRBoundingBoxV1(
                                x: box.minX,
                                y: box.minY,
                                width: box.width,
                                height: box.height
                            )
                        )
                    }
                    coordinator.finish(.success(lines))
                }
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                request.usesLanguageCorrection = true
                request.minimumTextHeight = 0.012

                let cancellableRequest = AssetOCRVisionRequest(request)
                guard coordinator.installCancellationAction({
                    cancellableRequest.cancel()
                }) else {
                    return
                }
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                do {
                    try handler.perform([request])
                } catch {
                    coordinator.finish(.failure(error))
                }
            }
        } onCancel: {
            coordinator.cancel()
        }
    }

    func parse(
        _ lines: [RecognizedLine],
        imageIndex: Int
    ) -> [OCRPositionCandidate] {
        guard !lines.isEmpty else { return [] }
        let medianHeight = median(
            lines.map { $0.boundingBox.height }
        )
        let amountLines = marketValueLines(
            in: lines,
            medianHeight: medianHeight
        )
        var candidates: [OCRPositionCandidate] = []

        for (index, amountLine) in amountLines.enumerated() {
            guard let amount = parseLikelyMarketValue(amountLine.text) else {
                continue
            }
            let upperBoundary = index == 0
                ? 1.0
                : (amountLines[index - 1].midY + amountLine.midY) / 2
            let lowerBoundary = index == amountLines.count - 1
                ? 0.0
                : (amountLine.midY + amountLines[index + 1].midY) / 2
            let possibleNameLines = lines.filter { line in
                line.midY < upperBoundary
                    && line.midY > lowerBoundary
                    && line.boundingBox.maxX
                        < amountLine.boundingBox.midX - medianHeight
                    && (looksLikeProductName(
                        line.text,
                        excluding: amountLine.text
                    ) || extractCode(line.text) != nil)
            }
            guard let primaryNameLine = possibleNameLines.min(by: {
                abs($0.midY - amountLine.midY)
                    < abs($1.midY - amountLine.midY)
            }) else {
                continue
            }
            let continuationDistance = max(
                medianHeight * 1.65,
                primaryNameLine.boundingBox.height * 1.5
            )
            let recordLines = possibleNameLines.filter { line in
                abs(line.midY - primaryNameLine.midY) <= continuationDistance
                    && abs(
                        line.boundingBox.x
                            - primaryNameLine.boundingBox.x
                    ) <= max(medianHeight * 2, 0.04)
            }
            .sorted { $0.midY > $1.midY }
            let context = recordLines.map(\.text) + [amountLine.text]
            let code = recordLines.compactMap {
                extractCode($0.text)
            }.first
            let nameFragments = recordLines.compactMap { line -> String? in
                let cleaned = cleanName(line.text)
                guard !cleaned.isEmpty, extractCode(cleaned) == nil else {
                    return nil
                }
                return cleaned
            }
            let name = joinedName(nameFragments)
                ?? code
                ?? "待确认产品"
            let evidence = context.joined(separator: " · ")
            let baseConfidence = (
                [amountLine.confidence] + recordLines.map(\.confidence)
            ).min() ?? amountLine.confidence
            let confidence = min(
                max(baseConfidence - (code == nil ? 0.16 : 0), 0.25),
                0.99
            )

            candidates.append(
                OCRPositionCandidate(
                    sourceImageIndex: imageIndex,
                    productName: name,
                    productCode: code,
                    kind: inferKind(from: evidence),
                    currency: inferCurrency(from: evidence),
                    originalMarketValue: amount,
                    confidence: confidence,
                    // 四个平台的脱敏截图样本尚未完成验收前，代码、类型、币种和金额
                    // 都必须由用户逐项确认，不能把 OCR 置信度当成业务正确性。
                    requiresMergeConfirmation: true,
                    rawEvidence: evidence
                )
            )
        }

        return removeLikelyBalanceNoise(from: candidates)
    }

    private func marketValueLines(
        in lines: [RecognizedLine],
        medianHeight: Double
    ) -> [RecognizedLine] {
        let numericLines = lines.filter {
            parseLikelyMarketValue($0.text) != nil
        }
        guard !numericLines.isEmpty else { return [] }

        let amountHeader = lines
            .filter {
                let text = $0.text.lowercased()
                return (text.contains("金额") || text.contains("市值"))
                    && !text.contains("总资产")
            }
            .max { $0.midY < $1.midY }
        if let amountHeader {
            let nameHeader = lines.first {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "名称"
            }
            let profitHeader = lines.first {
                let text = $0.text.lowercased()
                return text.contains("收益")
                    && !text.contains("金额")
                    && $0.boundingBox.midX > amountHeader.boundingBox.midX
            }
            let lowerX = nameHeader.map {
                ($0.boundingBox.midX + amountHeader.boundingBox.midX) / 2
            } ?? amountHeader.boundingBox.midX - max(0.12, medianHeight * 5)
            let upperX = profitHeader.map {
                ($0.boundingBox.midX + amountHeader.boundingBox.midX) / 2
            } ?? amountHeader.boundingBox.midX + max(0.12, medianHeight * 5)
            return numericLines
                .filter {
                    (lowerX...upperX).contains($0.boundingBox.midX)
                }
                .sorted { $0.midY > $1.midY }
        }

        let sorted = numericLines.sorted {
            $0.boundingBox.midX < $1.boundingBox.midX
        }
        let splitThreshold = max(0.08, medianHeight * 4)
        var clusters: [[RecognizedLine]] = []
        for line in sorted {
            guard var last = clusters.popLast() else {
                clusters.append([line])
                continue
            }
            let previousCenter = last.map {
                $0.boundingBox.midX
            }.reduce(0, +) / Double(last.count)
            if line.boundingBox.midX - previousCenter > splitThreshold {
                clusters.append(last)
                clusters.append([line])
            } else {
                last.append(line)
                clusters.append(last)
            }
        }
        return clusters.max {
            if $0.count != $1.count { return $0.count < $1.count }
            let lhsCenter = $0.map {
                $0.boundingBox.midX
            }.reduce(0, +) / Double($0.count)
            let rhsCenter = $1.map {
                $0.boundingBox.midX
            }.reduce(0, +) / Double($1.count)
            return lhsCenter > rhsCenter
        }?
        .sorted { $0.midY > $1.midY } ?? []
    }

    private func parseLikelyMarketValue(_ text: String) -> Double? {
        let lowered = text.lowercased()
        let positiveHints = ["市值", "总资产", "资产", "持有金额", "当前金额", "参考市值", "金额"]
        let negativeHints = ["收益率", "收益", "成本", "净值", "单价", "昨日", "日收益", "%"]

        if negativeHints.contains(where: lowered.contains) {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = amountPattern?.matches(in: text, range: range) ?? []
        let values = matches.compactMap { match -> Double? in
            guard match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            let raw = text[numberRange].replacingOccurrences(of: ",", with: "")
            guard var value = Double(raw), value > 0 else { return nil }
            if match.numberOfRanges > 2,
               let multiplierRange = Range(match.range(at: 2), in: text) {
                let multiplier = text[multiplierRange]
                if multiplier == "万" || multiplier == "萬" {
                    value *= 10_000
                } else if multiplier.lowercased() == "k" {
                    value *= 1_000
                }
            }
            return value
        }

        guard let best = values.max(), best >= 1 else { return nil }
        if positiveHints.contains(where: lowered.contains) {
            return best
        }
        // 平台通常将产品名与市值拆成相邻两行，纯金额行也保留，后续由用户确认。
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[¥￥$]?\s*\d[\d,.]*\s*(万|萬|k|K)?$"#, options: .regularExpression) != nil
            ? best
            : nil
    }

    private func extractCode(_ text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = codePattern?.matches(in: text, range: range) ?? []
        for match in matches {
            guard let swiftRange = Range(match.range, in: text),
                  let code = normalizedProductCode(
                      String(text[swiftRange]),
                      in: text
                  ) else {
                continue
            }
            return code
        }
        return nil
    }

    private func normalizedProductCode(
        _ rawCode: String,
        in text: String
    ) -> String? {
        let code = rawCode.uppercased()
        if [
            "USD",
            "HKD",
            "CNY",
            "RMB",
            "QDII",
            "LOF",
            "ETF",
            "FOF",
            "REIT",
        ].contains(code) {
            return nil
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.allSatisfy(\.isLetter),
           code.count == 1,
           trimmedText.uppercased() != code {
            return nil
        }

        let hongKongDigits = code.hasSuffix(".HK")
            ? String(code.dropLast(3))
            : code
        if hongKongDigits.allSatisfy(\.isNumber) {
            switch hongKongDigits.count {
            case 6:
                return hongKongDigits
            case 4:
                guard !isLikelyYear(hongKongDigits),
                      !isAmountLikeCode(rawCode, in: trimmedText) else {
                    return nil
                }
                return "0\(hongKongDigits)"
            case 5:
                guard !isAmountLikeCode(rawCode, in: trimmedText) else {
                    return nil
                }
                return hongKongDigits
            default:
                return nil
            }
        }
        return code
    }

    private func isLikelyYear(_ value: String) -> Bool {
        guard let year = Int(value) else { return false }
        return (1900...2100).contains(year)
    }

    private func isAmountLikeCode(
        _ rawCode: String,
        in text: String
    ) -> Bool {
        if text.contains(",")
            || text.range(
                of: #"-?\d{4,5}\.\d{1,2}"#,
                options: .regularExpression
            ) != nil {
            return true
        }
        let remainingText = text.replacingOccurrences(
            of: rawCode,
            with: "",
            options: .caseInsensitive
        )
        .trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters)
        )
        let amountLabels = [
            "¥", "￥", "$", "RMB", "CNY", "HKD", "USD",
            "元", "金额", "市值", "收益", "余额", "资产",
            "持有金额", "当前金额", "参考市值",
        ]
        return amountLabels.contains(remainingText.uppercased())
    }

    private func looksLikeProductName(_ text: String, excluding amountLine: String) -> Bool {
        guard text != amountLine else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40 else { return false }
        guard parseLikelyMarketValue(trimmed) == nil else { return false }
        let excluded = [
            "持仓",
            "资产",
            "基金",
            "股票",
            "全部",
            "偏股",
            "偏债",
            "指数",
            "黄金",
            "全球",
            "名称",
            "昨日收益",
            "累计收益",
            "总市值",
            "基金市场",
            "机会",
            "自选",
            "持有",
        ]
        let excludedPhrases = [
            "我的持有",
            "持有收益",
            "收益率排序",
            "金额/昨日收益",
            "金额／昨日收益",
            "投资锦囊",
            "市场解读",
            "点击查看",
            "去看看",
            "波动来袭",
        ]
        return !excluded.contains(trimmed)
            && !excludedPhrases.contains(where: trimmed.contains)
    }

    private func cleanName(_ text: String) -> String {
        guard let rawCode = rawNumericCode(in: text) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.replacingOccurrences(
            of: #"[（(]?\s*"# + NSRegularExpression.escapedPattern(
                for: rawCode
            ) + #"\s*[）)]?"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rawNumericCode(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = codePattern?.matches(in: text, range: range) ?? []
        for match in matches {
            guard let swiftRange = Range(match.range, in: text) else {
                continue
            }
            let rawCode = String(text[swiftRange])
            guard normalizedProductCode(rawCode, in: text) != nil else {
                continue
            }
            let digits = rawCode.uppercased().hasSuffix(".HK")
                ? String(rawCode.dropLast(3))
                : rawCode
            if digits.allSatisfy(\.isNumber) {
                return rawCode
            }
        }
        return nil
    }

    private func inferKind(from text: String) -> AssetKind {
        let lowered = text.lowercased()
        if ["现金", "余额", "货币"].contains(where: lowered.contains) { return .cash }
        if ["股票", "证券", ".hk", "nasdaq", "nyse"].contains(where: lowered.contains) {
            return .stock
        }
        return .fund
    }

    private func inferCurrency(from text: String) -> String {
        let uppercased = text.uppercased()
        if uppercased.contains("HKD") || uppercased.contains("HK$") { return "HKD" }
        if uppercased.contains("USD") || uppercased.contains("US$") { return "USD" }
        return "CNY"
    }

    private func joinedName(_ fragments: [String]) -> String? {
        guard !fragments.isEmpty else { return nil }
        let separator = fragments.joined().unicodeScalars.contains {
            (0x3400...0x9FFF).contains(Int($0.value))
        } ? "" : " "
        let name = fragments.joined(separator: separator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.02 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func removeLikelyBalanceNoise(
        from candidates: [OCRPositionCandidate]
    ) -> [OCRPositionCandidate] {
        let byImage = Dictionary(grouping: candidates, by: \.sourceImageIndex)
        return byImage.values.flatMap { imageCandidates in
            let coded = imageCandidates.filter { $0.productCode != nil }
            return coded.isEmpty ? imageCandidates : imageCandidates.filter {
                $0.productCode != nil || $0.productName != "待确认产品"
            }
        }
    }

    nonisolated static func redactPersonalInformation(in text: String) -> String {
        var redacted = PIIRedactor.redact(text: text)
        let patterns = [
            #"(?:账号|账户|卡号|尾号)\s*[:：]?\s*[\d*•·\s-]{4,}"#
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "[已移除]",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return redacted
    }
}

struct RecognizedLine: Sendable {
    let text: String
    let confidence: Double
    let boundingBox: AssetOCRBoundingBoxV1

    var midY: Double {
        boundingBox.y + boundingBox.height / 2
    }
}

private extension AssetOCRBoundingBoxV1 {
    var midX: Double { x + width / 2 }
    var maxX: Double { x + width }
}
