import Foundation

public struct TCPFrameDecoder: Sendable {
    private let maximumFrameBytes: Int
    private var buffer = Data()
    private var pendingFrameLength: Int?

    public init(maximumFrameBytes: Int = BridgeWire.maximumMessageBytes) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while true {
            if pendingFrameLength == nil {
                guard buffer.count >= MemoryLayout<UInt32>.size else {
                    break
                }
                let start = buffer.startIndex
                let length =
                    (UInt32(buffer[start]) << 24)
                    | (UInt32(buffer[buffer.index(start, offsetBy: 1)]) << 16)
                    | (UInt32(buffer[buffer.index(start, offsetBy: 2)]) << 8)
                    | UInt32(buffer[buffer.index(start, offsetBy: 3)])
                buffer.removeFirst(MemoryLayout<UInt32>.size)

                guard length > 0,
                      maximumFrameBytes > 0,
                      length <= UInt32(clamping: maximumFrameBytes) else {
                    throw FIREBridgeError.invalidMessage(
                        "TCP 消息长度必须为 1–\(maximumFrameBytes) 字节。"
                    )
                }
                pendingFrameLength = Int(length)
            }

            guard let frameLength = pendingFrameLength,
                  buffer.count >= frameLength else {
                break
            }
            frames.append(Data(buffer.prefix(frameLength)))
            buffer.removeFirst(frameLength)
            pendingFrameLength = nil
        }

        return frames
    }

    public func finish() throws {
        guard buffer.isEmpty, pendingFrameLength == nil else {
            throw FIREBridgeError.invalidMessage("TCP 消息在完整帧前结束。")
        }
    }

    public static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty,
              payload.count <= BridgeWire.maximumMessageBytes else {
            throw FIREBridgeError.invalidMessage(
                "TCP 消息长度必须为 1–\(BridgeWire.maximumMessageBytes) 字节。"
            )
        }

        var length = UInt32(payload.count).bigEndian
        var framed = Data()
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }
}
