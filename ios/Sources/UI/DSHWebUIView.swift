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
    @Environment(\.scenePhase) private var scenePhase
    @State private var launchURL: URL?
    @State private var allowedPort: Int = 0
    @State private var errorMessage: String?
    @State private var loadProgress: Double = 0
    @State private var reloadToken = UUID()
    @AppStorage("dsbot.web.viewportMode") private var viewportModeRaw: String = DSHWebViewportMode.responsive.rawValue

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var viewportMode: DSHWebViewportMode {
        DSHWebViewportMode(rawValue: viewportModeRaw) ?? .responsive
    }

    public var body: some View {
        ZStack(alignment: .top) {
            contentBody
            if launchURL != nil, loadProgress > 0, loadProgress < 1.0 {
                ProgressView(value: loadProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(DSTheme.brand)
                    .frame(height: 2)
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
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active, launchURL == nil, host.state == .ready {
                Task { await loadWebUIInfo() }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if let url = launchURL, allowedPort > 0 {
            LoopbackWebView(
                url: url,
                allowedPort: allowedPort,
                reloadToken: reloadToken,
                viewportMode: viewportMode,
                onProgress: { progress in
                    loadProgress = progress
                },
                onDisconnect: { reason in
                    launchURL = nil
                    loadProgress = 0
                    errorMessage = reason
                }
            )
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
    let onProgress: (Double) -> Void
    let onDisconnect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            allowedPort: allowedPort,
            viewportMode: viewportMode,
            onProgress: onProgress,
            onDisconnect: onDisconnect
        )
    }

    private static let mobileInjectScript = """
    (function() {
      if (window.__dsbotMobileInjected) return;
      window.__dsbotMobileInjected = true;
      var style = document.createElement('style');
      style.id = 'dsh-mobile-inject';
      style.textContent = [
        ':where(body) { --dsw-alias-bg-layer-4: color-mix(in srgb, var(--dsw-alias-bg-layer-3, #f3f4f6) 94%, var(--dsw-alias-label-primary, #111827) 6%); }',
        'input, textarea, select { font-size: 16px !important; }',
        'table { display: block; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }',
        'pre { max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }',
        'body.dsbot-mobile-mode [role="menu"], body.dsbot-mobile-mode [role="listbox"], body.dsbot-mobile-mode [role="dialog"] { max-width: calc(100vw - 16px) !important; box-sizing: border-box; }',
        '@media (hover: none) { *:hover { transition: none; } }'
      ].join('\\n');
      (document.head || document.documentElement).appendChild(style);
      setTimeout(function() {
        try {
          if (document.body && document.body.classList.contains('dsbot-mobile-mode')
              && document.documentElement && document.documentElement.scrollWidth > window.innerWidth + 4) {
            document.documentElement.style.overflowX = 'clip';
          }
        } catch (_) {}
      }, 2000);
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        let userScript = WKUserScript(
            source: Self.mobileInjectScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        context.coordinator.observeProgress(of: webView)
        context.coordinator.lastLoadedURL = url
        context.coordinator.lastLoadedToken = reloadToken
        context.coordinator.viewportMode = viewportMode
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedPort = allowedPort
        context.coordinator.onProgress = onProgress
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

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var allowedPort: Int
        var viewportMode: DSHWebViewportMode
        var lastLoadedToken: UUID?
        var lastLoadedURL: URL?
        var onProgress: (Double) -> Void
        var onDisconnect: (String) -> Void
        private var progressObservation: NSKeyValueObservation?
        private var recentCrashTimestamps: [Date] = []

        init(
            allowedPort: Int,
            viewportMode: DSHWebViewportMode,
            onProgress: @escaping (Double) -> Void,
            onDisconnect: @escaping (String) -> Void
        ) {
            self.allowedPort = allowedPort
            self.viewportMode = viewportMode
            self.onProgress = onProgress
            self.onDisconnect = onDisconnect
        }

        func observeProgress(of webView: WKWebView) {
            progressObservation?.invalidate()
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                guard let self, let value = change.newValue else { return }
                DispatchQueue.main.async {
                    self.onProgress(value)
                }
            }
        }

        func stopObserving() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        func applyViewport(to webView: WKWebView) {
            let content = viewportMode.viewportContent
            let isMobile = viewportMode == .responsive ? "true" : "false"
            let script = """
            (function() {
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    document.head.appendChild(meta);
                }
                meta.setAttribute('content', '\(content)');
                if (document.body) {
                    document.body.classList.toggle('dsbot-mobile-mode', \(isMobile));
                }
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyViewport(to: webView)
            onProgress(1.0)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let now = Date()
            recentCrashTimestamps = recentCrashTimestamps.filter { now.timeIntervalSince($0) < 15 }
            recentCrashTimestamps.append(now)
            if recentCrashTimestamps.count <= 2 {
                // Auto-recover seamlessly from transient iOS WKWebContent Jetsam termination
                webView.reload()
            } else {
                onDisconnect("Web 渲染进程多次因系统内存紧张中断，请点击重试加载。")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onDisconnect("本机 Web 连接已断开（\(error.localizedDescription)），请重试加载。")
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let target = navigationAction.request.url else { return nil }
            let scheme = target.scheme?.lowercased() ?? ""
            if scheme == "http", target.host == "127.0.0.1", target.port == allowedPort {
                webView.load(navigationAction.request)
            } else if scheme == "https" {
                #if canImport(UIKit)
                UIApplication.shared.open(target)
                #endif
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            #if canImport(UIKit)
            guard let presenter = Self.topViewController() else {
                completionHandler()
                return
            }
            let alert = UIAlertController(title: "DSH Web 工作台", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            presenter.present(alert, animated: true)
            #else
            completionHandler()
            #endif
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            #if canImport(UIKit)
            guard let presenter = Self.topViewController() else {
                completionHandler(false)
                return
            }
            let alert = UIAlertController(title: "确认操作", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            presenter.present(alert, animated: true)
            #else
            completionHandler(false)
            #endif
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

        #if canImport(UIKit)
        private static func topViewController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let root = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)?.rootViewController
                ?? scenes.first?.windows.first?.rootViewController
            var current = root
            while let presented = current?.presentedViewController {
                current = presented
            }
            return current
        }
        #endif
    }
}
