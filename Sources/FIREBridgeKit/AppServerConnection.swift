#if os(macOS)
import Foundation

public protocol AppServerConnection: Sendable {
    func start() async throws
    func send(_ line: Data) async throws
    func messages() async -> AsyncThrowingStream<Data, Error>
    func stop() async
}

public actor ProcessAppServerConnection: AppServerConnection {
    public struct Configuration: Sendable {
        public let executableURL: URL
        public let workingDirectoryURL: URL
        public let environment: [String: String]

        public init(
            executableURL: URL,
            workingDirectoryURL: URL,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            self.executableURL = executableURL
            self.workingDirectoryURL = workingDirectoryURL
            self.environment = environment
        }
    }

    private let configuration: Configuration
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var lineBuffer = Data()
    private var standardErrorBuffer = Data()
    private var wasStopped = false

    public init(configuration: Configuration) {
        self.configuration = configuration
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.messageStream = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    public func start() throws {
        guard process == nil else { return }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = configuration.executableURL
        process.arguments = CodexEnvironment.appServerArguments
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.environment = CodexEnvironment.sanitized(configuration.environment)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeStandardOutput(data) }
        }
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeStandardError(data) }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self?.didTerminate(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            throw FIREBridgeError.processLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
    }

    public func send(_ line: Data) throws {
        guard let process, process.isRunning, let inputHandle else {
            throw FIREBridgeError.appServerDisconnected("子进程没有运行。")
        }
        var framed = line
        framed.append(0x0A)
        do {
            try inputHandle.write(contentsOf: framed)
        } catch {
            throw FIREBridgeError.appServerDisconnected(error.localizedDescription)
        }
    }

    public func messages() -> AsyncThrowingStream<Data, Error> {
        messageStream
    }

    public func stop() {
        wasStopped = true
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        if let process, process.isRunning {
            process.terminate()
        }
        continuation.finish()
        self.process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
    }

    private func consumeStandardOutput(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            var line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                continuation.yield(line)
            }
        }
        if lineBuffer.count > 16 * 1_024 * 1_024 {
            continuation.finish(
                throwing: FIREBridgeError.appServerProtocolError(
                    "App Server 单条消息超过 16 MB 上限。"
                )
            )
            process?.terminate()
        }
    }

    private func consumeStandardError(_ data: Data) {
        standardErrorBuffer.append(data)
        let maximumBytes = 32 * 1_024
        if standardErrorBuffer.count > maximumBytes {
            standardErrorBuffer.removeFirst(standardErrorBuffer.count - maximumBytes)
        }
    }

    private func didTerminate(status: Int32) {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        guard !wasStopped else {
            continuation.finish()
            return
        }
        let details = String(data: standardErrorBuffer, encoding: .utf8) ?? ""
        continuation.finish(
            throwing: FIREBridgeError.processExited(
                status: status,
                details: details.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }
}
#endif
