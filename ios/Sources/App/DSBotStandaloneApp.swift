import SwiftUI
import UIKit

@main
public struct DSBotStandaloneApp: App {
    @StateObject private var host = LocalAgentHost.shared
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainTabView(host: host)
                .tint(DSTheme.brand)
                .overlay {
                    if scenePhase != .active {
                        Color(uiColor: .systemBackground).ignoresSafeArea().accessibilityHidden(true)
                    }
                }
                .task {
                    MemoryGovernor.shared.startMonitoring()
                    if host.state == .idle {
                        await host.boot()
                    }
                }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        performGuardedBackgroundSuspend()
                    case .active:
                        Task { await host.resumeFromBackground() }
                    default:
                        break
                    }
                }
        }
    }

    @MainActor
    private func performGuardedBackgroundSuspend() {
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "DSBotSQLiteWALFlush") {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
                bgTaskID = .invalid
            }
        }
        Task { @MainActor in
            defer {
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
            await host.suspendForBackground()
        }
    }
}
