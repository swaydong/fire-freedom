import SwiftData
import SwiftUI

@main
struct FIREFreedomApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: FIREAppState
    @State private var lockController: SessionLockController
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema(FIREModelSchema.models)
        let configuration = ModelConfiguration(
            "FIRELocal",
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            fatalError("无法创建本地数据仓库：\(error.localizedDescription)")
        }

        let state = FIREAppState()
        BackgroundOperationController.shared.prepareForLaunch()
        state.configure(context: container.mainContext)
        state.installBackgroundOperationRecoveryHandler()
        _appState = State(initialValue: state)
        _lockController = State(initialValue: SessionLockController())
        modelContainer = container
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(appState)
                    .environment(lockController)
                    .allowsHitTesting(!lockController.isLocked)
                    .blur(radius: lockController.isLocked ? 14 : 0)

                if lockController.isLocked {
                    LockScreenView()
                        .environment(lockController)
                        .transition(.opacity)
                }
            }
            .task {
                if lockController.isLocked {
                    await lockController.unlock()
                }
                if scenePhase == .active {
                    appState.bridge.startBrowsing()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                lockController.handle(newPhase)
                if newPhase == .active {
                    appState.bridge.startBrowsing()
                } else if newPhase == .background {
                    appState.bridge.didEnterBackground()
                } else {
                    appState.bridge.stopBrowsing()
                }
            }
        }
        .modelContainer(modelContainer)
    }
}
