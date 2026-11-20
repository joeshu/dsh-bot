import SwiftUI
import WebKit
import UniformTypeIdentifiers

public struct StorePluginItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let compatibility: String
    public let compatible: Bool
    public let reason: String?
    public var installed: Bool
    public var enabled: Bool
}

public struct IndexSourceItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let badge: String
    public let description: String
    public let host: String
    public let url: String
    public var enabled: Bool
}

public struct ExperimentalPluginItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let description: String
    public var enabled: Bool
}

/// Unified DSH Plugin Center matching the Fish Pocket / DSH iOS plugin ecosystem:
/// - Top segmented pills: 已安装 | 发现 + "..." menu (索引源 / 安装第三方插件)
/// - Web UI notice banner with quick "网页版" entry for plugins shipping Web UIs
/// - 3 sections: 已安装插件, 内置功能, 实验性插件
/// - Index Source sheet (dsh-market, dshfind, custom https://.../index.json)
/// - Add Plugin sheet (npm package or GitHub URL, local folder import, China mirror switch)
public struct PluginStoreView: View {
    private enum ActiveTab: String, CaseIterable {
        case installed = "已安装"
        case discover = "发现"
    }

    @ObservedObject var host: BareWorkletHost
    @State private var selectedTab: ActiveTab = .installed
    @State private var showIndexSheet = false
    @State private var showAddPluginSheet = false
    @State private var showWebNoticeAlert = false
    @State private var useChinaMirror = true
    @State private var installedItems: [StorePluginItem] = []
    @State private var discoverItems: [StorePluginItem] = []
    @State private var indexSources: [IndexSourceItem] = [
        IndexSourceItem(id: "dsh-market", name: "dsh-market", badge: "第三方", description: "社区维护的 DSH 插件目录，发布在 GitHub 上，通过 jsDelivr 访问。", host: "cdn.jsdelivr.net", url: "https://cdn.jsdelivr.net/gh/dsh-market/index@main/index.json", enabled: false),
        IndexSourceItem(id: "dshfind", name: "dshfind", badge: "第三方", description: "社区维护的 DSH 插件目录，由 dshfind.com 提供。", host: "api.dshfind.com", url: "https://api.dshfind.com/v1/index.json", enabled: false),
    ]
    @State private var experimentalItems: [ExperimentalPluginItem] = [
        ExperimentalPluginItem(id: "auto-auth-review", title: "自动授权审查", description: "提供“自动审查”访问模式：每次工具调用前自动评估风险。", enabled: true),
        ExperimentalPluginItem(id: "dev-tools", title: "开发者工具", description: "用于排查问题：在「会话数据诊断」中查看原始事件与状态。", enabled: false),
        ExperimentalPluginItem(id: "deepseek-session-import", title: "DeepSeek 会话导入", description: "点击“新建会话”旁的按钮上传历史会话记录。", enabled: false),
        ExperimentalPluginItem(id: "changes-worktree", title: "变更请求与工作树", description: "在会话侧栏中集中跟踪关联的 Git 变更。", enabled: true),
        ExperimentalPluginItem(id: "liveshare", title: "LiveShare 会话分享", description: "把当前会话分享给同事，对方可只读或协作查看。", enabled: false),
        ExperimentalPluginItem(id: "personalization", title: "个性化推荐", description: "针对你对 DSH 的个性化需求提供提示与推荐。", enabled: true),
        ExperimentalPluginItem(id: "git-worktree", title: "Git 工作树", description: "要求在新分支上工作时自动管理工作树。", enabled: true),
    ]
    @State private var statusMessage = ""
    @State private var isLoading = false
    @State private var discoverFilter = ""

    public init(host: BareWorkletHost) {
        self.host = host
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top segmented pill bar: 已安装 | 发现
                HStack(spacing: 10) {
                    ForEach(ActiveTab.allCases, id: \.self) { tab in
                        Button {
                            selectedTab = tab
                            if tab == .discover {
                                Task { await refreshDiscover() }
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(selectedTab == tab ? Color.primary : Color(.secondarySystemBackground))
                                .foregroundColor(selectedTab == tab ? Color(.systemBackground) : .primary)
                                .clipShape(Capsule())
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if selectedTab == .installed {
                    installedListView
                } else {
                    discoverListView
                }
            }
            .scrollDismissesKeyboard(.interactively)
        .navigationTitle("插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showIndexSheet = true } label: {
                            Label("索引源", systemImage: "list.bullet")
                        }
                        Button { showAddPluginSheet = true } label: {
                            Label("安装第三方插件", systemImage: "shippingbox")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showIndexSheet) {
                PluginIndexSheet(sources: $indexSources, onToggleSource: { id, enabled in
                    Task { await setActiveIndexSource(enabled ? id : nil) }
                }, onAddCustom: { url in
                    Task { await addCustomIndexSource(url: url) }
                })
            }
            .sheet(isPresented: $showAddPluginSheet) {
                AddPluginSheet(
                    useChinaMirror: $useChinaMirror,
                    onInstallPackageOrGitHub: { spec in
                        Task { await install(spec: spec) }
                    },
                    onInstallLocalFolder: { folderURL in
                        Task { await installLocal(folderURL: folderURL) }
                    }
                )
            }
            .sheet(isPresented: $showWebNoticeAlert) {
                PluginWebPreviewSheet(dshVersion: host.activeVersion)
            }
            .task {
                await refreshOverview()
            }
        }
    }

    private var installedListView: some View {
        List {
            // Web UI info banner matching Fish Pocket UX
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("插件自带的界面不会在 App 里显示，可在网页版中查看。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("网页版") { showWebNoticeAlert = true }
                        .font(.caption.weight(.semibold))
                }
            }

            // 1. 已安装插件
            Section("已安装插件") {
                if installedItems.isEmpty {
                    Text("尚未安装第三方插件，可点击右上角「...」配置索引源或手动安装。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(installedItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.headline)
                                Text(item.description.isEmpty ? "v\(item.version)" : item.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(item.enabled ? "已启用" : "已停用")
                                .font(.caption)
                                .foregroundColor(item.enabled ? .green : .secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("卸载", role: .destructive) {
                                Task { await uninstall(name: item.name) }
                            }
                            Button(item.enabled ? "停用" : "启用") {
                                Task { await togglePlugin(name: item.name, enabled: !item.enabled) }
                            }
                            .tint(.blue)
                        }
                    }
                }
            }

            // 2. 内置功能
            Section("内置功能") {
                builtinRow(icon: "person.2", title: "子智能体", subtitle: "设置子智能体的递归层级、数量和模型。")
                builtinRow(icon: "magnifyingglass", title: "网页搜索与获取", subtitle: "选择搜索和读取网页各用哪个提供方。")
                builtinRow(icon: "arrow.triangle.2.circlepath", title: "Agent 循环", subtitle: "控制 Agent 派发工具调用的方式。")
                builtinRow(icon: "terminal", title: "终端", subtitle: "限制每条命令最多能跑多久、最多输出多少（iOS 走远程 MCP/沙盒）。")
            }

            // 3. 实验性插件
            Section("实验性插件") {
                ForEach($experimentalItems) { $exp in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exp.title).font(.subheadline.weight(.medium))
                            Text(exp.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Toggle(exp.enabled ? "已启用" : "已停用", isOn: $exp.enabled)
                            .labelsHidden()
                            .onChange(of: exp.enabled) { next in
                                Task {
                                    _ = try? await host.rpc()?.request("plugins.experimental.toggle", params: ["id": exp.id, "enabled": next])
                                }
                            }
                    }
                }
            }

            if !statusMessage.isEmpty {
                Section("状态") {
                    Text(statusMessage).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .refreshable { await refreshOverview() }
        .scrollDismissesKeyboard(.interactively)
    }

    private var discoverListView: some View {
        List {
            if isLoading {
                ProgressView("正在拉取索引源目录...")
            } else if indexSources.allSatisfy({ !$0.enabled }) {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("未启用索引源")
                            .font(.headline)
                        Text("默认不启用任何第三方索引源。请前往「索引源」启用 dsh-market、dshfind 或添加自定义 index.json。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("配置索引源") { showIndexSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Section("发现插件") {
                    TextField("按名称或描述筛选插件...", text: $discoverFilter)
                        .textInputAutocapitalization(.never)
                    ForEach(discoverItems.filter {
                        discoverFilter.isEmpty
                        || $0.name.localizedCaseInsensitiveContains(discoverFilter)
                        || $0.description.localizedCaseInsensitiveContains(discoverFilter)
                    }) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.name).font(.headline)
                                Spacer()
                                Text("v\(item.version)").font(.caption2).foregroundColor(.secondary)
                            }
                            if !item.description.isEmpty {
                                Text(item.description).font(.caption).foregroundColor(.secondary)
                            }
                            HStack {
                                Spacer()
                                Button(item.installed ? "已安装" : "安装") {
                                    Task { await install(spec: item.name) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(item.installed)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func builtinRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: - RPC Actions

    private func refreshOverview() async {
        guard let rpc = host.rpc() else { return }
        if let res = try? await rpc.request("plugins.overview") {
            let rawInstalled = res["installed"] as? [[String: Any]] ?? []
            installedItems = rawInstalled.compactMap { dict in
                guard let name = dict["name"] as? String else { return nil }
                return StorePluginItem(
                    id: name,
                    name: name,
                    version: dict["version"] as? String ?? "0.0.0",
                    description: dict["description"] as? String ?? "",
                    compatibility: "ios-ready",
                    compatible: true,
                    reason: nil,
                    installed: true,
                    enabled: dict["enabled"] as? Bool ?? true
                )
            }
            if let rawCustom = res["customIndexSources"] as? [[String: Any]] {
                for dict in rawCustom {
                    if let cid = dict["id"] as? String,
                       let url = dict["url"] as? String,
                       !indexSources.contains(where: { $0.id == cid }) {
                        indexSources.append(IndexSourceItem(
                            id: cid,
                            name: dict["name"] as? String ?? cid,
                            badge: "自定义",
                            description: "用户添加的自定义索引源",
                            host: dict["host"] as? String ?? "",
                            url: url,
                            enabled: false
                        ))
                    }
                }
            }
            if let activeId = res["activeIndexSourceId"] as? String {
                for idx in indexSources.indices {
                    indexSources[idx].enabled = (!activeId.isEmpty && indexSources[idx].id == activeId)
                }
            }
            if let expFlags = res["experimentalFlags"] as? [String: Bool] {
                for idx in experimentalItems.indices {
                    if let saved = expFlags[experimentalItems[idx].id] {
                        experimentalItems[idx].enabled = saved
                    }
                }
            }
            if let reg = res["registryUrl"] as? String {
                useChinaMirror = reg.contains("npmmirror")
            }
        }
    }

    private func refreshDiscover() async {
        guard let rpc = host.rpc() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let res = try await rpc.request("plugins.discover")
            let raw = res["items"] as? [[String: Any]] ?? []
            discoverItems = raw.compactMap { dict in
                guard let name = dict["name"] as? String else { return nil }
                return StorePluginItem(
                    id: name,
                    name: name,
                    version: dict["version"] as? String ?? "latest",
                    description: dict["description"] as? String ?? "",
                    compatibility: "ios-ready",
                    compatible: true,
                    reason: nil,
                    installed: installedItems.contains { $0.name == name },
                    enabled: false
                )
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func setActiveIndexSource(_ sourceId: String?) async {
        for idx in indexSources.indices {
            indexSources[idx].enabled = (indexSources[idx].id == sourceId)
        }
        _ = try? await host.rpc()?.request("plugins.index.setActive", params: ["sourceId": sourceId ?? ""])
        if selectedTab == .discover { await refreshDiscover() }
    }

    private func addCustomIndexSource(url: String) async {
        if (try? await host.rpc()?.request("plugins.index.addCustom", params: ["url": url, "activate": true])) != nil {
            if let parsed = URL(string: url), let hostName = parsed.host {
                let cid = "custom-\(hostName)"
                for idx in indexSources.indices { indexSources[idx].enabled = false }
                indexSources.removeAll { $0.id == cid }
                indexSources.append(IndexSourceItem(id: cid, name: hostName, badge: "自定义", description: "用户添加的自定义索引源", host: hostName, url: url, enabled: true))
            }
            statusMessage = "已添加并启用自定义索引源：\(url)"
            DSHaptics.notify(.success)
            await refreshDiscover()
        }
    }

    private func install(spec: String) async {
        guard let rpc = host.rpc() else { return }
        let registry = useChinaMirror ? "https://registry.npmmirror.com" : "https://registry.npmjs.org"
        _ = try? await rpc.request("plugins.setRegistry", params: ["url": registry])
        do {
            _ = try await rpc.request("plugins.install", params: ["name": spec])
            statusMessage = "已安装插件：\(spec)"
            await refreshOverview()
        } catch {
            statusMessage = "安装失败：\(error.localizedDescription)"
        }
    }

    private func installLocal(folderURL: URL) async {
        guard let rpc = host.rpc() else { return }
        let granted = folderURL.startAccessingSecurityScopedResource()
        defer { if granted { folderURL.stopAccessingSecurityScopedResource() } }
        do {
            _ = try await rpc.request("plugins.installLocal", params: ["folderPath": folderURL.path])
            statusMessage = "已从本地文件夹复制并安装插件：\(folderURL.lastPathComponent)"
            await refreshOverview()
        } catch {
            statusMessage = "本地安装失败：\(error.localizedDescription)"
        }
    }

    private func togglePlugin(name: String, enabled: Bool) async {
        _ = try? await host.rpc()?.request("plugins.toggle", params: ["name": name, "enabled": enabled])
        await refreshOverview()
    }

    private func uninstall(name: String) async {
        _ = try? await host.rpc()?.request("plugins.uninstall", params: ["name": name])
        statusMessage = "已卸载插件：\(name)"
        await refreshOverview()
    }
}

/// Sheet 1: 索引源管理（dsh-market / dshfind / 自定义 HTTPS index.json）
private struct PluginIndexSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var sources: [IndexSourceItem]
    let onToggleSource: (String, Bool) -> Void
    let onAddCustom: (String) -> Void
    @State private var customURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundColor(.orange)
                        Text("DS Bot 不运营第三方插件市场。下面的示例索引由第三方社区独立维护，是否启用、安装哪些插件请自行甄别，只安装你信任的来源。")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("示例索引源"), footer: Text("默认不启用。同一时间只能启用一个索引源，启用另一个会替换当前的。")) {
                    ForEach($sources) { $source in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(source.name).font(.headline)
                                    Text(source.badge)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(Capsule())
                                }
                                Text(source.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(source.host)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { source.enabled },
                                set: { next in onToggleSource(source.id, next) }
                            ))
                            .labelsHidden()
                        }
                    }
                }

                Section(header: Text("添加索引源"), footer: Text("打开「发现」时，App 会访问启用的索引源。其中的插件安装后以你的权限运行。")) {
                    TextField("https://example.com/index.json", text: $customURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("添加") {
                        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onAddCustom(trimmed)
                        customURL = ""
                    }
                    .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("索引源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }
}

/// Sheet 2: 添加插件（包名或 GitHub 地址 + 从本地文件夹安装 + 中国大陆镜像源切换）
private struct AddPluginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var useChinaMirror: Bool
    let onInstallPackageOrGitHub: (String) -> Void
    let onInstallLocalFolder: (URL) -> Void

    @State private var packageOrGitHub = ""
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section(
                    header: Text("包名或 GitHub 地址"),
                    footer: Text("插件以你的权限运行，也可能调用授权后的本机能力（文件、网络、剪贴板、通知、日历、语音等）。只安装信任的来源。")
                ) {
                    TextField("dsh-plugin-whale-pet", text: $packageOrGitHub)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        showFolderPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("从本地文件夹安装").foregroundColor(.primary)
                                Text("选择插件所在的文件夹，App 会复制一份再安装")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Picker("安装源", selection: $useChinaMirror) {
                        Text("中国大陆镜像源").tag(true)
                        Text("官方源 (npmjs)").tag(false)
                    }
                }
            }
            .navigationTitle("添加插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("安装") {
                        let spec = packageOrGitHub.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !spec.isEmpty else { return }
                        onInstallPackageOrGitHub(spec)
                        dismiss()
                    }
                    .disabled(packageOrGitHub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let first = urls.first {
                    onInstallLocalFolder(first)
                    dismiss()
                }
            }
        }
    }
}


/// Sandboxed WKWebView sheet for viewing DSH plugin Web UIs on iOS.
private struct PluginWebPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let dshVersion: String

    var body: some View {
        NavigationStack {
            PluginLocalWebView(html: """
            <!doctype html>
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark">
            <style>body{font-family:-apple-system,sans-serif;padding:24px;color:#111;background:#f8fafc;}
            .card{background:#fff;border-radius:16px;padding:18px;box-shadow:0 2px 10px rgba(0,0,0,.06);}
            h2{margin:0 0 8px;font-size:18px;}p{margin:6px 0;color:#475569;font-size:14px;line-height:1.5;}
            @media(prefers-color-scheme:dark){body{color:#f1f5f9;background:#0f172a;}.card{background:#1e293b;box-shadow:none;}p{color:#cbd5e1;}}</style>
            </head><body><div class="card">
            <h2>DSH \(dshVersion) 插件网页版容器</h2>
            <p>支持渲染带有 <code>dsh.client</code> 前端界面的纯 JS 原生插件。核心工具与命令已自动注册至 iOS 原生对话引擎。</p>
            </div></body></html>
            """)
            .navigationTitle("插件网页版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
    }
}

private struct PluginLocalWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
