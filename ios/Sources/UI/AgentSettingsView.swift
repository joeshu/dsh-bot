import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Dedicated engine, model service, global capabilities, and experimental features settings view.
public struct AgentSettingsView: View {
    @ObservedObject var host: LocalAgentHost

    public init(host: LocalAgentHost) {
        self.host = host
    }

    public var body: some View {
        NavigationStack {
            Form {
                AgentSettingsFormSections(host: host)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("引擎与系统设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Reusable form sections for Model Providers, Keychain API keys, Global Agent Capabilities,
/// Experimental Features, and Runtime Diagnostics & Backup.
public struct AgentSettingsFormSections: View {
    @ObservedObject var host: LocalAgentHost
    @State private var apiKey = ""
    @State private var status = ""
    @State private var keyConfigured = false

    public init(host: LocalAgentHost) {
        self.host = host
    }

    public var body: some View {
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
            TextField("HTTPS Base URL", text: $host.apiBaseURL)
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
                        Task { keyConfigured = await host.hasSavedAPIKey() }
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
            Text("官方 DeepSeek 地址会自动映射至 Anthropic 兼容路径；API Key 按服务域名隔离存储在 iOS Keychain。")
        }

        Section("智能体全局能力") {
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
        }

        Section("实验性能力与界面偏好") {
            NavigationLink {
                ExperimentalFeaturesView(host: host)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.indigo.opacity(0.14))
                            .frame(width: 34, height: 34)
                        Image(systemName: "flask.fill")
                            .foregroundStyle(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("实验性功能与外部会话导入")
                            .font(.subheadline.weight(.semibold))
                        Text("自动授权审查、会话诊断统计、DeepSeek 对话记录导入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("消息气泡布局（关闭则为文档流）", isOn: $host.useBubbleLayout)
            Toggle("推理模型深度思考默认折叠", isOn: $host.collapseThinkingByDefault)
        }

        Section("运行时诊断与配置备份") {
            LabeledContent("应用版本", value: "\(host.appVersion) (\(host.buildNumber))")
            LabeledContent("内嵌引擎", value: host.embeddedRuntimeLabel ?? "Node.js + DSH 0.2.2-rc.5")
            LabeledContent("Web 工作台", value: "Loopback 认证端口（支持 dsh-client-ui-*）")
            LabeledContent(
                "本地 SQLite 存储",
                value: ByteCountFormatter.string(fromByteCount: host.sqliteDatabaseSizeBytes(), countStyle: .file)
            )

            Button {
                status = "正在重启 DSH 引擎…"
                Task {
                    status = await host.restartRuntime()
                }
            } label: {
                Label("重启 DSH 引擎", systemImage: "power.circle")
            }

            Button {
                Task {
                    do {
                        guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
                        let info = try await rpc.request("agent.info")
                        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                        #if canImport(UIKit)
                        UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
                        #endif
                        status = "已复制运行时诊断 JSON 到剪贴板。"
                        DSHaptics.notify(.success)
                    } catch {
                        status = error.localizedDescription
                    }
                }
            } label: {
                Label("复制运行时诊断 JSON", systemImage: "doc.on.doc")
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
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Color.clear
            .frame(height: 0)
            .listRowBackground(Color.clear)
            .task { keyConfigured = await host.hasSavedAPIKey() }
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

    private func capabilityRow(icon: String, color: Color, title: String, subtitle: String, enabled: Bool) -> some View {
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
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            DSStatusBadge(enabled ? "已开启" : "已停用", color: enabled ? DSTheme.success : .secondary)
        }
    }
}
