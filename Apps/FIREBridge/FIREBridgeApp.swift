import AppKit
import Darwin
import FIREBridgeKit
import ServiceManagement
import SwiftUI

@main
struct FIREBridgeApp: App {
    @StateObject private var model: BridgeStatusModel

    @MainActor
    init() {
        BridgeSingleInstanceGuard.acquireOrExit()
        _model = StateObject(wrappedValue: BridgeStatusModel())
    }

    var body: some Scene {
        MenuBarExtra("F.I.R.E Bridge", systemImage: model.menuBarIcon) {
            BridgeMenuView(model: model)
                .frame(width: 320)
                .task {
                    await model.startIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

private enum BridgeSingleInstanceGuard {
    @MainActor private static var lockFileDescriptor: Int32 = -1

    @MainActor
    static func acquireOrExit() {
        guard lockFileDescriptor == -1 else { return }
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "com.local.firefreedom.bridge"
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(bundleIdentifier).single-instance.lock",
                isDirectory: false
            )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            exitIfVisibleDuplicate(bundleIdentifier: bundleIdentifier)
            Darwin.exit(EXIT_FAILURE)
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            Darwin.close(descriptor)
            exitIfVisibleDuplicate(bundleIdentifier: bundleIdentifier)
            Darwin.exit(EXIT_SUCCESS)
        }
        lockFileDescriptor = descriptor
    }

    @MainActor
    private static func exitIfVisibleDuplicate(bundleIdentifier: String) {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let hasVisibleDuplicate = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains {
                !$0.isTerminated
                    && $0.processIdentifier != currentProcessID
            }
        if hasVisibleDuplicate {
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

@MainActor
final class BridgeStatusModel: ObservableObject {
    enum LoginItemState: Equatable {
        case checking
        case enabled
        case requiresApproval
        case failed(String)

        var title: String {
            switch self {
            case .checking:
                "正在设置登录时自动启动…"
            case .enabled:
                "登录时自动启动已开启"
            case .requiresApproval:
                "需要在系统设置中允许自动启动"
            case .failed:
                "自动启动设置失败"
            }
        }

        var systemImage: String {
            switch self {
            case .checking:
                "hourglass"
            case .enabled:
                "checkmark.circle.fill"
            case .requiresApproval:
                "exclamationmark.circle.fill"
            case .failed:
                "xmark.circle.fill"
            }
        }
    }

    enum RuntimeState: Equatable {
        case starting
        case ready
        case failed(String)
        case stopped

        var title: String {
            switch self {
            case .starting:
                "正在连接 Codex…"
            case .ready:
                "Codex 已就绪"
            case .failed:
                "Codex 不可用"
            case .stopped:
                "桥接已停止"
            }
        }
    }

    @Published private(set) var runtimeState: RuntimeState = .stopped
    @Published private(set) var loginItemState: LoginItemState = .checking
    @Published private(set) var peerState = SecurePeerHostState(
        isAdvertising: false,
        isPairingOpen: false,
        pairingSAS: nil,
        connectedPeerNames: [],
        lastError: nil
    )
    @Published private(set) var tcpPeerState = SecureTCPPeerHostState(
        isListening: false,
        connectedPeerNames: [],
        lastError: nil
    )
    @Published private(set) var codexPath = ""

    private var runtime: CodexBridgeRuntime?
    private var peerHost: SecurePeerHost?
    private var tcpPeerHost: SecureTCPPeerHost?
    private var isStarting = false

    init() {
        registerLaunchAtLogin()
        Task { @MainActor [weak self] in
            await self?.startIfNeeded()
        }
    }

    var menuBarIcon: String {
        switch runtimeState {
        case .ready:
            connectedPeerNames.isEmpty ? "flame" : "flame.fill"
        case .starting:
            "hourglass"
        case .failed, .stopped:
            "flame"
        }
    }

    var connectedPeerNames: [String] {
        Array(
            Set(
                peerState.connectedPeerNames
                    + tcpPeerState.connectedPeerNames
            )
        ).sorted()
    }

    var transportError: String? {
        tcpPeerState.lastError ?? peerState.lastError
    }

    func startIfNeeded() async {
        guard runtime == nil, !isStarting else { return }
        isStarting = true
        runtimeState = .starting
        defer { isStarting = false }
        do {
            let runtime = try await Task.detached {
                try await CodexBridgeRuntime.makeDefault()
            }.value
            let credentialStore = PairingCredentialStore()
            let peerHost = try SecurePeerHost(
                credentialStore: credentialStore
            )
            let tcpPeerHost = try SecureTCPPeerHost(
                credentialStore: credentialStore
            )
            peerHost.setEnvelopeHandler { envelope in
                await runtime.handle(envelope)
            }
            tcpPeerHost.setEnvelopeHandler { envelope in
                await runtime.handle(envelope)
            }
            peerHost.setStateHandler { [weak self] state in
                Task { @MainActor in
                    self?.peerState = state
                }
            }
            tcpPeerHost.setStateHandler { [weak self] state in
                Task { @MainActor in
                    self?.tcpPeerState = state
                }
            }
            try peerHost.startAdvertising()
            try tcpPeerHost.start()
            self.runtime = runtime
            self.peerHost = peerHost
            self.tcpPeerHost = tcpPeerHost
            codexPath = await runtime.health.executablePath
            runtimeState = .ready
        } catch {
            runtimeState = .failed(error.localizedDescription)
        }
    }

    func beginPairing() {
        do {
            _ = try peerHost?.startAdvertising(allowNewPairing: true)
        } catch {
            runtimeState = .failed(error.localizedDescription)
        }
    }

    func closePairing() {
        peerHost?.closeNewPairingWindow()
    }

    func retry() {
        Task {
            await stop()
            await startIfNeeded()
        }
    }

    func stop() async {
        tcpPeerHost?.stop()
        tcpPeerHost = nil
        peerHost?.stopAdvertising()
        peerHost?.disconnectAll()
        peerHost = nil
        if let runtime {
            await runtime.shutdown()
        }
        self.runtime = nil
        runtimeState = .stopped
    }

    func registerLaunchAtLogin() {
        loginItemState = .checking
        let service = SMAppService.mainApp

        do {
            switch service.status {
            case .notRegistered, .notFound:
                try service.register()
            case .enabled, .requiresApproval:
                break
            @unknown default:
                break
            }
            updateLoginItemState(for: service.status)
        } catch {
            loginItemState = .failed(error.localizedDescription)
        }
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func updateLoginItemState(for status: SMAppService.Status) {
        switch status {
        case .enabled:
            loginItemState = .enabled
        case .requiresApproval:
            loginItemState = .requiresApproval
        case .notRegistered:
            loginItemState = .failed("系统没有完成登录项登记，请重试。")
        case .notFound:
            loginItemState = .failed("请先把 F.I.R.E Bridge 放进“应用程序”文件夹。")
        @unknown default:
            loginItemState = .failed("系统返回了暂不支持的登录项状态。")
        }
    }
}

private struct BridgeMenuView: View {
    @ObservedObject var model: BridgeStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            connectionSection
            loginItemSection
            if let code = model.peerState.pairingSAS {
                pairingSAS(code)
            } else if model.peerState.isPairingOpen {
                pairingWaiting
            }
            if case let .failed(message) = model.runtimeState {
                errorSection(message)
            } else if let message = model.transportError {
                errorSection(message)
            }
            Divider()
            footer
        }
        .padding(18)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: model.menuBarIcon)
                .font(.title2)
                .foregroundStyle(model.runtimeState == .ready ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("F.I.R.E 自由进度")
                    .font(.headline)
                Text(model.runtimeState.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(model.runtimeState == .ready ? .green : .gray)
                .frame(width: 8, height: 8)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                model.connectedPeerNames.isEmpty
                    ? "没有已连接的 iPhone"
                    : model.connectedPeerNames.joined(separator: "、"),
                systemImage: "iphone"
            )
            .font(.subheadline)

            if !model.peerState.isPairingOpen
                && model.peerState.pairingSAS == nil {
                Button("配对新 iPhone") {
                    model.beginPairing()
                }
                .disabled(model.runtimeState != .ready)
            }
        }
    }

    private var loginItemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.loginItemState.title,
                systemImage: model.loginItemState.systemImage
            )
            .font(.caption)
            .foregroundStyle(loginItemColor)

            switch model.loginItemState {
            case .requiresApproval:
                Button("打开登录项设置") {
                    model.openLoginItemSettings()
                }
            case .failed:
                Button("重试自动启动设置") {
                    model.registerLaunchAtLogin()
                }
            case .checking, .enabled:
                EmptyView()
            }
        }
    }

    private var loginItemColor: Color {
        switch model.loginItemState {
        case .enabled:
            .green
        case .requiresApproval:
            .orange
        case .failed:
            .red
        case .checking:
            .secondary
        }
    }

    private var pairingWaiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("现在请在 iPhone 上选择这台 Mac")
                .font(.subheadline.weight(.semibold))
            Text("连接后，两边会显示同一个 6 位短码。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("取消配对") {
                model.closePairing()
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pairingSAS(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("确认 iPhone 也显示这个短码")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Text("如果一致，请在 iPhone 上点“两边一致，继续”。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("短码不一致，取消") {
                model.closePairing()
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Button("重试") {
                model.retry()
            }
        }
    }

    private var footer: some View {
        HStack {
            if !model.codexPath.isEmpty {
                Text("ChatGPT 登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
