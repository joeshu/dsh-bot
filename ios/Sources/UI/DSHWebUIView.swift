import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// Hosts the embedded official DSH Web UI (`@deepseek-ai/dsh-web-app` + `@deepseek-ai/dsh-web-frontend`)
/// and any installed community `dsh-client-ui-*` plugins over the private loopback port.
public struct DSHWebUIView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var launchURL: URL?
    @State private var allowedPort: Int = 0
    @State private var errorMessage: String?
    @State private var reloadToken = UUID()

    public init(host: LocalAgentHost) {
        self.host = host
    }

    public var body: some View {
        Group {
            if let url = launchURL, allowedPort > 0 {
                LoopbackWebView(url: url, allowedPort: allowedPort, reloadToken: reloadToken)
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
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    reloadToken = UUID()
                    Task { await loadWebUIInfo() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task {
            await loadWebUIInfo()
        }
    }

    private func loadWebUIInfo() async {
        errorMessage = nil
        guard let rpc = host.rpc() else {
            errorMessage = "DSH 运行时尚未就绪，请稍候重试。"
            return
        }
        do {
            let info = try await rpc.request("web.ui.info", timeoutSeconds: 15)
            guard info["ready"] as? Bool == true,
                  let raw = info["url"] as? String,
                  let parsed = URL(string: raw),
                  let port = info["port"] as? Int, port > 0,
                  parsed.host == "127.0.0.1" else {
                errorMessage = "DSH Web 工作台未启动（当前可能处于恢复模式）。"
                return
            }
            allowedPort = port
            launchURL = parsed
        } catch {
            errorMessage = "无法获取 Web 工作台地址：\(error.localizedDescription)"
        }
    }
}

private struct LoopbackWebView: UIViewRepresentable {
    let url: URL
    let allowedPort: Int
    let reloadToken: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedPort: allowedPort)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.lastLoadedToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedPort = allowedPort
        if context.coordinator.lastLoadedToken != reloadToken {
            context.coordinator.lastLoadedToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var allowedPort: Int
        var lastLoadedToken: UUID?

        init(allowedPort: Int) {
            self.allowedPort = allowedPort
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
