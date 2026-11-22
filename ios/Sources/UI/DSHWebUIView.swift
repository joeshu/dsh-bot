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
            return "width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes, viewport-fit=cover"
        case .desktop1280:
            return "width=1280, initial-scale=0.32, minimum-scale=0.25, maximum-scale=5.0, user-scalable=yes, viewport-fit=cover"
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
            if newPhase == .active, host.state == .ready {
                Task { await loadWebUIInfo(preserveIfSamePort: true) }
            }
        }
        .onDisappear {
            Task { await host.syncFromWebWorkbench() }
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

    private func loadWebUIInfo(preserveIfSamePort: Bool = false) async {
        let generation = host.runtimeGeneration
        if !preserveIfSamePort {
            errorMessage = nil
        }
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
            if preserveIfSamePort && allowedPort == port && launchURL != nil {
                return
            }
            errorMessage = nil
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

    private static let mobileStyleInjectScript = """
    (function() {
      if (window.__dsbotMobileStyleInjected) return;
      window.__dsbotMobileStyleInjected = true;
      var style = document.createElement('style');
      style.id = 'dsh-mobile-inject';
      style.textContent = [
        ':where(body) { --dsw-alias-bg-layer-4: color-mix(in srgb, var(--dsw-alias-bg-layer-3, #f3f4f6) 94%, var(--dsw-alias-label-primary, #111827) 6%); }',
        'html, body, #root, #app { height: 100dvh; max-height: 100dvh; }',
        'input, textarea, select { font-size: 16px !important; }',
        'table { display: block; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }',
        'pre { max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }',
        'body.dsbot-mobile-mode { padding-bottom: env(safe-area-inset-bottom, 0px); }',
        'body.dsbot-mobile-mode [role="menu"], body.dsbot-mobile-mode [role="listbox"], body.dsbot-mobile-mode [role="dialog"] { max-width: calc(100vw - 16px) !important; box-sizing: border-box; }',
        '@media (pointer: coarse) { body.dsbot-mobile-mode button, body.dsbot-mobile-mode [role="button"] { min-height: 36px; touch-action: manipulation; } }',
        '@media (hover: none) { *:hover { transition: none; } }'
      ].join('\\n');
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    private static let mobileDomAuditScript = """
    (function() {
      if (window.__dsbotMobileAuditInjected) return;
      window.__dsbotMobileAuditInjected = true;
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
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.userContentController.addUserScript(WKUserScript(
            source: Self.mobileStyleInjectScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: Self.mobileDomAuditScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var allowedPort: Int
        var viewportMode: DSHWebViewportMode
        var lastLoadedToken: UUID?
        var lastLoadedURL: URL?
        var onProgress: (Double) -> Void
        var onDisconnect: (String) -> Void
        private var progressObservation: NSKeyValueObservation?
        private var memoryTrimObserver: NSObjectProtocol?
        private var recentCrashTimestamps: [Date] = []
        private var activeDownloadDestinations: [ObjectIdentifier: URL] = [:]

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
            if let oldObserver = memoryTrimObserver {
                NotificationCenter.default.removeObserver(oldObserver)
            }
            memoryTrimObserver = NotificationCenter.default.addObserver(
                forName: .dsbotMemoryPressureTrim,
                object: nil,
                queue: .main
            ) { [weak webView] note in
                let tier = note.object as? String ?? ""
                guard tier == MemoryPressureTier.urgent.rawValue || tier == MemoryPressureTier.critical.rawValue else { return }
                webView?.configuration.websiteDataStore.removeData(
                    ofTypes: [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache],
                    modifiedSince: .distantPast
                ) {}
            }
        }

        func stopObserving() {
            progressObservation?.invalidate()
            progressObservation = nil
            if let oldObserver = memoryTrimObserver {
                NotificationCenter.default.removeObserver(oldObserver)
                memoryTrimObserver = nil
            }
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
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            #if canImport(UIKit)
            guard let presenter = Self.topViewController() else {
                completionHandler(nil)
                return
            }
            let alert = UIAlertController(title: "DSH Web 输入", message: prompt, preferredStyle: .alert)
            alert.addTextField { field in
                field.text = defaultText
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
            #else
            completionHandler(nil)
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
            if navigationAction.shouldPerformDownload {
                if scheme == "blob" || (scheme == "http" && target.host == "127.0.0.1" && target.port == allowedPort) {
                    decisionHandler(.download)
                    return
                }
                decisionHandler(.cancel)
                return
            }
            // Allow only safe loopback origin, about:blank, and blob: (for export previews); block data: XSS navigation.
            if scheme == "about" && target.absoluteString.lowercased().hasPrefix("about:blank") {
                decisionHandler(.allow)
                return
            }
            if scheme == "blob" {
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

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse,
               let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
               disposition.contains("attachment") {
                decisionHandler(.download)
                return
            }
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let safeName = suggestedFilename
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
                .replacingOccurrences(of: "..", with: "_")
            let fileName = safeName.isEmpty ? "dsh-export-\(Int(Date().timeIntervalSince1970)).bin" : safeName
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-web-downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(fileName)")
            activeDownloadDestinations[ObjectIdentifier(download)] = dest
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let key = ObjectIdentifier(download)
            guard let fileURL = activeDownloadDestinations.removeValue(forKey: key) else { return }
            #if canImport(UIKit)
            DispatchQueue.main.async {
                guard let presenter = Self.topViewController() else { return }
                let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = presenter.view
                sheet.popoverPresentationController?.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.maxY - 60,
                    width: 1,
                    height: 1
                )
                sheet.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: fileURL)
                }
                presenter.present(sheet, animated: true)
            }
            #endif
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let key = ObjectIdentifier(download)
            if let fileURL = activeDownloadDestinations.removeValue(forKey: key) {
                try? FileManager.default.removeItem(at: fileURL)
            }
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
