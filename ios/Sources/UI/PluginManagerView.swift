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
    case local(URL)

    var id: String {
        switch self {
        case .catalog(let plugin): return "catalog:\(plugin.id)"
        case .local(let url): return "local:\(url.path)"
        }
    }
}

public struct PluginManagerView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var section: PluginManagerSection = .installed
    @State private var searchText = ""
    @State private var newSourceURL = ""
    @State private var showFolderPicker = false
    @State private var pendingInstall: PendingPluginInstall?

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("第三方插件由其作者维护，DS Bot 不审核插件代码。插件在本机 DSH Node 进程内运行，可访问应用沙盒和网络。只安装你信任的来源。")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("iOS 安装会检查 DSH bundle、平台声明、依赖和本机二进制；不会执行 npm 安装脚本。检查不能代替对作者和代码的信任判断。")
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
            .navigationTitle("插件")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await host.refreshPluginState() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(host.state != .ready)
                }
            }
            .task {
                await host.refreshPluginState()
                if host.pluginSources.contains(where: { $0.enabled }) {
                    await host.discoverPlugins()
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
                            case .local(let url): await host.installLocalPlugin(from: url)
                            }
                        }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        Section("内置能力") {
            if let label = host.embeddedRuntimeLabel { LabeledContent("内嵌引擎", value: label) }
            LabeledContent("网页抓取", value: "每次访问需批准")
            Toggle("启用 DeepSeek 网页搜索", isOn: $host.webSearchEnabled)
                .disabled(!host.usesOfficialModels)
            Text(host.usesOfficialModels ? "每次搜索前确认关键词，可能产生 API 费用。" : "网页搜索需要 DeepSeek 官方 API 地址。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("启用子智能体", isOn: $host.subagentEnabled)
            Text("最多一层、同时运行一个子智能体。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle(isOn: Binding(
                            get: { host.installedPlugins.first(where: { $0.id == plugin.id })?.desiredEnabled ?? plugin.desiredEnabled },
                            set: { value in Task { await host.setPluginEnabled(plugin, enabled: value) } }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plugin.name).font(.subheadline.weight(.semibold))
                                if plugin.desiredEnabled && !plugin.enabled {
                                    Text(host.isDSHRecoveryMode ? "恢复模式下未加载" : "等待生效")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("版本 \(plugin.version) · \(plugin.compatibilityLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(host.isDSHRecoveryMode && !plugin.desiredEnabled)
                        Button("卸载", role: .destructive) {
                            Task { await host.removePlugin(plugin) }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 3)
                }
            }
            Button {
                section = .discover
                showFolderPicker = true
            } label: {
                Label("从本地文件夹安装", systemImage: "folder")
            }
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
                    Text("没有匹配结果。可刷新索引或更换来源。")
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
                Text("一次启用一个插件索引源。新添加的地址默认关闭；关闭所有来源后，发现页不会联网读取插件目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("示例索引源") {
                ForEach(host.pluginSources) { source in
                    Toggle(isOn: Binding(
                        get: { host.pluginSources.first(where: { $0.id == source.id })?.enabled ?? source.enabled },
                        set: { value in Task { await host.setPluginSourceEnabled(id: source.id, enabled: value) } }
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
