import Darwin
import FIREBridgeKit
import Foundation
import ImageIO
import Vision

@main
struct FIREBridgeCLI {
    static func main() async {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        let arguments = Set(rawArguments)
        let wantsJSON = arguments.contains("--json")
        let wantsAppServerSmoke = arguments.contains("--app-server-smoke")
        let wantsAssetRecognitionSmoke = arguments.contains(
            "--asset-recognition-smoke"
        )
        let assetImagePath = optionValue(
            named: "--asset-image-smoke",
            in: rawArguments
        )

        do {
            if let assetImagePath {
                let lines = try await recognizeText(
                    in: URL(fileURLWithPath: assetImagePath)
                )
                if arguments.contains("--ocr-only") {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    FileHandle.standardOutput.write(try encoder.encode(lines))
                    FileHandle.standardOutput.write(Data("\n".utf8))
                    return
                }
                try await runAssetRecognition(
                    request: RecognizeAssetsRequestV1(
                        imageCount: 1,
                        lines: lines
                    ),
                    wantsJSON: wantsJSON
                )
                return
            }

            if wantsAssetRecognitionSmoke {
                try await runAssetRecognition(
                    request: RecognizeAssetsRequestV1(
                        imageCount: 1,
                        lines: [
                            AssetOCRLineV1(
                                imageIndex: 0,
                                text: "示例指数基金 000001 当前市值 10000.00 元",
                                confidence: 0.99,
                                boundingBox: AssetOCRBoundingBoxV1(
                                    x: 0.1,
                                    y: 0.5,
                                    width: 0.8,
                                    height: 0.1
                                )
                            ),
                        ]
                    ),
                    wantsJSON: wantsJSON
                )
                return
            }

            if wantsAppServerSmoke {
                let runtime = try await CodexBridgeRuntime.makeDefault()
                let status = await runtime.health
                await runtime.shutdown()
                if wantsJSON {
                    let payload: [String: Any] = [
                        "status": "ok",
                        "appServerInitialized": true,
                        "authenticatedWithChatGPT": status.authenticatedWithChatGPT,
                        "executablePath": status.executablePath,
                        "platformAPIFallback": false,
                    ]
                    let data = try JSONSerialization.data(
                        withJSONObject: payload,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    print("Codex App Server：初始化成功")
                    print("认证：ChatGPT")
                    print("Platform API 回退：关闭")
                }
                return
            }

            let status = try CodexHealthChecker().check()
            if wantsJSON {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(status)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print("Codex：可用")
                print("认证：ChatGPT")
                print("路径：\(status.executablePath)")
                print("Platform API 回退：关闭")
            }
        } catch {
            if wantsJSON {
                let payload = [
                    "status": "error",
                    "message": error.localizedDescription,
                ]
                let data = try? JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                )
                if let data {
                    FileHandle.standardError.write(data)
                    FileHandle.standardError.write(Data("\n".utf8))
                }
            } else {
                FileHandle.standardError.write(
                    Data("检查失败：\(error.localizedDescription)\n".utf8)
                )
            }
            exit(EXIT_FAILURE)
        }
    }

    private static func runAssetRecognition(
        request: RecognizeAssetsRequestV1,
        wantsJSON: Bool
    ) async throws {
        let runtime = try await CodexBridgeRuntime.makeDefault()
        do {
            let response = try await runtime.recognizeAssets(request: request)
            await runtime.shutdown()
            if wantsJSON {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode(response))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print("资产识别：成功（\(response.positions.count) 个产品）")
            }
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private static func optionValue(
        named option: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func recognizeText(
        in imageURL: URL
    ) async throws -> [AssetOCRLineV1] {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: "FIREBridgeCLI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法读取测试截图。"]
            )
        }

        let lines: [AssetOCRLineV1] = try await withCheckedThrowingContinuation {
            continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results
                    as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap {
                    observation -> AssetOCRLineV1? in
                    guard let candidate = observation.topCandidates(1).first else {
                        return nil
                    }
                    let box = observation.boundingBox
                    return AssetOCRLineV1(
                        imageIndex: 0,
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
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.012

            do {
                try VNImageRequestHandler(
                    cgImage: image,
                    orientation: .up
                ).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }

        guard !lines.isEmpty else {
            throw NSError(
                domain: "FIREBridgeCLI",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "截图没有识别到文字。"]
            )
        }
        return lines
    }
}
