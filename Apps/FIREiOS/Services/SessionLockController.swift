import Foundation
import LocalAuthentication
import Observation
import SwiftUI

@MainActor
@Observable
final class SessionLockController {
    private enum Keys {
        static let lastBackgroundDate = "fire.lastBackgroundDate"
    }

    private let lockInterval: TimeInterval = 60
    private let defaults: UserDefaults

    var isLocked = true
    var isAuthenticating = false
    var authenticationError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            defaults.set(Date(), forKey: Keys.lastBackgroundDate)
        case .active:
            let lastBackgroundDate = defaults.object(forKey: Keys.lastBackgroundDate) as? Date
            if let lastBackgroundDate,
               Date().timeIntervalSince(lastBackgroundDate) >= lockInterval {
                isLocked = true
            }
            if isLocked {
                Task { await unlock() }
            }
        default:
            break
        }
    }

    func unlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authenticationError = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "稍后"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            authenticationError = error?.localizedDescription ?? "此设备尚未启用 Face ID。"
            return
        }

        do {
            let allowed = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "解锁你的财务自由数据"
            )
            if allowed {
                isLocked = false
                defaults.removeObject(forKey: Keys.lastBackgroundDate)
            }
        } catch {
            authenticationError = error.localizedDescription
        }
    }

    func lockImmediately() {
        isLocked = true
        defaults.set(Date(timeIntervalSince1970: 0), forKey: Keys.lastBackgroundDate)
    }
}
