import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

private enum DSHWebViewportMode: String, CaseIterable, Identifiable {
    case responsive = "移动自适应"
    case desktop1280 = "桌面工作台 (1280px)"
    var id: String { rawValue }
    var viewportContent: String {
        switch self {
        case .responsive:
            return "width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes"
        case .desktop1280:
            return "width=1280, initial-scale=0.32, minimum-scale=0.25, maximum-scale=5.0, user-scalable=yes"
        }
    }
}

/// Hosts the embedded official DSH Web UI (`@deepseek-ai/dsh-web-app` + `@deepseek-ai/dsh-web-frontend`)
/// and any installed community `dsh-client-ui-*` plugins over the private loopback port.
public struct DSHWebUIView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var launchURL: URL?
    @State private var allowedPort: Int = 0
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()
    @AppStorage("dsbot.web.viewportMode") private var viewportModeRaw: String = DSHWebViewportMode.responsive.rawValue

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var viewportMode: DSHWebViewportMode {
        DSHWebViewportMode(rawValue: viewportModeRaw) ?? .responsive
    }

    public var body: some View {
        Group {
            if let url = launchURL, allowedPort > 0 {
                LoopbackWebView(
                    url: url,
                    allowedPort: allowedPort,
                    reloadToken: reloadToken,
                    viewportMode: viewportMode
                ) {
                    launchURL = nil
                    errorMessage = "本机 Web 连接已断开，请重新连接。"
                }
                .ignoresSafeArea(edges: .bottom)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重试加载") {
                        Task { await loadWebUIInfo() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                ProgressView("正在连接本机 DSH Web 工作台…")
            }
        }
        .navigationTitle("DSH Web 工作台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Picker("布局视口", selection: $viewportModeRaw) {
                        ForEach(DSHWebViewportMode.allCases) { mode in
                            Label(
                                mode.rawValue,
                                systemImage: mode == .desktop1280 ? "desktopcomputer" : "iphone"
                            )
                            .tag(mode.rawValue)
                        }
                    }
                    Divider()
                    Button {
                        reloadToken = UUID()
                        Task { await loadWebUIInfo() }
                    } label: {
                        Label("刷新页面", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task {
                            launchURL = nil
                            _ = await host.restartRuntime()
                            reloadToken = UUID()
                            await loadWebUIInfo()
                        }
                    } label: {
                        Label("重启 DSH 引擎并刷新", systemImage: "power")
                    }
                } label: {
                    Image(systemName: viewportMode == .desktop1280 ? "desktopcomputer" : "ellipsis.circle")
                }
            }
        }
        .task(id: host.runtimeGeneration) {
            await loadWebUIInfo()
        }
    }

    private func loadWebUIInfo() async {
        let generation = host.runtimeGeneration
        errorMessage = nil
        guard let rpc = host.rpc() else {
            launchURL = nil
            errorMessage = "DSH 运行时尚未就绪，请稍候重试。"
            return
        }
        do {
            let info = try await rpc.request("web.ui.info", timeoutSeconds: 15)
            guard !Task.isCancelled, generation == host.runtimeGeneration else { return }
            guard info["ready"] as? Bool == true,
                  let raw = info["url"] as? String,
                  let parsed = URL(string: raw),
                  let port = info["port"] as? Int, port > 0,
                  parsed.scheme == "http", parsed.port == port,
                  parsed.host == "127.0.0.1" else {
                launchURL = nil
                errorMessage = "DSH Web 工作台未启动（当前可能处于恢复模式）。"
                return
            }
            allowedPort = port
            launchURL = parsed
        } catch {
            guard !Task.isCancelled, generation == host.runtimeGeneration else { return }
            launchURL = nil
            errorMessage = "无法获取 Web 工作台地址：\(error.localizedDescription)"
        }
    }
}

private struct LoopbackWebView: UIViewRepresentable {
    let url: URL
    let allowedPort: Int
    let reloadToken: UUID
    let viewportMode: DSHWebViewportMode
    let onDisconnect: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedPort: allowedPort, viewportMode: viewportMode, onDisconnect: onDisconnect)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.lastLoadedURL = url
        context.coordinator.lastLoadedToken = reloadToken
        context.coordinator.viewportMode = viewportMode
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedPort = allowedPort
        context.coordinator.onDisconnect = onDisconnect
        if context.coordinator.viewportMode != viewportMode {
            context.coordinator.viewportMode = viewportMode
            context.coordinator.applyViewport(to: webView)
        }
        if context.coordinator.lastLoadedToken != reloadToken || context.coordinator.lastLoadedURL != url {
            context.coordinator.lastLoadedURL = url
            context.coordinator.lastLoadedToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var allowedPort: Int
        var viewportMode: DSHWebViewportMode
        var lastLoadedToken: UUID?
        var lastLoadedURL: URL?
        var onDisconnect: () -> Void

        init(allowedPort: Int, viewportMode: DSHWebViewportMode, onDisconnect: @escaping () -> Void) {
            self.allowedPort = allowedPort
            self.viewportMode = viewportMode
            self.onDisconnect = onDisconnect
        }

        func applyViewport(to webView: WKWebView) {
            let content = viewportMode.viewportContent
            let script = """
            (function() {
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    document.head.appendChild(meta);
                }
                meta.setAttribute('content', '\(content)');
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyViewport(to: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onDisconnect()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onDisconnect()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = target.scheme?.lowercased() ?? ""
            if scheme == "about" || scheme == "blob" || scheme == "data" {
                decisionHandler(.allow)
                return
            }
            if scheme == "http", target.host == "127.0.0.1", target.port == allowedPort {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated, scheme == "https" {
                #if canImport(UIKit)
                UIApplication.shared.open(target)
                #endif
            }
            decisionHandler(.cancel)
        }
    }
}
