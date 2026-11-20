import SwiftUI

@main
public struct DSBotStandaloneApp: App {
    @StateObject private var host = BareWorkletHost()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainTabView(host: host)
                .tint(DSTheme.brand)
                .task {
                    if host.state == .idle {
                        await host.boot { _ in LocalAgentTransport(dshVersion: host.activeVersion) }
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
