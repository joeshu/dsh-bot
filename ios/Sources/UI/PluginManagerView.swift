import SwiftUI
import UniformTypeIdentifiers

private enum ExploreRootMode: String, CaseIterable, Identifiable {
    case settings = "引擎与设置"
    case plugins = "插件与红队"
    var id: String { rawValue }
}

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
    @State private var rootMode: ExploreRootMode = .settings
    @State private var section: PluginManagerSection = .installed
    @State private var searchText = ""
    @State private var newSourceURL = ""
    @State private var githubRepoURL = ""
    @State private var showFolderPicker = false
    @State private var isInstalling = false
    @State private var pendingInstall: PendingPluginInstall?
    @State private var pendingRemoval: DSHInstalledPlugin?

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var hasPendingRestart: Bool {
        !host.isDSHRecoveryMode && (
            host.installedPlugins.contains(where: { $0.desiredEnabled != $0.enabled })
                || (host.pluginStatus?.contains("重启") == true)
        )
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("模块", selection: $rootMode) {
                        ForEach(ExploreRootMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch rootMode {
                case .settings:
                    AgentSettingsFormSections(host: host)

                case .plugins:
                    if hasPendingRestart {
                        Section {
                            DSBannerCard(
                                icon: "arrow.triangle.2.circlepath.circle.fill",
                                tint: DSTheme.warning,
                                message: "检测到插件安装/更新或开关变更，重启 DSH 引擎后即可生效。",
                                actionTitle: "立即重启"
                            ) {
                                Task {
                                    let result = await host.restartRuntime()
                                    host.setPluginStatus(result)
                                    await host.refreshPluginState()
                                    await host.refreshRedteamStatus()
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                    pluginSecurityNoticeSection

                    Section {
                        Picker("插件视图", selection: $section) {
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

                    if isInstalling {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("正在下载、校验依赖并写入 DSH Profile…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let status = host.pluginStatus, !status.isEmpty {
                        Section("插件操作状态") {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("探索与设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if rootMode == .plugins {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                await host.refreshPluginState()
                                await host.refreshRedteamStatus()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(host.state != .ready || isInstalling)
                    }
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
                    title: Text("安装 / 更新第三方插件代码？"),
                    message: Text("插件代码将在 DSH Node 进程中运行，可访问应用沙盒和网络。支持已安装插件就地安全更新（失败自动回滚）。仅继续安装你已审阅并信任的插件。"),
                    primaryButton: .default(Text("继续安装")) {
                        isInstalling = true
                        Task {
                            defer { isInstalling = false }
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

    private var pluginSecurityNoticeSection: some View {
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

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        DSStatusBadge(
                            host.redteamStatus.storeReady ? "SQLite 事实库就绪" : "事实库未加载",
                            color: host.redteamStatus.storeReady ? DSTheme.success : .secondary
                        )
                        DSStatusBadge("已挂载 \(host.redteamStatus.toolCount) 工具", color: DSTheme.brand)
                        DSStatusBadge("沙盒补丁区可写", color: DSTheme.success)
                        if host.redteamStatus.skillCount > 0 {
                            DSStatusBadge("\(host.redteamStatus.skillCount) 演练技能", color: .indigo)
                        }
                    }
                }

                Text("iOS 已在沙盒内挂载独立可写的宿主镜像（支持 dsh-purge-safe 补丁应用与还原、提示词覆盖、规则集、RedTeam SQLite、工具、技能与 Web 演练台）；敏感工具与文件修改仍受 iOS 会话权限保护。")
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
                    Text("未安装 CallMeGuLab/dsh-purge-safe 插件")
                        .font(.subheadline.weight(.semibold))
                    Text("安装后可启用沙盒补丁清洗、提示词覆盖、规则集、RedTeam 工具、SQLite 事实库、技能与 Web 演练台；每个 Bot 的权限分别配置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    pendingInstall = .github("https://github.com/CallMeGuLab/dsh-purge-safe")
                } label: {
                    Label("一键安装 CallMeGuLab/dsh-purge-safe", systemImage: "arrow.down.circle.fill")
                }
                .disabled(host.state != .ready)
            }
        }

        Section("已安装插件 (\(host.installedPlugins.count))") {
            if host.installedPlugins.isEmpty {
                DSEmptyStateView(
                    icon: "shippingbox",
                    title: "还没有安装第三方插件",
                    subtitle: "从「发现」浏览索引，或在下方直接输入 GitHub 仓库地址安装。"
                )
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
                showFolderPicker = true
            } label: {
                Label("从本地文件夹导入 DSH Bundle", systemImage: "folder")
            }
            .disabled(isInstalling || host.state != .ready)
        }

        Section("从 GitHub 仓库直接安装 / 更新") {
            TextField("https://github.com/owner/repo 或 owner/repo@branch", text: $githubRepoURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button {
                let target = githubRepoURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { return }
                pendingInstall = .github(target)
            } label: {
                Label(isInstalling ? "正在安装…" : "下载并安装 / 更新 GitHub 插件", systemImage: "arrow.down.circle")
            }
            .disabled(isInstalling || githubRepoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.state != .ready)
            Text("支持仓库地址、分支（/tree/分支）、Release 标签（/releases/tag/v1.0）及已安装插件的就地原子更新（如 CallMeGuLab/dsh-purge-safe）。")
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
                    Text("请先切换到“索引源”启用一个插件目录。")
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

            Section("可用索引源") {
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
                                if source.builtIn {
                                    Text("第三方").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                                }
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

            Section("添加自定义 HTTPS 索引源") {
                TextField("https://example.com/index.json", text: $newSourceURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("添加索引源") {
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
    @State private var auditLoading = false
    @State private var auditRiskLevel: String = ""
    @State private var auditFileCount: Int = 0
    @State private var auditTotalKB: Int = 0
    @State private var auditDshEngine: String = ""
    @State private var auditDshCompatible: Bool = true
    @State private var auditFindings: [String] = []
    @State private var auditError: String = ""

    public init(host: LocalAgentHost, pluginId: String) {
        self.host = host
        self.pluginId = pluginId
    }

    private var plugin: DSHInstalledPlugin? {
        host.installedPlugins.first(where: { $0.id == pluginId })
    }

    private var riskBadge: (label: String, color: Color) {
        switch auditRiskLevel {
        case "elevated": return ("需留意权限", DSTheme.warning)
        case "standard": return ("常规网络能力", DSTheme.brand)
        case "low": return ("低风险纯沙盒", DSTheme.success)
        default: return ("待体检", .secondary)
        }
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

                Section("安全与健康体检") {
                    if auditLoading {
                        ProgressView("正在扫描插件代码与依赖契约…")
                    } else if !auditError.isEmpty {
                        Text(auditError).font(.caption).foregroundStyle(.secondary)
                    } else if !auditRiskLevel.isEmpty {
                        LabeledContent("静态风险评级") {
                            DSStatusBadge(riskBadge.label, color: riskBadge.color)
                        }
                        LabeledContent("DSH 引擎契约", value: "\(auditDshEngine) · \(auditDshCompatible ? "兼容" : "不兼容")")
                        LabeledContent("文件数 / 磁盘占用", value: "\(auditFileCount) 个文件 · \(auditTotalKB) KB")
                        if auditFindings.isEmpty {
                            Text("未检出子进程、动态求值或网络调用特征。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(auditFindings, id: \.self) { finding in
                                Text("• \(finding)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        Task { await runAudit(name: plugin.name) }
                    } label: {
                        Label("重新执行安全体检", systemImage: "checkmark.shield")
                    }
                    .disabled(auditLoading)
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
        .task(id: plugin?.name) {
            if let name = plugin?.name {
                await runAudit(name: name)
            }
        }
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

    private func runAudit(name: String) async {
        guard let rpc = host.rpc() else { return }
        auditLoading = true
        auditError = ""
        defer { auditLoading = false }
        do {
            let res = try await rpc.request("plugins.audit", params: ["name": name], timeoutSeconds: 15)
            auditRiskLevel = res["riskLevel"] as? String ?? "low"
            auditFileCount = res["fileCount"] as? Int ?? 0
            auditTotalKB = res["totalKB"] as? Int ?? 0
            auditDshEngine = res["dshEngine"] as? String ?? "未声明"
            auditDshCompatible = res["dshCompatible"] as? Bool ?? true
            auditFindings = res["findings"] as? [String] ?? []
        } catch {
            auditError = "安全体检失败：\(error.localizedDescription)"
        }
    }
}
