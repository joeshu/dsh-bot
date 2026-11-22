import SwiftUI
#if canImport(WebKit) && canImport(UIKit)
import WebKit
import UIKit
#endif

/// Interactive in-app browser sheet showing the exact WKWebView controlled by the Bot,
/// allowing the user to watch live automation, lock Bot control during manual takeover,
/// inspect action history, or hand the current page back to the Bot.
public struct AgentBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controller = AgentBrowserController.shared
    @State private var addressText: String = ""
    @State private var showActionLog: Bool = false
    let workspace: URL?
    let onHandbackToBot: ((String) -> Void)?

    private static let quickBookmarks: [(title: String, icon: String, url: String)] = [
        ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com"),
        ("Bing 搜索", "magnifyingglass", "https://www.bing.com"),
        ("维基百科", "book.closed", "https://zh.wikipedia.org"),
        ("DuckDuckGo", "globe", "https://duckduckgo.com"),
    ]

    public init(workspace: URL? = nil, onHandbackToBot: ((String) -> Void)? = nil) {
        self.workspace = workspace
        self.onHandbackToBot = onHandbackToBot
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if canImport(WebKit) && canImport(UIKit)
                if controller.needsHumanTakeover || controller.isHumanControlling {
                    HStack(spacing: 8) {
                        Image(systemName: controller.needsHumanTakeover ? "hand.raised.fill" : "lock.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.needsHumanTakeover ? "Bot 请求人工接管（已暂停自动操作）" : "人工接管锁已开启（已暂停 Bot 操作）")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            if !controller.humanTakeoverReason.isEmpty {
                                Text(controller.humanTakeoverReason)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Button(controller.isHumanControlling ? "解除锁定" : "锁定") {
                            controller.toggleHumanControl()
                        }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.14))
                }

                HStack(spacing: 8) {
                    TextField("输入 HTTPS 网址（或由 Bot 自动控制）", text: $addressText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(DSTheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onSubmit {
                            controller.loadManualURL(addressText)
                        }
                    Button {
                        if controller.isLoading {
                            controller.webView.stopLoading()
                        } else if !addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && addressText != controller.currentURL {
                            controller.loadManualURL(addressText)
                        } else {
                            controller.webView.reload()
                        }
                    } label: {
                        Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if controller.isLoading && controller.estimatedProgress < 1.0 {
                    ProgressView(value: controller.estimatedProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(DSTheme.brand)
                        .frame(height: 2)
                }

                ZStack {
                    SharedAgentWebViewRepresentable(webView: controller.webView)
                        .ignoresSafeArea(edges: .bottom)

                    if controller.currentURL.isEmpty && !controller.isLoading {
                        ScrollView {
                            VStack(spacing: 18) {
                                Image(systemName: "safari.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(DSTheme.brand)
                                    .padding(.top, 28)
                                VStack(spacing: 6) {
                                    Text("App 内置浏览器")
                                        .font(.headline)
                                    Text("与当前 Bot 共享同一个实时页面与登录会话。\n你可以先手动打开并登录网站，再交由 Bot 接手读取或操作。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(.horizontal, 24)

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                    ForEach(Self.quickBookmarks, id: \.url) { item in
                                        Button {
                                            controller.loadManualURL(item.url)
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: item.icon)
                                                    .foregroundStyle(DSTheme.brand)
                                                Text(item.title)
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(.primary)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(DSTheme.surfaceSecondary)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        .background(DSTheme.surfacePrimary)
                    }
                }

                VStack(spacing: 6) {
                    if showActionLog && !controller.actionHistory.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(controller.actionHistory.prefix(12)) { entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(entry.actor == .bot ? "Bot" : (entry.actor == .user ? "人工" : "系统"))
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(entry.actor == .bot ? DSTheme.brandSoft : Color.orange.opacity(0.16))
                                            .foregroundStyle(entry.actor == .bot ? DSTheme.brand : .orange)
                                            .clipShape(Capsule())
                                        Text(entry.summary)
                                            .font(.caption2)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Spacer()
                                        Text(entry.timestamp, style: .time)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 130)
                        Divider()
                    }

                    if !controller.lastActionSummary.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showActionLog.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.caption2)
                                    .foregroundStyle(DSTheme.brand)
                                Text(controller.lastActionSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                if !controller.actionHistory.isEmpty {
                                    Label("\(controller.actionHistory.count)", systemImage: showActionLog ? "chevron.down" : "chevron.up")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if let onHandbackToBot, !controller.currentURL.isEmpty {
                        HStack(spacing: 8) {
                            Button {
                                let wasTakeover = controller.needsHumanTakeover || controller.isHumanControlling
                                controller.clearTakeoverFlag()
                                let dlHint = controller.lastDownloadedFile.isEmpty ? "" : "（最近下载文件：\(controller.lastDownloadedFile)）"
                                let prompt = wasTakeover
                                    ? "我已在内置浏览器中完成手动操作（当前页：\(controller.currentURL)）\(dlHint)，请调用 browser_snapshot 检查当前页面并继续刚才的任务。"
                                    : "请调用 browser_snapshot 读取我当前在内置浏览器打开的页面（\(controller.currentURL)）\(dlHint)，并帮我总结或分析页面内容。"
                                dismiss()
                                onHandbackToBot(prompt)
                            } label: {
                                Label(
                                    (controller.needsHumanTakeover || controller.isHumanControlling) ? "我已完成，交回 Bot 继续" : "让 Bot 读取当前页面",
                                    systemImage: (controller.needsHumanTakeover || controller.isHumanControlling) ? "checkmark.circle.fill" : "sparkles"
                                )
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint((controller.needsHumanTakeover || controller.isHumanControlling) ? .orange : DSTheme.brand)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DSTheme.surfaceSecondary)
                #else
                Text("当前平台不支持内置浏览器。")
                    .foregroundStyle(.secondary)
                #endif
            }
            .navigationTitle(controller.pageTitle.isEmpty ? "App 内置浏览器" : controller.pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                #if canImport(WebKit) && canImport(UIKit)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        controller.webView.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!controller.canGoBack)
                    Button {
                        controller.webView.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!controller.canGoForward)
                    Menu {
                        Button {
                            controller.toggleHumanControl()
                        } label: {
                            Label(
                                controller.isHumanControlling ? "解除人工接管锁（恢复 Bot 控制）" : "开启人工接管锁（暂停 Bot 操作）",
                                systemImage: controller.isHumanControlling ? "lock.open" : "hand.raised"
                            )
                        }
                        Toggle(isOn: $controller.useDesktopUserAgent) {
                            Label("桌面版网页 (Desktop UA)", systemImage: "desktopcomputer")
                        }
                        if let url = URL(string: controller.currentURL), !controller.currentURL.isEmpty {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label("在 Safari 中打开", systemImage: "safari")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            controller.clearBrowsingData()
                        } label: {
                            Label("清除浏览器 Cookie 与缓存", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                #endif
            }
            .onAppear {
                if let workspace {
                    controller.workspaceDirectory = workspace
                }
                addressText = controller.currentURL
            }
            .onChange(of: controller.currentURL) { nextURL in
                addressText = nextURL
            }
        }
    }
}

#if canImport(WebKit) && canImport(UIKit)
private struct SharedAgentWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
