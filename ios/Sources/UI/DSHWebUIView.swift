import SwiftUI
import UniformTypeIdentifiers
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

private enum DSHWebTextScale: Int, CaseIterable, Identifiable {
    case compact = 90
    case standard = 100
    case large = 110
    var id: Int { rawValue }
    var label: String { "\(rawValue)%" }
}

/// Hosts the embedded official DSH Web UI (`@deepseek-ai/dsh-web-app` + `@deepseek-ai/dsh-web-frontend`)
/// in an immersive mobile container featuring a floating top-right capsule (`••• | ✕`),
/// synced dark/light chrome, injected sidebar "返回 DS Bot ⇄" bridge, and mobile-refined CSS.
public struct DSHWebUIView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var browserController = AgentBrowserController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var launchURL: URL?
    @State private var allowedPort: Int = 0
    @State private var errorMessage: String?
    @State private var loadProgress: Double = 0
    @State private var reloadToken = UUID()
    @State private var recoveryTimestamps: [Date] = []
    @State private var isRecovering = false
    @State private var webBackgroundColor: Color?
    @State private var webIsDark: Bool?
    @State private var showAgentBrowser = false
    @State private var importBanner: String?
    @AppStorage("dsbot.web.viewportMode") private var viewportModeRaw: String = DSHWebViewportMode.responsive.rawValue
    @AppStorage("dsbot.web.textScale") private var textScaleRaw: Int = DSHWebTextScale.standard.rawValue
    private let initialSessionId: String?

    public init(host: LocalAgentHost, initialSessionId: String? = nil) {
        self.host = host
        self.initialSessionId = initialSessionId
    }

    private var viewportMode: DSHWebViewportMode {
        DSHWebViewportMode(rawValue: viewportModeRaw) ?? .responsive
    }

    private var textScale: DSHWebTextScale {
        DSHWebTextScale(rawValue: textScaleRaw) ?? .standard
    }

    private var effectiveIsDark: Bool {
        webIsDark ?? (systemColorScheme == .dark)
    }

    private var chromeBackground: Color {
        webBackgroundColor ?? (effectiveIsDark ? Color(red: 0.08, green: 0.08, blue: 0.09) : DSTheme.surfacePrimary)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            chromeBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Dedicated top capsule bar area matching the Web UI theme so the floating
                // `••• | ✕` capsule never overlaps the Web UI's own top-right toolbar icons.
                HStack {
                    if let importBanner {
                        Text(importBanner)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    floatingCapsule
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .background(chromeBackground)

                ZStack(alignment: .top) {
                    contentBody
                    if launchURL != nil, loadProgress > 0, loadProgress < 1.0 {
                        ProgressView(value: loadProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(DSTheme.brand)
                            .frame(height: 2)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showAgentBrowser) {
            AgentBrowserSheet(workspace: host.workspace)
        }
        .task(id: host.runtimeGeneration) {
            await loadWebUIInfo(preserveIfSamePort: true)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active, host.state == .ready {
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    await loadWebUIInfo(preserveIfSamePort: true)
                }
            }
        }
        .onDisappear {
            Task { await host.syncFromWebWorkbench() }
        }
    }

    private var floatingCapsule: some View {
        let iconColor: Color = effectiveIsDark ? .white : .primary
        let borderColor: Color = effectiveIsDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        let fillColor: Color = effectiveIsDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        let dividerColor: Color = effectiveIsDark ? Color.white.opacity(0.20) : Color.black.opacity(0.14)
        let needsTakeover = browserController.needsHumanTakeover || browserController.isHumanControlling

        return HStack(spacing: 0) {
            Menu {
                Section("手机文件与文本导入") {
                    Button {
                        #if canImport(UIKit)
                        NativeDocumentPicker.present(allowsMultipleSelection: true) { urls in
                            guard !urls.isEmpty else { return }
                            var importedPaths: [String] = []
                            var lastErr: String?
                            for url in urls {
                                do {
                                    let imported = try host.importFileToWorkspace(from: url)
                                    importedPaths.append("files/\(imported.relativePath)")
                                } catch {
                                    lastErr = error.localizedDescription
                                }
                            }
                            if !importedPaths.isEmpty {
                                UIPasteboard.general.string = importedPaths.joined(separator: "\n")
                                importBanner = importedPaths.count == 1
                                    ? "已导入 \(importedPaths[0])（路径已复制，可直接粘贴）"
                                    : "已导入 \(importedPaths.count) 个文件（路径已复制）"
                                DSHaptics.notify(.success)
                            } else if let lastErr {
                                importBanner = "导入失败：\(lastErr)"
                                DSHaptics.notify(.error)
                            }
                        }
                        #endif
                    } label: {
                        Label("导入手机文件到工作区 (files/)", systemImage: "square.and.arrow.down")
                    }
                    #if canImport(UIKit)
                    Button {
                        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !text.isEmpty else {
                            importBanner = "剪贴板为空"
                            return
                        }
                        do {
                            let stamp = Int(Date().timeIntervalSince1970)
                            let imported = try host.importRawDataToWorkspace(Data(text.utf8), suggestedName: "clipboard_\(stamp).txt")
                            importBanner = "已保存剪贴板文本：files/\(imported.relativePath)"
                            DSHaptics.notify(.success)
                        } catch {
                            importBanner = "保存失败：\(error.localizedDescription)"
                        }
                    } label: {
                        Label("粘贴剪贴板文本存为文件", systemImage: "doc.on.clipboard")
                    }
                    #endif
                }
                Picker("布局视口", selection: $viewportModeRaw) {
                    ForEach(DSHWebViewportMode.allCases) { mode in
                        Label(
                            mode.rawValue,
                            systemImage: mode == .desktop1280 ? "desktopcomputer" : "iphone"
                        )
                        .tag(mode.rawValue)
                    }
                }
                Picker("页面缩放", selection: $textScaleRaw) {
                    ForEach(DSHWebTextScale.allCases) { scale in
                        Text("文字缩放 \(scale.label)").tag(scale.rawValue)
                    }
                }
                Divider()
                Button {
                    showAgentBrowser = true
                } label: {
                    Label(
                        needsTakeover ? "打开内置浏览器（等待接管）" : "打开 App 内置浏览器",
                        systemImage: needsTakeover ? "hand.raised.fill" : "safari"
                    )
                }
                Button {
                    reloadToken = UUID()
                    Task { await loadWebUIInfo() }
                } label: {
                    Label("刷新工作台", systemImage: "arrow.clockwise")
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
                Divider()
                Button {
                    dismiss()
                } label: {
                    Label("返回 DS Bot", systemImage: "arrow.left.arrow.right")
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 42, height: 32)
                        .contentShape(Rectangle())
                    if needsTakeover {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                            .offset(x: -7, y: 6)
                    }
                }
            }

            Rectangle()
                .fill(dividerColor)
                .frame(width: 0.75, height: 16)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 42, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭并返回 DS Bot")
        }
        .background(
            Capsule(style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var contentBody: some View {
        if let url = launchURL, allowedPort > 0 {
            LoopbackWebView(
                url: url,
                allowedPort: allowedPort,
                reloadToken: reloadToken,
                initialSessionId: initialSessionId,
                viewportMode: viewportMode,
                textScalePercent: textScale.rawValue,
                onProgress: { progress in
                    loadProgress = progress
                },
                onThemeChanged: { color, isDark in
                    webBackgroundColor = color
                    webIsDark = isDark
                },
                onNativeAction: { action in
                    if action == "exitWebUI" {
                        dismiss()
                    } else if action == "openAgentBrowser" {
                        showAgentBrowser = true
                    }
                },
                onDisconnect: { reason in
                    guard !isRecovering else { return }
                    launchURL = nil
                    loadProgress = 0
                    errorMessage = reason
                },
                onProcessTerminate: { reason in
                    handleBoundedRecovery(reason: reason)
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
                    recoveryTimestamps.removeAll()
                    Task { await loadWebUIInfo() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在连接本机 DSH Web 工作台…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handleBoundedRecovery(reason: String) {
        guard !isRecovering else { return }
        let now = Date()
        recoveryTimestamps = recoveryTimestamps.filter { now.timeIntervalSince($0) < 15 }
        recoveryTimestamps.append(now)
        if recoveryTimestamps.count <= 2 {
            isRecovering = true
            Task {
                defer { isRecovering = false }
                try? await Task.sleep(nanoseconds: 250_000_000)
                reloadToken = UUID()
                await loadWebUIInfo()
            }
        } else {
            launchURL = nil
            loadProgress = 0
            errorMessage = reason
        }
    }

    /// Exchanges the one-shot `?token=` URL via URLSession (without following the 303 redirect),
    /// writes the resulting signed HttpOnly session cookie directly into `WKWebsiteDataStore.default().httpCookieStore`,
    /// and returns the clean loopback root URL so `WKWebView` never hits iOS WebKit's 303 + `SameSite=Strict` cookie-drop race.
    private static func exchangeTokenCookie(from authURL: URL, cleanBaseURL: URL) async -> URL {
        final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                willPerformHTTPRedirection response: HTTPURLResponse,
                newRequest request: URLRequest,
                completionHandler: @escaping (URLRequest?) -> Void
            ) {
                completionHandler(nil)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 8
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var req = URLRequest(url: authURL)
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...399).contains(http.statusCode) else {
                return authURL
            }
            var stringHeaders: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String {
                    stringHeaders[ks] = vs
                }
            }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: cleanBaseURL)
            guard !cookies.isEmpty else {
                return http.statusCode == 200 ? cleanBaseURL : authURL
            }
            let cookieStore = WKWebsiteDataStore.default().httpCookieStore
            for cookie in cookies {
                await cookieStore.setCookie(cookie)
            }
            return cleanBaseURL
        } catch {
            return authURL
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
            let cleanBaseURL = (info["baseUrl"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "http://127.0.0.1:\(port)/")
                ?? parsed
            let targetURL = await Self.exchangeTokenCookie(from: parsed, cleanBaseURL: cleanBaseURL)
            guard !Task.isCancelled, generation == host.runtimeGeneration else { return }
            errorMessage = nil
            allowedPort = port
            launchURL = targetURL
        } catch {
            guard !Task.isCancelled, generation == host.runtimeGeneration else { return }
            launchURL = nil
            errorMessage = "无法获取 Web 工作台地址：\(error.localizedDescription)"
        }
    }
}

private final class WeakWebScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private struct LoopbackWebView: UIViewRepresentable {
    let url: URL
    let allowedPort: Int
    let reloadToken: UUID
    let initialSessionId: String?
    let viewportMode: DSHWebViewportMode
    let textScalePercent: Int
    let onProgress: (Double) -> Void
    let onThemeChanged: (Color, Bool) -> Void
    let onNativeAction: (String) -> Void
    let onDisconnect: (String) -> Void
    let onProcessTerminate: (String) -> Void

    private static func sessionSeedScript(sessionId: String?) -> String? {
        guard let raw = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let jsonData = try? JSONSerialization.data(withJSONObject: ["sessionId": raw]),
              let payload = String(data: jsonData, encoding: .utf8),
              let keyData = try? JSONSerialization.data(withJSONObject: [raw]),
              let keyArr = String(data: keyData, encoding: .utf8) else {
            return nil
        }
        return """
        (function() {
          try {
            var tokenKey = '__dsbot_seeded_session_id';
            var targetId = (\(keyArr))[0];
            if (window.sessionStorage && window.sessionStorage.getItem(tokenKey) !== targetId) {
              window.sessionStorage.setItem(tokenKey, targetId);
              window.localStorage.setItem('dsh.sessions.current', JSON.stringify(\(payload)));
            }
          } catch (_) {}
        })();
        """
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            allowedPort: allowedPort,
            viewportMode: viewportMode,
            textScalePercent: textScalePercent,
            onProgress: onProgress,
            onThemeChanged: onThemeChanged,
            onNativeAction: onNativeAction,
            onDisconnect: onDisconnect,
            onProcessTerminate: onProcessTerminate
        )
    }

    private static let mobileStyleInjectScript = """
    (function() {
      // Bypass iOS WKWebView Blob Web Worker cookie/XHR restrictions by routing DSH file uploads
      // through main-thread fetch() with credentials: 'include' before Cordis boots FileUploadRuntime.
      if (!window.__DSH_FILE_UPLOAD__) {
        window.__DSH_FILE_UPLOAD__ = {
          fetch: function(input, init) {
            var opts = Object.assign({}, init || {}, { credentials: 'include' });
            return window.fetch(input, opts);
          }
        };
      }
      if (window.__dsbotMobileStyleInjected) return;
      window.__dsbotMobileStyleInjected = true;
      var style = document.createElement('style');
      style.id = 'dsh-mobile-inject';
      style.textContent = [
        ':where(body) { --dsw-alias-bg-layer-4: color-mix(in srgb, var(--dsw-alias-bg-layer-3, #f3f4f6) 94%, var(--dsw-alias-label-primary, #111827) 6%); }',
        'html, body { overscroll-behavior: none; -webkit-tap-highlight-color: transparent; }',
        'html, body, #root, #app { height: var(--dsbot-vvh, 100dvh); max-height: var(--dsbot-vvh, 100dvh); }',
        'body.dsbot-mobile-mode textarea, body.dsbot-mobile-mode input[type="text"], body.dsbot-mobile-mode input[type="search"], body.dsbot-mobile-mode input[type="url"], body.dsbot-mobile-mode input[type="email"], body.dsbot-mobile-mode input:not([type]) { font-size: 16px !important; }',
        'table { display: block; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }',
        'pre { max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }',
        'body.dsbot-mobile-mode { padding-bottom: env(safe-area-inset-bottom, 0px); }',
        'body.dsbot-mobile-mode [role="menu"], body.dsbot-mobile-mode [role="listbox"], body.dsbot-mobile-mode [role="dialog"], body.dsbot-mobile-mode [data-radix-popper-content-wrapper] { max-width: calc(100vw - 16px) !important; box-sizing: border-box; }',
        'body.dsbot-mobile-mode [role="menu"], body.dsbot-mobile-mode [role="listbox"] { border-radius: 14px; }',
        '@media (pointer: coarse) { body.dsbot-mobile-mode button, body.dsbot-mobile-mode [role="button"] { min-height: 34px; touch-action: manipulation; } }',
        '@media (hover: none) { *:hover { transition: none; } }',
        '.dsbot-return-pill { display: inline-flex; align-items: center; gap: 8px; padding: 9px 14px; margin: 8px 10px 4px; border-radius: 999px; border: 1px solid rgba(128,128,128,0.22); background: rgba(128,128,128,0.12); color: inherit; font-size: 14px; font-weight: 500; cursor: pointer; width: fit-content; max-width: calc(100% - 20px); -webkit-tap-highlight-color: transparent; }',
        '.dsbot-return-pill:active { opacity: 0.7; transform: scale(0.98); }'
      ].join('\\n');
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Syncs visualViewport (iOS keyboard), reports Web UI theme color to SwiftUI chrome,
    /// clamps accidental horizontal overflow, and injects the sidebar "返回 DS Bot ⇄" pill.
    private static let mobileBridgeAndEnhancementScript = """
    (function() {
      if (window.__dsbotMobileBridgeInstalled) return;
      window.__dsbotMobileBridgeInstalled = true;

      function postNative(payload) {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dsbotNative) {
            window.webkit.messageHandlers.dsbotNative.postMessage(payload);
          }
        } catch (_) {}
      }

      // 1. iOS virtual keyboard height sync
      function syncViewportHeight() {
        try {
          var h = (window.visualViewport && window.visualViewport.height) ? Math.round(window.visualViewport.height) : window.innerHeight;
          if (h > 180) {
            document.documentElement.style.setProperty('--dsbot-vvh', h + 'px');
          }
        } catch (_) {}
      }
      if (window.visualViewport) {
        window.visualViewport.addEventListener('resize', syncViewportHeight, { passive: true });
        window.visualViewport.addEventListener('scroll', syncViewportHeight, { passive: true });
      }
      window.addEventListener('resize', syncViewportHeight, { passive: true });
      syncViewportHeight();

      // 2. Sync Web UI dark/light background color to native top capsule chrome
      var lastThemeKey = '';
      function parseRGB(str) {
        var m = String(str || '').match(/rgba?\\((\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)(?:\\s*,\\s*([\\d.]+))?\\)/);
        if (!m) return null;
        var a = m[4] !== undefined ? parseFloat(m[4]) : 1;
        if (a < 0.05) return null;
        return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)];
      }
      function syncThemeToNative() {
        try {
          var bg = parseRGB(getComputedStyle(document.body || document.documentElement).backgroundColor)
            || parseRGB(getComputedStyle(document.documentElement).backgroundColor);
          if (!bg) return;
          var luminance = (0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]) / 255;
          var isDark = luminance < 0.5;
          var key = bg.join(',') + ':' + (isDark ? '1' : '0');
          if (key === lastThemeKey) return;
          lastThemeKey = key;
          postNative({ action: 'themeChanged', r: bg[0], g: bg[1], b: bg[2], isDark: isDark });
        } catch (_) {}
      }

      // 3. Inject "返回 DS Bot ⇄" pill at the bottom of the DSH left sidebar
      function ensureSidebarReturnPill() {
        try {
          if (document.getElementById('dsbot-return-pill')) return;
          var candidates = Array.from(document.querySelectorAll('aside, nav, [class*="sidebar"], [class*="Sidebar"], [role="navigation"]'));
          var target = candidates.find(function(el) {
            var rect = el.getBoundingClientRect();
            if (rect.width < 160 || rect.height < 300 || rect.left > 40) return false;
            var txt = el.innerText || '';
            return txt.includes('新会话') || txt.includes('工作区') || txt.includes('HARNESS') || txt.includes('Workspace');
          });
          if (!target) return;
          var btn = document.createElement('button');
          btn.id = 'dsbot-return-pill';
          btn.type = 'button';
          btn.className = 'dsbot-return-pill';
          btn.innerHTML = '<span style="font-size:15px;line-height:1">🐳</span><span>返回 DS Bot</span><span style="opacity:0.65;font-size:13px">⇄</span>';
          btn.addEventListener('click', function(ev) {
            ev.preventDefault();
            ev.stopPropagation();
            postNative({ action: 'exitWebUI' });
          });
          // Insert right before the bottom-most footer action if present, else append
          var children = target.children;
          if (children && children.length > 0) {
            var last = children[children.length - 1];
            if (last && (last.innerText || '').trim().length <= 12) {
              target.insertBefore(btn, last);
              return;
            }
          }
          target.appendChild(btn);
        } catch (_) {}
      }

      // 4. Horizontal overflow clamp in mobile mode
      function auditOverflow() {
        try {
          if (document.body && document.body.classList.contains('dsbot-mobile-mode')
              && document.documentElement && document.documentElement.scrollWidth > window.innerWidth + 4) {
            document.documentElement.style.overflowX = 'clip';
          }
        } catch (_) {}
      }

      var scheduled = false;
      function schedulePass() {
        if (scheduled) return;
        scheduled = true;
        setTimeout(function() {
          scheduled = false;
          syncThemeToNative();
          ensureSidebarReturnPill();
          auditOverflow();
        }, 220);
      }

      var observer = new MutationObserver(schedulePass);
      observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'data-theme', 'style'] });
      schedulePass();
      setTimeout(schedulePass, 1200);
      setTimeout(schedulePass, 2600);
    })();
    """

    private func installUserScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        if let seed = Self.sessionSeedScript(sessionId: initialSessionId) {
            controller.addUserScript(WKUserScript(
                source: seed,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        controller.addUserScript(WKUserScript(
            source: Self.mobileStyleInjectScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: Self.mobileBridgeAndEnhancementScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.userContentController.add(WeakWebScriptMessageHandler(context.coordinator), name: "dsbotNative")
        installUserScripts(on: config.userContentController)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.observeProgress(of: webView)
        context.coordinator.lastLoadedURL = url
        context.coordinator.lastLoadedToken = reloadToken
        context.coordinator.viewportMode = viewportMode
        context.coordinator.textScalePercent = textScalePercent
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedPort = allowedPort
        context.coordinator.onProgress = onProgress
        context.coordinator.onThemeChanged = onThemeChanged
        context.coordinator.onNativeAction = onNativeAction
        context.coordinator.onDisconnect = onDisconnect
        context.coordinator.onProcessTerminate = onProcessTerminate
        if context.coordinator.viewportMode != viewportMode || context.coordinator.textScalePercent != textScalePercent {
            context.coordinator.viewportMode = viewportMode
            context.coordinator.textScalePercent = textScalePercent
            context.coordinator.applyViewport(to: webView)
        }
        if context.coordinator.lastLoadedToken != reloadToken || context.coordinator.lastLoadedURL != url {
            context.coordinator.lastLoadedURL = url
            context.coordinator.lastLoadedToken = reloadToken
            installUserScripts(on: webView.configuration.userContentController)
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dsbotNative")
        webView.configuration.userContentController.removeAllUserScripts()
        webView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        var allowedPort: Int
        var viewportMode: DSHWebViewportMode
        var textScalePercent: Int
        var lastLoadedToken: UUID?
        var lastLoadedURL: URL?
        var onProgress: (Double) -> Void
        var onThemeChanged: (Color, Bool) -> Void
        var onNativeAction: (String) -> Void
        var onDisconnect: (String) -> Void
        var onProcessTerminate: (String) -> Void
        private var progressObservation: NSKeyValueObservation?
        private var memoryTrimObserver: NSObjectProtocol?
        private var activeDownloadDestinations: [ObjectIdentifier: URL] = [:]

        init(
            allowedPort: Int,
            viewportMode: DSHWebViewportMode,
            textScalePercent: Int,
            onProgress: @escaping (Double) -> Void,
            onThemeChanged: @escaping (Color, Bool) -> Void,
            onNativeAction: @escaping (String) -> Void,
            onDisconnect: @escaping (String) -> Void,
            onProcessTerminate: @escaping (String) -> Void
        ) {
            self.allowedPort = allowedPort
            self.viewportMode = viewportMode
            self.textScalePercent = textScalePercent
            self.onProgress = onProgress
            self.onThemeChanged = onThemeChanged
            self.onNativeAction = onNativeAction
            self.onDisconnect = onDisconnect
            self.onProcessTerminate = onProcessTerminate
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "dsbotNative",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            DispatchQueue.main.async {
                if action == "themeChanged",
                   let r = body["r"] as? Double,
                   let g = body["g"] as? Double,
                   let b = body["b"] as? Double,
                   let isDark = body["isDark"] as? Bool {
                    let color = Color(red: r / 255.0, green: g / 255.0, blue: b / 255.0)
                    self.onThemeChanged(color, isDark)
                } else {
                    self.onNativeAction(action)
                }
            }
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
            let scale = max(80, min(textScalePercent, 130))
            let script = """
            (function() {
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    document.head.appendChild(meta);
                }
                meta.setAttribute('content', '\(content)');
                if (document.documentElement) {
                    document.documentElement.style.webkitTextSizeAdjust = '\(scale)%';
                    document.documentElement.style.fontSize = '\(scale)%';
                }
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
            // Re-fetch fresh tokenized URL and exchange cookie via DSHWebUIView's bounded recovery state.
            onProcessTerminate("Web 渲染进程多次因系统内存紧张中断，请点击重试加载。")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }
            // Ignore WKErrorFrameLoadInterruptedByPolicyChange (102) triggered by decidePolicyFor(.cancel / .download)
            if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
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
            if let http = navigationResponse.response as? HTTPURLResponse {
                if navigationResponse.isForMainFrame && http.statusCode == 401 {
                    decisionHandler(.cancel)
                    onProcessTerminate("本机 Web 工作台认证未通过（HTTP 401），请点击重试加载。")
                    return
                }
                if let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
                   disposition.contains("attachment") {
                    decisionHandler(.download)
                    return
                }
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
                guard let presenter = Self.topViewController() else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
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
