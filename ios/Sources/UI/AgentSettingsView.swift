import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Dedicated Tab 4 root view ("设置") following Apple HIG hierarchical IA:
/// zero stacked segmented pickers, 4 high-frequency core entries, and clean
/// drill-down pages for Model Credentials, Plugins & RedTeam, Budget, Experimental,
/// and Runtime Diagnostics / Safe Mode.
public struct SettingsAndExploreTabView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var memoryGovernor = MemoryGovernor.shared
    @ObservedObject private var budgetGovernor = CostBudgetGovernor.shared
    @ObservedObject private var safeModeGuard = SafeModeBootGuard.shared
    @State private var keyConfigured = false

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var activePluginCount: Int {
        host.installedPlugins.filter(\.enabled).count
    }

    private var hasPendingPluginRestart: Bool {
        !host.isDSHRecoveryMode && host.installedPlugins.contains(where: { $0.desiredEnabled != $0.enabled })
    }

    public var body: some View {
        NavigationStack {
            List {
                if safeModeGuard.isSafeModeRequested || host.isDSHRecoveryMode {
                    Section {
                        DSBannerCard(
                            icon: "shield.lefthalf.filled.badge.checkmark",
                            tint: DSTheme.warning,
                            message: "当前处于安全恢复模式（第三方插件已暂停），可先排查或禁用异常插件后重启恢复。",
                            actionTitle: "重置并重启"
                        ) {
                            safeModeGuard.resetCrashCounter()
                            Task { _ = await host.restartRuntime() }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                Section("高频核心配置") {
                    NavigationLink {
                        ModelServiceSettingsView(host: host)
                    } label: {
                        settingsRow(
                            icon: "key.fill",
                            color: keyConfigured ? DSTheme.success : DSTheme.warning,
                            title: "模型服务与 Keychain 凭据",
                            subtitle: host.usesOfficialModels ? "DeepSeek 官方 · Anthropic 兼容通道" : host.apiBaseURL,
                            badge: keyConfigured ? "已配置" : "未配置",
                            badgeColor: keyConfigured ? DSTheme.success : DSTheme.warning
                        )
                    }

                    NavigationLink {
                        PluginManagerView(host: host)
                    } label: {
                        settingsRow(
                            icon: "puzzlepiece.extension.fill",
                            color: .indigo,
                            title: "插件生态与红队演练宿主",
                            subtitle: host.redteamStatus.installed
                                ? "已安装 \(host.installedPlugins.count) 个插件 · 红队工具 \(host.redteamStatus.toolCount) 项"
                                : "已启用 \(activePluginCount) / \(host.installedPlugins.count) 个 Cordis 插件",
                            badge: hasPendingPluginRestart ? "需重启" : (host.redteamModeEnabled ? "红队就绪" : nil),
                            badgeColor: hasPendingPluginRestart ? DSTheme.warning : DSTheme.danger
                        )
                    }

                    NavigationLink {
                        ConnectorsAndUsageView(host: host)
                    } label: {
                        let spendText = CostDisplayState.exact(budgetGovernor.todayEstimatedSpendUSD).formattedLabel
                        settingsRow(
                            icon: "chart.bar.xaxis",
                            color: DSTheme.brand,
                            title: "用量账本与预算熔断",
                            subtitle: budgetGovernor.dailyBudgetUSD > 0
                                ? "今日估算 \(spendText) / 上限 $\(String(format: "%.2f", budgetGovernor.dailyBudgetUSD))"
                                : "今日估算 \(spendText) · 未设每日硬上限",
                            badge: budgetGovernor.budgetAction == .stop ? "已熔断" : nil,
                            badgeColor: DSTheme.danger
                        )
                    }
                }

                Section("智能体全局能力与策略") {
                    NavigationLink {
                        SubagentSettingsView(host: host)
                    } label: {
                        capabilityRow(
                            icon: "person.2.fill",
                            color: DSTheme.brand,
                            title: "子智能体 (Subagent)",
                            subtitle: "递归深度 \(host.subagentMaxDepth) · 并行上限 \(host.subagentMaxActive)",
                            enabled: host.subagentEnabled
                        )
                    }

                    NavigationLink {
                        WebSearchSettingsView(host: host)
                    } label: {
                        capabilityRow(
                            icon: "magnifyingglass.circle.fill",
                            color: .blue,
                            title: "网页搜索与抓取",
                            subtitle: "单次 \(host.webSearchCount) 条 · 每次查询前逐次审批",
                            enabled: host.webSearchEnabled && host.usesOfficialModels
                        )
                    }

                    NavigationLink {
                        SmartRecommendationsSettingsView(host: host)
                    } label: {
                        capabilityRow(
                            icon: "sparkles.rectangle.stack.fill",
                            color: .indigo,
                            title: "上下文操作推荐卡片",
                            subtitle: "回答末尾自动浮现旁白追问、存记忆、压缩与导出代码",
                            enabled: host.smartActionCardsEnabled
                        )
                    }

                    NavigationLink {
                        AutoReviewDetailView(host: host)
                    } label: {
                        capabilityRow(
                            icon: "checkmark.shield.fill",
                            color: .teal,
                            title: "自动授权审查",
                            subtitle: "低风险工具调用自动放行并记录审计日志",
                            enabled: host.autoReviewEnabled
                        )
                    }

                    NavigationLink {
                        DiagnosticsFeatureDetailView(host: host)
                    } label: {
                        capabilityRow(
                            icon: "doc.text.magnifyingglass",
                            color: .purple,
                            title: "会话数据诊断与统计",
                            subtitle: "在对话顶部开启消息分布、估算 Token 与首字延迟面板",
                            enabled: host.sessionDiagnosticsEnabled
                        )
                    }
                }

                Section("阅读与交互偏好") {
                    Toggle("消息气泡布局（关闭则为文档流）", isOn: $host.useBubbleLayout)
                    Toggle("推理模型深度思考默认折叠", isOn: $host.collapseThinkingByDefault)
                }

                Section("系统诊断、DevTools 与备份") {
                    NavigationLink {
                        RuntimeDiagnosticsAndBackupView(host: host)
                    } label: {
                        let snap = memoryGovernor.snapshot
                        settingsRow(
                            icon: "stethoscope",
                            color: snap.tier == .normal ? DSTheme.success : DSTheme.warning,
                            title: "系统诊断、安全模式与配置备份",
                            subtitle: String(
                                format: "v%@ · %.0f MB / V8 %d MB · SQLite %@",
                                host.appVersion,
                                snap.physFootprintMB,
                                snap.nodeHeapLimitMB,
                                ByteCountFormatter.string(fromByteCount: host.sqliteDatabaseSizeBytes(), countStyle: .file)
                            ),
                            badge: snap.tier.displayName,
                            badgeColor: snap.tier == .normal ? DSTheme.success : DSTheme.warning
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .task {
                keyConfigured = await host.hasSavedAPIKey()
                memoryGovernor.refreshSnapshot()
            }
        }
    }

    private func settingsRow(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        badge: String?,
        badgeColor: Color
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let badge {
                DSStatusBadge(badge, color: badgeColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func capabilityRow(icon: String, color: Color, title: String, subtitle: String, enabled: Bool) -> some View {
        settingsRow(
            icon: icon,
            color: color,
            title: title,
            subtitle: subtitle,
            badge: enabled ? "已开启" : "已停用",
            badgeColor: enabled ? DSTheme.success : .secondary
        )
    }
}

/// Dedicated Model Service & Keychain Credentials screen.
public struct ModelServiceSettingsView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var providerStore = ProviderProfileStore.shared
    @State private var apiKey = ""
    @State private var status = ""
    @State private var keyConfigured = false
    @State private var modelSearch = ""
    @State private var editingProfile: ProviderProfile?

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var displayedEndpointModels: [String] {
        let ordered = host.orderedAvailableModels.filter { host.models.contains($0) || !host.usesOfficialModels }
        let q = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? ordered : ordered.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder
    private func modelRow(modelId: String, isSelected: Bool) -> some View {
        let isFav = host.isFavoriteModel(modelId)
        HStack(spacing: 10) {
            Button {
                host.toggleFavoriteModel(modelId)
                DSHaptics.impact(.light)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .foregroundStyle(isFav ? .orange : .secondary.opacity(0.6))
            }
            .buttonStyle(.plain)

            Button {
                host.applyModelToAllBots(modelId)
                let trimmed = host.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if let existing = providerStore.profiles.first(where: { $0.apiBaseURL == trimmed }) {
                    providerStore.upsert(ProviderProfile(
                        id: existing.id,
                        name: existing.name,
                        apiBaseURL: existing.apiBaseURL,
                        defaultModel: modelId
                    ))
                }
                status = "已将「\(modelId)」设为默认模型并同步应用到全部智能体。"
                DSHaptics.notify(.success)
            } label: {
                HStack {
                    Text(modelId)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                    if isSelected {
                        DSStatusBadge("当前默认", color: DSTheme.brand, icon: "checkmark.circle.fill")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("当前地址密钥") {
                    DSStatusBadge(
                        keyConfigured ? "Keychain 已配置" : "未配置密钥",
                        color: keyConfigured ? DSTheme.success : DSTheme.warning,
                        icon: keyConfigured ? "key.fill" : "exclamationmark.triangle.fill"
                    )
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        providerPresetButton("DeepSeek 官方", url: ModelProvider.defaultAddress)
                        providerPresetButton("OpenRouter", url: "https://openrouter.ai/api")
                        providerPresetButton("智谱 Anthropic", url: "https://open.bigmodel.cn/api/anthropic")
                    }
                    .padding(.vertical, 2)
                }
                TextField("API Base URL（支持 HTTP / HTTPS）", text: $host.apiBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: host.apiBaseURL) { _ in
                        apiKey = ""
                        status = ""
                        Task { keyConfigured = await host.hasSavedAPIKey() }
                    }
                if !host.usesOfficialModels {
                    Button("恢复官方地址（api.deepseek.com）") {
                        host.apiBaseURL = ModelProvider.defaultAddress
                    }
                    .font(.caption)
                    Text("DSH 自定义服务需兼容 Anthropic Messages API；模型 ID 可在智能体设置中手动填写。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("服务支持工具调用", isOn: $host.customTools)
                }
                SecureField("输入当前服务地址的 API Key", text: $apiKey)
                HStack(spacing: 12) {
                    Button("保存至 Keychain") {
                        do {
                            try host.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            apiKey = ""
                            status = "已为当前服务地址安全保存密钥至 iOS Keychain。"
                            DSHaptics.notify(.success)
                            Task {
                                keyConfigured = await host.hasSavedAPIKey()
                                await host.syncProviderModelCatalogToDSH()
                            }
                        } catch {
                            status = error.localizedDescription
                            DSHaptics.notify(.error)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("测试连接并拉取模型") {
                        status = "正在连接并读取服务模型…"
                        Task {
                            do {
                                let result = try await host.refreshModels()
                                status = "连接成功：读到 \(result.count) 个模型，首包耗时 \(result.latency) ms。"
                                DSHaptics.notify(.success)
                            } catch {
                                status = "\(error.localizedDescription) 自定义服务可在智能体设置手填模型 ID。"
                                DSHaptics.notify(.warning)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption.weight(.semibold))
            } header: {
                Text("模型服务与 Keychain 凭据")
            } footer: {
                Text("官方 DeepSeek 地址会自动映射至 Anthropic 兼容路径；API Key 按服务域名隔离存储在 iOS Keychain（AfterFirstUnlockThisDeviceOnly）。")
            }

            if !status.isEmpty {
                Section("操作状态") {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !host.models.isEmpty {
                Section {
                    if host.models.count > 5 {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("筛选模型 ID…", text: $modelSearch)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !modelSearch.isEmpty {
                                Button {
                                    modelSearch = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    let currentMainModel = host.bots.first(where: \.isMain)?.model ?? host.bots.first?.model ?? ""
                    ForEach(displayedEndpointModels, id: \.self) { (modelId: String) in
                        modelRow(modelId: modelId, isSelected: currentMainModel == modelId)
                    }
                } header: {
                    Text("当前端点已拉取模型（\(host.models.count) 个 · 点星标置顶 / 点名称设为默认）")
                } footer: {
                    Text("拉取到的模型列表会按服务地址自动缓存并同步至 DSH Web 工作台，重启 App 后在对话顶部与智能体设置中均可直接选择。")
                }
            }

            Section("已保存的多端点档案（按域名隔离 Keychain）") {
                ForEach(providerStore.profiles) { profile in
                    let active = host.apiBaseURL == profile.apiBaseURL
                    Button {
                        host.apiBaseURL = profile.apiBaseURL
                        DSHaptics.impact(.light)
                        if !profile.defaultModel.isEmpty {
                            host.applyModelToAllBots(profile.defaultModel)
                            status = "已切换至档案「\(profile.name)」，默认模型：\(profile.defaultModel)"
                        } else {
                            status = "已切换至档案「\(profile.name)」"
                        }
                        if host.models.isEmpty {
                            Task {
                                if let res = try? await host.refreshModels() {
                                    status = "已切换至「\(profile.name)」，自动拉取到 \(res.count) 个模型并同步至 Web 工作台。"
                                }
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(profile.defaultModel.isEmpty ? profile.apiBaseURL : "\(profile.apiBaseURL) · 默认：\(profile.defaultModel)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if active {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DSTheme.brand)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if profile.id != "deepseek-official" {
                            Button(role: .destructive) {
                                providerStore.delete(id: profile.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        Button {
                            editingProfile = profile
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(DSTheme.brand)
                    }
                }
                Button {
                    let trimmed = host.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let hostName = URL(string: trimmed)?.host ?? "自定义端点"
                    let newProfile = ProviderProfile(
                        name: hostName,
                        apiBaseURL: trimmed,
                        defaultModel: host.models.first ?? ModelProvider.defaultModel,
                        supportsTools: host.customTools
                    )
                    providerStore.upsert(newProfile)
                    editingProfile = newProfile
                    status = "已将 \(hostName) 保存到端点档案列表，可继续自定义名称与默认模型。"
                    DSHaptics.notify(.success)
                } label: {
                    Label("保存当前地址为新档案", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .disabled(host.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("模型服务与凭据")
        .navigationBarTitleDisplayMode(.inline)
        .task { keyConfigured = await host.hasSavedAPIKey() }
        .sheet(item: $editingProfile) { target in
            EditProviderProfileSheet(profile: target, host: host) { updated in
                providerStore.upsert(updated)
                status = "已更新档案「\(updated.name)」。"
                DSHaptics.notify(.success)
            }
        }
    }

    private func providerPresetButton(_ title: String, url: String) -> some View {
        let isSelected = host.apiBaseURL == url
        return Button {
            host.apiBaseURL = url
            DSHaptics.impact(.light)
        } label: {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? DSTheme.brand : DSTheme.surfaceSecondary)
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct EditProviderProfileSheet: View {
    let profile: ProviderProfile
    @ObservedObject var host: LocalAgentHost
    let onSave: (ProviderProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var apiBaseURL: String
    @State private var defaultModel: String
    @State private var supportsTools: Bool

    init(profile: ProviderProfile, host: LocalAgentHost, onSave: @escaping (ProviderProfile) -> Void) {
        self.profile = profile
        self.host = host
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _apiBaseURL = State(initialValue: profile.apiBaseURL)
        _defaultModel = State(initialValue: profile.defaultModel)
        _supportsTools = State(initialValue: profile.supportsTools)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("端点档案信息") {
                    TextField("档案名称（如 香港自建 V4 网关）", text: $name)
                    TextField("API Base URL", text: $apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(profile.id == "deepseek-official")
                    ModelSelectionView(host: host, model: $defaultModel, endpointURL: apiBaseURL)
                    Toggle("支持工具调用 (Tool Calling)", isOn: $supportsTools)
                }
            }
            .navigationTitle("编辑端点档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanName.isEmpty, !cleanURL.isEmpty else { return }
                        onSave(ProviderProfile(
                            id: profile.id,
                            name: cleanName,
                            apiBaseURL: cleanURL,
                            defaultModel: defaultModel.trimmingCharacters(in: .whitespacesAndNewlines),
                            protocolKind: profile.protocolKind,
                            supportsTools: supportsTools
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Dedicated Runtime Diagnostics, Jetsam Telemetry, Safe Mode & Workspace Backup screen.
public struct RuntimeDiagnosticsAndBackupView: View {
    @ObservedObject var host: LocalAgentHost
    @ObservedObject private var memoryGovernor = MemoryGovernor.shared
    @ObservedObject private var safeModeGuard = SafeModeBootGuard.shared
    @State private var status = ""

    public init(host: LocalAgentHost) {
        self.host = host
    }

    public var body: some View {
        let snap = memoryGovernor.snapshot
        Form {
            Section("运行态与 Jetsam 内存遥测") {
                LabeledContent("应用版本", value: "\(host.appVersion) (\(host.buildNumber))")
                LabeledContent("内嵌引擎", value: host.embeddedRuntimeLabel ?? "Node.js + DSH 0.2.2-rc.5")
                LabeledContent("物理内存 / 压力档位", value: String(format: "%.1f MB (%@)", snap.physFootprintMB, snap.tier.displayName))
                LabeledContent("剩余可用配额", value: snap.availableMB > 0 ? String(format: "%.0f MB", snap.availableMB) : "模拟器/未知")
                LabeledContent("V8 Worker 堆上限", value: "\(snap.nodeHeapLimitMB) MB")
                LabeledContent("活跃文件描述符 (FD)", value: "\(snap.openFDCount)")
                LabeledContent("MetricKit 遥测", value: snap.lastMetricSummary)
                LabeledContent("本地 SQLite 存储", value: ByteCountFormatter.string(fromByteCount: host.sqliteDatabaseSizeBytes(), countStyle: .file))
                LabeledContent("Web 工作台", value: "Loopback 认证端口（支持 dsh-client-ui-*）")
                Button {
                    memoryGovernor.refreshSnapshot()
                    host.trimMemoryCachesForPressure()
                    status = "已刷新内存遥测，并回收渲染缓存与非活跃会话内存。"
                } label: {
                    Label("刷新遥测并清理渲染缓存", systemImage: "arrow.clockwise")
                }

                NavigationLink {
                    BackendDevToolsInspectorView(host: host)
                } label: {
                    Label("打开后端 DevTools 与 Cordis 调试器", systemImage: "ladybug.fill")
                }
            }

            Section("安全模式与恢复控制") {
                LabeledContent("连续未完成启动计数", value: "\(safeModeGuard.consecutiveBootCrashes)")
                LabeledContent("当前安全恢复态", value: (host.isDSHRecoveryMode || safeModeGuard.isSafeModeRequested) ? "已开启" : "正常")

                Button {
                    status = "正在重启 DSH 引擎…"
                    Task { status = await host.restartRuntime() }
                } label: {
                    Label("重启 DSH 引擎", systemImage: "power.circle")
                }

                Button {
                    safeModeGuard.requestSafeModeOnNextBoot()
                    status = "已预约安全模式，正在重启…"
                    Task { status = await host.restartRuntime() }
                } label: {
                    Label("以安全模式重启（暂不加载第三方插件）", systemImage: "shield.lefthalf.filled")
                }

                if safeModeGuard.consecutiveBootCrashes > 0 || safeModeGuard.isSafeModeRequested {
                    Button("重置崩溃计数并恢复正常启动") {
                        safeModeGuard.resetCrashCounter()
                        status = "已重置崩溃计数，下次重启将恢复正常模式。"
                    }
                }
            }

            Section {
                Toggle("启用统一导航与多话题架构 (V2)", isOn: $host.unifiedNavigationV2)
            } header: {
                Text("页面重构灰度开关 (P2-02)")
            } footer: {
                Text("关闭后可安全回滚到经典会话列表视图，不会丢失已创建的话题与聊天记录，且始终保留 SessionAddress 地址校验与隐私边界保护。")
            }

            Section("脱敏诊断与配置备份") {
                Button {
                    Task {
                        do {
                            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                            let info = try await rpc.request("agent.info")
                            let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                            let rawJSON = String(decoding: data, as: UTF8.self)
                            #if canImport(UIKit)
                            UIPasteboard.general.string = SecretRedactor.redactCommonTokens(rawJSON)
                            #endif
                            status = "已复制脱敏运行时诊断 JSON 到剪贴板。"
                            DSHaptics.notify(.success)
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                } label: {
                    Label("复制运行时诊断 JSON（已脱敏）", systemImage: "doc.on.doc")
                }

                ShareLink(
                    item: host.exportWorkspaceBackupJSON(),
                    subject: Text("DS Bot 工作区配置备份"),
                    message: Text("包含智能体团队配置与服务地址（不含 Keychain 密钥）")
                ) {
                    Label("导出工作区配置备份 (JSON)", systemImage: "square.and.arrow.up")
                }
            }

            if !status.isEmpty {
                Section("操作状态") {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("系统诊断与备份")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { memoryGovernor.refreshSnapshot() }
    }
}

/// Backward-compatible wrapper preserving `AgentSettingsView` symbol.
public struct AgentSettingsView: View {
    @ObservedObject var host: LocalAgentHost

    public init(host: LocalAgentHost) {
        self.host = host
    }

    public var body: some View {
        SettingsAndExploreTabView(host: host)
    }
}
