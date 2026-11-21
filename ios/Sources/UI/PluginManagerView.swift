import SwiftUI
import UniformTypeIdentifiers

private enum PluginManagerSection: String, CaseIterable, Identifiable {
    case installed = "已安装"
    case discover = "发现"
    case sources = "索引源"
    var id: String { rawValue }
}

private enum PendingPluginInstall: Identifiable {
    case catalog(DSHPluginCatalogItem)
    case github(String)
    case local(URL)

    var id: String {
        switch self {
        case .catalog(let plugin): return "catalog:\(plugin.id)"
        case .github(let url): return "github:\(url)"
        case .local(let url): return "local:\(url.path)"
        }
    }
}

public struct PluginManagerView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var section: PluginManagerSection = .installed
    @State private var searchText = ""
    @State private var newSourceURL = ""
    @State private var githubRepoURL = ""
    @State private var showFolderPicker = false
    @State private var pendingInstall: PendingPluginInstall?
    @State private var pendingRemoval: DSHInstalledPlugin?

    public var body: some View {
        NavigationStack {
            Form {
                Section("Web 工作台与连接器") {
                    NavigationLink {
                        DSHWebUIView(host: host)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("打开 DSH Web 工作台")
                                    .font(.headline)
                                Text("内嵌官方 Web UI，支持社区 dsh-client-ui-* 界面插件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "macwindow.on.rectangle")
                                .foregroundStyle(DSTheme.brand)
                        }
                    }
                    NavigationLink {
                        ConnectorMarketplaceView(host: host)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("连接器市场")
                                    .font(.headline)
                                Text("38 个标准 Remote MCP 服务（GitHub / Notion / DeepWiki / Exa 等）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .foregroundStyle(.indigo)
                        }
                    }
                }

                Section {
                    Label {
                        Text("第三方插件由其作者维护，DS Bot 不审核插件代码。插件在本机 DSH Node 进程内运行，可访问应用沙盒和网络。只安装你信任的来源。")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("iOS 安装会检查 DSH bundle、平台声明、纯 JS 依赖树和本机二进制；不会执行 npm 安装脚本。检查不能代替对作者和代码的信任判断。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("插件", selection: $section) {
                        ForEach(PluginManagerSection.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch section {
                case .installed:
                    installedSection
                case .discover:
                    discoverSection
                case .sources:
                    sourcesSection
                }

                if let status = host.pluginStatus, !status.isEmpty {
                    Section { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("探索与插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await host.refreshPluginState()
                            await host.refreshRedteamStatus()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(host.state != .ready)
                }
            }
            .task {
                await host.refreshPluginState()
                await host.refreshRedteamStatus()
                if host.pluginSources.contains(where: { $0.enabled }) {
                    await host.discoverPlugins()
                }
            }
            .onChange(of: section) { nextSection in
                if nextSection == .discover,
                   host.pluginSources.contains(where: { $0.enabled }),
                   host.pluginCatalog.isEmpty,
                   !host.isLoadingPlugins {
                    Task { await host.discoverPlugins(query: searchText) }
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { pendingInstall = .local(url) }
                case .failure(let error):
                    host.setPluginStatus(error.localizedDescription)
                }
            }
            .alert(item: $pendingInstall) { target in
                Alert(
                    title: Text("安装第三方插件代码？"),
                    message: Text("插件代码将在 DSH Node 进程中运行，可访问应用沙盒和网络。仅继续安装你已审阅并信任的插件。"),
                    primaryButton: .default(Text("继续安装")) {
                        Task {
                            switch target {
                            case .catalog(let plugin): await host.installPlugin(plugin)
                            case .github(let url):
                                await host.installGithubPlugin(url: url)
                                githubRepoURL = ""
                            case .local(let url): await host.installLocalPlugin(from: url)
                            }
                            await host.refreshRedteamStatus()
                        }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            .confirmationDialog(
                "确定卸载插件「\(pendingRemoval?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("卸载", role: .destructive) {
                    if let target = pendingRemoval {
                        pendingRemoval = nil
                        Task {
                            await host.removePlugin(target)
                            await host.refreshRedteamStatus()
                        }
                    }
                }
                Button("取消", role: .cancel) { pendingRemoval = nil }
            }
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        Section("dsh-purge-safe · iOS 适配与授权") {
            if host.redteamStatus.installed {
                Toggle(isOn: Binding(
                    get: { host.redteamModeEnabled },
                    set: { value in Task { await host.setRedteamMode(value) } }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("启用插件工具宿主（Bot + Web 控制台）").font(.subheadline.weight(.semibold))
                            DSStatusBadge(
                                host.redteamModeEnabled ? "已开启" : "已关闭",
                                color: host.redteamModeEnabled ? .red : .secondary
                            )
                        }
                        Text("这是全局宿主开关；每个 Bot 仍须单独获准使用工具、写入演练台或读取敏感资料。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.red)

                Toggle("允许 Web 演练台读取普通演练数据", isOn: Binding(
                    get: { host.redteamWebReadEnabled },
                    set: { value in Task { await host.setRedteamWebPermissions(readEnabled: value) } }
                ))
                Toggle("允许 Web 演练台写入演练记录", isOn: Binding(
                    get: { host.redteamWebWriteEnabled },
                    set: { value in Task { await host.setRedteamWebPermissions(writeEnabled: value) } }
                ))
                .disabled(!host.redteamWebReadEnabled)
                Toggle("允许 Web 查看敏感资料与主动探测", isOn: Binding(
                    get: { host.redteamWebSensitiveEnabled },
                    set: { value in Task { await host.setRedteamWebPermissions(sensitiveEnabled: value) } }
                ))
                .disabled(!host.redteamWebReadEnabled)
                Text("Web 权限独立于 Bot：普通读取、演练记录写入、凭据等敏感资料和主动探测分别控制。Web 控制台由用户直接操作；Bot 工具仍按会话授权并走 DSH/iOS 审批。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    DSStatusBadge(
                        host.redteamStatus.storeReady ? "SQLite 事实库就绪" : "事实库未加载",
                        color: host.redteamStatus.storeReady ? DSTheme.success : .secondary
                    )
                    DSStatusBadge("已挂载 \(host.redteamStatus.toolCount) 工具", color: DSTheme.brand)
                    DSStatusBadge("iOS 补丁旁路已关闭", color: DSTheme.success)
                    if host.redteamStatus.skillCount > 0 {
                        DSStatusBadge("\(host.redteamStatus.skillCount) 演练技能", color: .indigo)
                    }
                }

                Text("iOS 保留 RedTeam SQLite、工具、技能和 Web 演练台；关闭 dsh-purge-safe 根层的应用包修改、自动放行和子代理审批接管。文件修改仍走 DSH 原生审批。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !host.redteamStatus.webWorkbenchSupported {
                    Text(host.redteamStatus.compatibilityWarning.isEmpty
                         ? "当前插件版本未通过 iOS Web API 隔离适配；Web 演练台已禁用。"
                         : "Web 演练台已禁用：\(host.redteamStatus.compatibilityWarning)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !host.redteamStatus.tools.isEmpty {
                    DisclosureGroup("查看已挂载的红队工具 (\(host.redteamStatus.tools.count))") {
                        ForEach(host.redteamStatus.tools, id: \.self) { toolName in
                            Text(toolName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if host.redteamStatus.webWorkbenchSupported {
                    if !host.redteamModeEnabled {
                        Text("请先打开上方全局宿主开关，再进入 Web 演练台。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !host.redteamWebReadEnabled {
                        Text("请授予 Web 演练台读取权限后再打开。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        DSHWebUIView(host: host)
                    } label: {
                        Label("打开 Web 演练台（含 RedTeam Dock 与预设）", systemImage: "shield.lefthalf.filled")
                            .font(.subheadline)
                    }
                    .disabled(!host.redteamModeEnabled || !host.redteamWebReadEnabled)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("未安装 joeshu/dsh-purge-safe 插件")
                        .font(.subheadline.weight(.semibold))
                    Text("安装后可启用 RedTeam 工具、SQLite 事实库、技能与 Web 演练台；每个 Bot 的权限分别配置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    pendingInstall = .github("https://github.com/joeshu/dsh-purge-safe")
                } label: {
                    Label("安装 joeshu/dsh-purge-safe", systemImage: "arrow.down.circle.fill")
                }
                .disabled(host.state != .ready)
            }
        }

        Section("内置功能") {
            if let label = host.embeddedRuntimeLabel { LabeledContent("内嵌引擎", value: label) }
            NavigationLink {
                SubagentSettingsView(host: host)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(DSTheme.brand)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("子智能体").font(.subheadline.weight(.semibold))
                        Text("递归深度 \(host.subagentMaxDepth) · 并行上限 \(host.subagentMaxActive) · \(host.subagentEnabled ? "已启用" : "已停用")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink {
                WebSearchSettingsView(host: host)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.blue)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("网页搜索与获取").font(.subheadline.weight(.semibold))
                        Text("单次 \(host.webSearchCount) 条 · \(host.webSearchEnabled ? "搜索已启用" : "搜索未开启")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            NavigationLink {
                SmartRecommendationsSettingsView(host: host)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2.fill")
                        .foregroundStyle(.indigo)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("个性化推荐与操作卡片").font(.subheadline.weight(.semibold))
                        Text(host.smartActionCardsEnabled ? "回答下方展示上下文操作卡片" : "已停用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section("已安装插件") {
            if host.installedPlugins.isEmpty {
                VStack(spacing: 8) {
                    Label("还没有安装插件", systemImage: "shippingbox")
                    Text("从“发现”浏览索引，或导入本地 DSH bundle。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(host.installedPlugins) { plugin in
                    NavigationLink {
                        PluginDetailView(host: host, pluginId: plugin.id)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(DSTheme.brand.opacity(0.12))
                                    .frame(width: 38, height: 38)
                                Image(systemName: "puzzlepiece.fill")
                                    .foregroundStyle(DSTheme.brand)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(plugin.name).font(.subheadline.weight(.semibold))
                                    Text("v\(plugin.version)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill))
                                        .clipShape(Capsule())
                                }
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(plugin.enabled ? DSTheme.success : Color.secondary)
                                        .frame(width: 7, height: 7)
                                    Text(plugin.enabled ? "运行中" : (plugin.desiredEnabled ? (host.isDSHRecoveryMode ? "恢复模式下未加载" : "等待生效") : "已停用"))
                                        .font(.caption)
                                        .foregroundStyle(plugin.enabled ? DSTheme.success : .secondary)
                                    if plugin.components.count > 1 {
                                        Text("· \(plugin.components.count) 个组件")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("卸载", role: .destructive) {
                            pendingRemoval = plugin
                        }
                    }
                }
            }
            Button {
                section = .discover
                showFolderPicker = true
            } label: {
                Label("从本地文件夹安装", systemImage: "folder")
            }
        }
        Section("从 GitHub 仓库直接安装") {
            TextField("https://github.com/owner/repo 或 owner/repo", text: $githubRepoURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button {
                let target = githubRepoURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { return }
                pendingInstall = .github(target)
            } label: {
                Label("下载并安装 GitHub 插件", systemImage: "arrow.down.circle")
            }
            .disabled(githubRepoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.state != .ready)
            Text("适用于尚未收录到公共索引源的 DSH 插件仓库（如 joeshu/dsh-purge-safe）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var discoverSection: some View {
        Group {
            Section {
                HStack {
                    TextField("搜索 DSH 插件", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await host.discoverPlugins(query: searchText) } }
                    Button("搜索") { Task { await host.discoverPlugins(query: searchText) } }
                        .disabled(host.isLoadingPlugins)
                }
                if host.pluginSourceName == nil && !host.pluginSources.contains(where: { $0.enabled }) {
                    Text("先到“索引源”启用一个目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if host.isLoadingPlugins { ProgressView("正在读取索引…") }
            }

            Section(host.pluginSourceName.map { "来自 \($0)" } ?? "插件目录") {
                if host.pluginCatalog.isEmpty && !host.isLoadingPlugins {
                    Text("没有匹配结果。可刷新索引、更换来源，或在“已安装”页直接粘贴 GitHub 仓库地址安装。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(host.pluginCatalog) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title).font(.headline)
                            Spacer()
                            Text(item.version.isEmpty ? "未知版本" : item.version)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(item.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if !item.description.isEmpty {
                            Text(item.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        HStack {
                            Text(item.installable ? "待验证 · \(item.installSource)" : "仅浏览")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(item.installable ? "安装" : "仅浏览") {
                                guard item.installable else { return }
                                pendingInstall = .catalog(item)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!item.installable || host.installedPlugins.contains(where: { $0.name == item.name }))
                        }
                    }
                    .padding(.vertical, 4)
                }
                if host.pluginCatalog.count < host.pluginCatalogTotal {
                    Button("加载更多") { Task { await host.discoverPlugins(query: searchText, nextPage: true) } }
                        .disabled(host.isLoadingPlugins)
                }
                if !host.pluginCatalog.isEmpty {
                    Button("重新读取索引") { Task { await host.discoverPlugins(query: searchText, forceRefresh: true) } }
                        .disabled(host.isLoadingPlugins)
                }
            }
        }
    }

    private var sourcesSection: some View {
        Group {
            Section {
                Text("一次启用一个插件索引源；启用后会自动加载插件列表并跳转到“发现”页。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("示例索引源") {
                ForEach(host.pluginSources) { source in
                    Toggle(isOn: Binding(
                        get: { host.pluginSources.first(where: { $0.id == source.id })?.enabled ?? source.enabled },
                        set: { value in
                            Task {
                                await host.setPluginSourceEnabled(id: source.id, enabled: value)
                                if value { section = .discover }
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(source.name).font(.subheadline.weight(.semibold))
                                if source.builtIn { Text("第三方").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                            }
                            Text(source.url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                    .tint(DSTheme.brand)
                    .swipeActions {
                        if !source.builtIn {
                            Button("移除", role: .destructive) { Task { await host.removePluginSource(id: source.id) } }
                        }
                    }
                }
            }

            Section("添加索引源") {
                TextField("https://example.com/index.json", text: $newSourceURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("添加") {
                    let value = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await host.addPluginSource(url: value)
                        newSourceURL = ""
                    }
                }
                .disabled(newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

public struct PluginDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    let pluginId: String
    @State private var confirmUninstall = false

    private var plugin: DSHInstalledPlugin? {
        host.installedPlugins.first(where: { $0.id == pluginId })
    }

    public var body: some View {
        Form {
            if let plugin {
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                                .frame(width: 48, height: 48)
                            Image(systemName: "puzzlepiece.extension")
                                .font(.title2)
                                .foregroundStyle(.primary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plugin.name).font(.headline)
                            HStack(spacing: 6) {
                                Text("v\(plugin.version)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Capsule())
                                Text(plugin.compatibilityLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Capsule())
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { plugin.desiredEnabled },
                            set: { value in Task { await host.setPluginEnabled(plugin, enabled: value) } }
                        ))
                        .labelsHidden()
                        .disabled(host.isDSHRecoveryMode && !plugin.desiredEnabled)
                    }
                    .padding(.vertical, 4)

                    if !plugin.description.isEmpty {
                        Text(plugin.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                let components = plugin.components.isEmpty
                    ? [DSHPluginComponent(id: plugin.name, name: plugin.name, description: plugin.description, active: plugin.enabled)]
                    : plugin.components
                let runningCount = components.filter(\.active).count

                Section {
                    ForEach(components) { comp in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(comp.name)
                                .font(.subheadline.weight(.semibold))
                            if !comp.description.isEmpty && comp.description != "子模块 \(comp.name)" {
                                Text(comp.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(comp.active ? DSTheme.success : Color.secondary)
                                    .frame(width: 7, height: 7)
                                Text(comp.active ? "运行中" : "已关闭")
                                    .font(.caption)
                                    .foregroundStyle(comp.active ? DSTheme.success : .secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("包含的组件")
                } footer: {
                    Text("共 \(components.count) 个 · \(runningCount) 运行中")
                }

                Section("高级") {
                    LabeledContent("包名", value: plugin.name)
                    LabeledContent("代码来源", value: plugin.sourceLabel)
                    LabeledContent("当前版本", value: plugin.version)
                    LabeledContent("兼容性", value: plugin.compatibilityLabel)
                }

                Section {
                    Button("卸载此插件", role: .destructive) {
                        confirmUninstall = true
                    }
                }
            } else {
                Text("该插件已卸载或不可用。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(plugin?.name ?? "插件详情")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定卸载插件「\(plugin?.name ?? "")」？", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("卸载", role: .destructive) {
                if let target = plugin {
                    Task {
                        await host.removePlugin(target)
                        dismiss()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

