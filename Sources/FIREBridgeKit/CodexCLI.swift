#if os(macOS)
import Foundation

public struct CodexCLIResolver: @unchecked Sendable {
    public let fileManager: FileManager
    public let environment: [String: String]

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    public func candidateURLs() -> [URL] {
        var candidates: [URL] = []

        if let explicitPath = environment["FIRE_CODEX_CLI_PATH"], !explicitPath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        candidates.append(contentsOf: pathEntries.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("codex")
        })

        candidates.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"))
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex")
        )

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public func resolve() throws -> URL {
        let candidates = candidateURLs()
        guard let executable = candidates.first(where: {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
                && fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw FIREBridgeError.codexNotFound(searchedPaths: candidates.map(\.path))
        }
        return executable
    }
}

public enum CodexEnvironment {
    private static let allowedKeys: Set<String> = [
        "ALL_PROXY",
        "CODEX_HOME",
        "CURL_CA_BUNDLE",
        "FIRE_CODEX_CLI_PATH",
        "HOME",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "LANG",
        "LOGNAME",
        "NO_PROXY",
        "NODE_EXTRA_CA_CERTS",
        "PATH",
        "REQUESTS_CA_BUNDLE",
        "SHELL",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TERM",
        "TMPDIR",
        "USER",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
    ]

    public static func sanitized(_ source: [String: String]) -> [String: String] {
        source.filter {
            allowedKeys.contains($0.key)
                || $0.key.hasPrefix("LC_")
        }
    }

    public static let appServerArguments: [String] = [
        "app-server",
        "--stdio",
        "--strict-config",
        "-c", #"web_search="disabled""#,
        "-c", "features.shell_tool=false",
        "-c", "agents.enabled=false",
        "-c", "mcp_servers={}",
        "--disable", "apps",
        "--disable", "artifact",
        "--disable", "auth_elicitation",
        "--disable", "browser_use",
        "--disable", "browser_use_external",
        "--disable", "browser_use_full_cdp_access",
        "--disable", "chronicle",
        "--disable", "code_mode",
        "--disable", "code_mode_host",
        "--disable", "computer_use",
        "--disable", "default_mode_request_user_input",
        "--disable", "enable_mcp_apps",
        "--disable", "external_agent_memory_import",
        "--disable", "in_app_browser",
        "--disable", "image_generation",
        "--disable", "plugins",
        "--disable", "remote_plugin",
        "--disable", "request_permissions_tool",
        "--disable", "shell_snapshot",
        "--disable", "skill_mcp_dependency_install",
        "--disable", "skill_search",
        "--disable", "standalone_web_search",
        "--disable", "tool_call_mcp_elicitation",
        "--disable", "tool_suggest",
        "--disable", "unified_exec",
        "--disable", "workspace_dependencies",
        "--disable", "memories",
        "--disable", "goals",
        "--disable", "hooks",
        "--disable", "multi_agent",
        "--disable", "multi_agent_v2",
    ]
}

public enum CodexAuthentication {
    public static func validateLoginStatus(
        standardOutput: String,
        standardError: String,
        terminationStatus: Int32
    ) throws {
        let combined = [standardOutput, standardError]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard terminationStatus == 0 else {
            throw FIREBridgeError.codexAuthenticationRequired(
                details: combined.isEmpty ? "登录状态检查失败。" : combined
            )
        }

        let normalized = combined.lowercased()
        guard normalized.contains("logged in using chatgpt"),
              !normalized.contains("api key") else {
            throw FIREBridgeError.codexAuthenticationRequired(
                details: combined.isEmpty ? "当前没有登录。" : "当前状态：\(combined)"
            )
        }
    }
}

public struct CodexHealthStatus: Codable, Equatable, Sendable {
    public let executablePath: String
    public let authenticatedWithChatGPT: Bool

    public init(executablePath: String, authenticatedWithChatGPT: Bool) {
        self.executablePath = executablePath
        self.authenticatedWithChatGPT = authenticatedWithChatGPT
    }
}

public struct CodexHealthChecker: Sendable {
    public let resolver: CodexCLIResolver
    public let environment: [String: String]
    public let timeout: TimeInterval

    public init(
        resolver: CodexCLIResolver = CodexCLIResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10
    ) {
        self.resolver = resolver
        self.environment = environment
        self.timeout = timeout
    }

    public func check() throws -> CodexHealthStatus {
        let executableURL = try resolver.resolve()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["login", "status"]
        process.environment = CodexEnvironment.sanitized(environment)
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            throw FIREBridgeError.processLaunchFailed(error.localizedDescription)
        }
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            throw FIREBridgeError.codexAuthenticationRequired(
                details: "登录状态检查在 \(Int(timeout)) 秒内没有完成。"
            )
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        try CodexAuthentication.validateLoginStatus(
            standardOutput: output,
            standardError: errorOutput,
            terminationStatus: process.terminationStatus
        )

        return CodexHealthStatus(
            executablePath: executableURL.path,
            authenticatedWithChatGPT: true
        )
    }
}
#endif
