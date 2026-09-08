import BackgroundTasks
import Foundation
import UIKit

enum ReportBackgroundActivityPolicy {
    static func shouldBegin(
        isNewOperation: Bool,
        startsBackgroundActivity: Bool,
        isSystemRecovery: Bool
    ) -> Bool {
        isSystemRecovery || (isNewOperation && startsBackgroundActivity)
    }
}

/// Keeps user-initiated work alive while F.I.R.E moves to the background.
///
/// The caller still owns and executes the actual `Task`. Start support from the
/// foreground, report real progress, and always call `finish`.
@MainActor
final class BackgroundOperationController {
    enum ProtectionMode: Equatable, Sendable {
        case continuedProcessing
        case shortBackgroundTime
    }

    struct OperationDescriptor: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var title: String
        var subtitle: String
        var completedUnitCount: Int64
        var totalUnitCount: Int64
        let startedAt: Date
    }

    enum ControllerError: LocalizedError {
        case mustBeginInForeground
        case alreadyRunning
        case registrationFailed
        case shortBackgroundTimeUnavailable

        var errorDescription: String? {
            switch self {
            case .mustBeginInForeground:
                "后台任务必须由你在 App 前台主动发起。"
            case .alreadyRunning:
                "同一个后台任务已经在运行。"
            case .registrationFailed:
                "系统没有允许注册持续处理任务。"
            case .shortBackgroundTimeUnavailable:
                "系统当前无法提供额外的后台处理时间。"
            }
        }
    }

    typealias ExpirationHandler = @MainActor @Sendable () -> Void
    typealias RecoveryHandler = @MainActor @Sendable (OperationDescriptor) -> Void

    static let shared = BackgroundOperationController()

    private final class ActiveOperation {
        var descriptor: OperationDescriptor
        var expirationHandler: ExpirationHandler?
        var legacyTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
        var systemTask: BGTask?
        var isRecovering: Bool
        var didNotifyRecovery = false
        var completesSuccessfullyOnExpiration: Bool

        init(
            descriptor: OperationDescriptor,
            expirationHandler: ExpirationHandler?,
            isRecovering: Bool = false,
            completesSuccessfullyOnExpiration: Bool = false
        ) {
            self.descriptor = descriptor
            self.expirationHandler = expirationHandler
            self.isRecovering = isRecovering
            self.completesSuccessfullyOnExpiration =
                completesSuccessfullyOnExpiration
        }
    }

    private enum Constants {
        static let defaultsKey = "fire.backgroundOperations.v1"
        static let semanticIdentifier = "continued-processing"
    }

    private let defaults: UserDefaults
    private var persistedOperations: [UUID: OperationDescriptor]
    private var activeOperations: [UUID: ActiveOperation] = [:]
    private var registeredIdentifiers: Set<String> = []
    private var recoveryHandler: RecoveryHandler?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Constants.defaultsKey),
           let values = try? JSONDecoder().decode(
               [OperationDescriptor].self,
               from: data
           ) {
            persistedOperations = Dictionary(
                uniqueKeysWithValues: values.map { ($0.id, $0) }
            )
        } else {
            persistedOperations = [:]
        }
    }

    /// Re-registers dynamic iOS 26 identifiers after a process relaunch.
    ///
    /// Call this during app launch, before reconnecting persisted work.
    func prepareForLaunch() {
        guard #available(iOS 26.0, *) else { return }
        for operationID in persistedOperations.keys {
            _ = registerContinuedProcessingHandler(operationID: operationID)
        }
    }

    /// Installs the callback used when iOS relaunches a persisted continued task.
    ///
    /// The callback should recreate the caller-owned work with the same
    /// operation ID, then call `begin` again to attach its expiration handler.
    func setRecoveryHandler(_ handler: RecoveryHandler?) {
        recoveryHandler = handler
        guard let handler else { return }

        for active in activeOperations.values
        where active.isRecovering && !active.didNotifyRecovery {
            active.didNotifyRecovery = true
            handler(active.descriptor)
        }
    }

    var recoverableOperations: [OperationDescriptor] {
        persistedOperations.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Gives a relaunched operation a cancellation hook while its owner
    /// reconnects the durable work. Calling `begin` later replaces this hook.
    func attachRecoveryExpirationHandler(
        operationID: UUID,
        completesSuccessfully: Bool,
        handler: ExpirationHandler?
    ) {
        guard let active = activeOperations[operationID],
              active.isRecovering else {
            return
        }
        active.completesSuccessfullyOnExpiration = completesSuccessfully
        active.expirationHandler = handler
    }

    func isRecovering(operationID: UUID) -> Bool {
        activeOperations[operationID]?.isRecovering == true
    }

    /// Starts background support for work initiated by an explicit user action.
    ///
    /// On iOS 26 this submits a visible continued-processing task. On iOS
    /// 17–25 it uses only the limited completion time granted by UIKit.
    /// Keep `title` and `subtitle` generic because the system may show them
    /// outside the unlocked app; never include balances or product names.
    @discardableResult
    func begin(
        operationID: UUID,
        title: String,
        subtitle: String,
        completesSuccessfullyOnExpiration: Bool = false,
        onExpiration: ExpirationHandler? = nil
    ) throws -> ProtectionMode {
        let descriptor = makeDescriptor(
            operationID: operationID,
            title: title,
            subtitle: subtitle
        )
        if let active = activeOperations[operationID] {
            guard active.isRecovering else {
                throw ControllerError.alreadyRunning
            }
            active.descriptor = descriptor
            active.expirationHandler = onExpiration
            active.isRecovering = false
            active.didNotifyRecovery = true
            active.completesSuccessfullyOnExpiration =
                completesSuccessfullyOnExpiration
            store(descriptor)
            applyProgress(from: descriptor, to: active.systemTask)
            return .continuedProcessing
        }
        guard UIApplication.shared.applicationState == .active else {
            throw ControllerError.mustBeginInForeground
        }

        let active = ActiveOperation(
            descriptor: descriptor,
            expirationHandler: onExpiration,
            completesSuccessfullyOnExpiration:
                completesSuccessfullyOnExpiration
        )
        activeOperations[operationID] = active
        store(descriptor)

        do {
            if #available(iOS 26.0, *) {
                do {
                    try beginContinuedProcessing(
                        active,
                        operationID: operationID
                    )
                    return .continuedProcessing
                } catch {
                    cancelScheduledRequest(operationID: operationID)
                    try beginShortBackgroundTime(
                        active,
                        operationID: operationID
                    )
                    return .shortBackgroundTime
                }
            } else {
                try beginShortBackgroundTime(active, operationID: operationID)
                return .shortBackgroundTime
            }
        } catch {
            activeOperations.removeValue(forKey: operationID)
            removeStoredOperation(operationID)
            throw error
        }
    }

    /// Reports measurable, monotonic progress to the system UI on iOS 26.
    func updateProgress(
        operationID: UUID,
        completedUnitCount: Int64,
        totalUnitCount: Int64 = 100,
        subtitle: String? = nil
    ) {
        guard let active = activeOperations[operationID] else { return }
        let total = max(
            totalUnitCount,
            active.descriptor.totalUnitCount,
            1
        )
        let completed = min(
            max(completedUnitCount, active.descriptor.completedUnitCount),
            total
        )
        active.descriptor.totalUnitCount = total
        active.descriptor.completedUnitCount = completed
        if let subtitle {
            active.descriptor.subtitle = normalized(
                subtitle,
                fallback: active.descriptor.subtitle
            )
        }
        store(active.descriptor)
        applyProgress(from: active.descriptor, to: active.systemTask)

        if #available(iOS 26.0, *),
           let continuedTask = active.systemTask as? BGContinuedProcessingTask {
            continuedTask.updateTitle(
                active.descriptor.title,
                subtitle: active.descriptor.subtitle
            )
        }
    }

    /// Ends the system assertion. Call exactly once after the caller-owned work
    /// completes or fails.
    func finish(operationID: UUID, success: Bool) {
        guard let active = activeOperations.removeValue(
            forKey: operationID
        ) else {
            cancelScheduledRequest(operationID: operationID)
            removeStoredOperation(operationID)
            return
        }
        removeStoredOperation(operationID)

        if active.legacyTaskIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(
                active.legacyTaskIdentifier
            )
            active.legacyTaskIdentifier = .invalid
        }
        if let systemTask = active.systemTask {
            systemTask.expirationHandler = nil
            systemTask.setTaskCompleted(success: success)
        } else {
            cancelScheduledRequest(operationID: operationID)
        }
    }

    private func makeDescriptor(
        operationID: UUID,
        title: String,
        subtitle: String
    ) -> OperationDescriptor {
        let existing = persistedOperations[operationID]
        return OperationDescriptor(
            id: operationID,
            title: normalized(title, fallback: "F.I.R.E 正在处理"),
            subtitle: normalized(subtitle, fallback: "请稍候"),
            completedUnitCount: existing?.completedUnitCount ?? 0,
            totalUnitCount: max(existing?.totalUnitCount ?? 100, 1),
            startedAt: existing?.startedAt ?? Date()
        )
    }

    private func beginShortBackgroundTime(
        _ active: ActiveOperation,
        operationID: UUID
    ) throws {
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "F.I.R.E \(operationID.uuidString)"
        ) { [weak self] in
            Task { @MainActor in
                self?.expire(operationID: operationID)
            }
        }
        guard identifier != .invalid else {
            throw ControllerError.shortBackgroundTimeUnavailable
        }
        active.legacyTaskIdentifier = identifier
    }

    @available(iOS 26.0, *)
    private func beginContinuedProcessing(
        _ active: ActiveOperation,
        operationID: UUID
    ) throws {
        guard registerContinuedProcessingHandler(
            operationID: operationID
        ) else {
            throw ControllerError.registrationFailed
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: taskIdentifier(for: operationID),
            title: active.descriptor.title,
            subtitle: active.descriptor.subtitle
        )
        // This work starts from a user action and is useful only immediately.
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
    }

    @available(iOS 26.0, *)
    private func registerContinuedProcessingHandler(
        operationID: UUID
    ) -> Bool {
        let identifier = taskIdentifier(for: operationID)
        guard !registeredIdentifiers.contains(identifier) else { return true }

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            self?.handleContinuedProcessingTask(
                task,
                operationID: operationID
            )
        }
        if registered {
            registeredIdentifiers.insert(identifier)
        }
        return registered
    }

    @available(iOS 26.0, *)
    private func handleContinuedProcessingTask(
        _ task: BGTask,
        operationID: UUID
    ) {
        guard task is BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }

        let active: ActiveOperation
        if let existing = activeOperations[operationID] {
            active = existing
        } else if let descriptor = persistedOperations[operationID] {
            active = ActiveOperation(
                descriptor: descriptor,
                expirationHandler: nil,
                isRecovering: true
            )
            activeOperations[operationID] = active
        } else {
            task.setTaskCompleted(success: false)
            return
        }

        active.systemTask = task
        applyProgress(from: active.descriptor, to: task)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expire(operationID: operationID)
            }
        }

        if active.isRecovering,
           !active.didNotifyRecovery,
           let recoveryHandler {
            active.didNotifyRecovery = true
            recoveryHandler(active.descriptor)
        }
    }

    private func expire(operationID: UUID) {
        guard let active = activeOperations[operationID] else { return }
        let success = active.completesSuccessfullyOnExpiration
        if success {
            active.descriptor.completedUnitCount =
                active.descriptor.totalUnitCount
            active.descriptor.subtitle = "任务已保存，回到 F.I.R.E 后继续"
            applyProgress(from: active.descriptor, to: active.systemTask)
            if #available(iOS 26.0, *),
               let task = active.systemTask as? BGContinuedProcessingTask {
                task.updateTitle(
                    active.descriptor.title,
                    subtitle: active.descriptor.subtitle
                )
            }
        }
        active.expirationHandler?()
        finish(operationID: operationID, success: success)
    }

    private func applyProgress(
        from descriptor: OperationDescriptor,
        to task: BGTask?
    ) {
        guard #available(iOS 26.0, *),
              let continuedTask = task as? BGContinuedProcessingTask else {
            return
        }
        continuedTask.progress.totalUnitCount = descriptor.totalUnitCount
        continuedTask.progress.completedUnitCount = descriptor.completedUnitCount
    }

    private func taskIdentifier(for operationID: UUID) -> String {
        let bundleID = Bundle.main.bundleIdentifier
            ?? "com.local.firefreedom.ios"
        return "\(bundleID).\(Constants.semanticIdentifier)."
            + operationID.uuidString.lowercased()
    }

    private func cancelScheduledRequest(operationID: UUID) {
        guard #available(iOS 26.0, *) else { return }
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: taskIdentifier(for: operationID)
        )
    }

    private func store(_ descriptor: OperationDescriptor) {
        persistedOperations[descriptor.id] = descriptor
        persist()
    }

    private func removeStoredOperation(_ operationID: UUID) {
        persistedOperations.removeValue(forKey: operationID)
        persist()
    }

    private func persist() {
        let values = persistedOperations.values.sorted {
            $0.startedAt < $1.startedAt
        }
        if values.isEmpty {
            defaults.removeObject(forKey: Constants.defaultsKey)
        } else if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Constants.defaultsKey)
        }
    }

    private func normalized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(120))
    }
}
