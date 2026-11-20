import SwiftUI

@main
public struct DSBotStandaloneApp: App {
    @StateObject private var host = LocalAgentHost()
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
                    if host.state == .idle {
                        await host.boot()
                    }
                }
                .onChange(of: scenePhase) { newPhase in
                    Task {
                        switch newPhase {
                        case .background:
                            await host.suspendForBackground()
                        case .active:
                            await host.resumeFromBackground()
                        default:
                            break
                        }
                    }
                }
        }
    }
}
