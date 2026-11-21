import SwiftUI

public struct SubagentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    @State private var maxDepth: Int
    @State private var maxActive: Int
    @State private var modelSelection: Bool
    @State private var status = ""
    @State private var isSaving = false

    @MainActor
    public init(host: LocalAgentHost) {
        self.host = host
        _maxDepth = State(initialValue: host.subagentMaxDepth)
        _maxActive = State(initialValue: host.subagentMaxActive)
        _modelSelection = State(initialValue: host.subagentModelSelection)
    }

    public var body: some View {
        Form {
            Section {
                Toggle("启用子智能体工具", isOn: $host.subagentEnabled)
            }

            Section {
                Stepper("最大递归深度：\(maxDepth)", value: $maxDepth, in: 0...3)
                Stepper("并行数量上限：\(maxActive)", value: $maxActive, in: 1...8)
            } header: {
                Text("运行限制")
            } footer: {
                Text("深度 0 禁用子智能体，1 只允许主 Agent 创建。达到数量上限时不再启动新的子智能体，主 Agent 不计入。")
            }

            Section {
                Toggle("允许 Agent 为子智能体选择模型", isOn: $modelSelection)
            } header: {
                Text("模型选择")
            } footer: {
                Text("关闭时子智能体使用默认模型或继承父 Agent 的模型。")
            }

            if !status.isEmpty {
                Section {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("子智能体")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "保存中…" : "保存") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        host.subagentMaxDepth = maxDepth
                        host.subagentMaxActive = maxActive
                        host.subagentModelSelection = modelSelection
                        if maxDepth == 0 { host.subagentEnabled = false }
                        status = await host.applyLiveRuntimeConfig()
                        DSHaptics.notify(.success)
                    }
                }
                .disabled(isSaving)
            }
        }
    }
}

public struct WebSearchSettingsView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var searchCount: Int
    @State private var sendOriginalQuestion: Bool
    @State private var status = ""
    @State private var isSaving = false

    @MainActor
    public init(host: LocalAgentHost) {
        self.host = host
        _searchCount = State(initialValue: host.webSearchCount)
        _sendOriginalQuestion = State(initialValue: host.webSearchSendOriginalQuestion)
    }

    public var body: some View {
        Form {
            Section("网页搜索提供方") {
                Toggle("启用 DeepSeek 网页搜索", isOn: $host.webSearchEnabled)
                    .disabled(!host.usesOfficialModels)
                LabeledContent("网页抓取", value: "每次访问需批准")
                if !host.usesOfficialModels {
                    Text("DeepSeek 网页搜索需要官方 API 地址（api.deepseek.com）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper("单次返回条数：\(searchCount)", value: $searchCount, in: 1...20)
                Toggle("发送原始问题上下文", isOn: $sendOriginalQuestion)
            } header: {
                Text("搜索参数与隐私")
            } footer: {
                Text("默认关闭「发送原始问题上下文」。开启后，原始问题会压缩空白并截取前 128 个字符；审批卡片会展示实际发送的上下文。")
            }

            if !status.isEmpty {
                Section {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("网页搜索与获取")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "保存中…" : "保存") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        host.webSearchCount = searchCount
                        host.webSearchSendOriginalQuestion = sendOriginalQuestion
                        status = await host.applyLiveRuntimeConfig()
                        DSHaptics.notify(.success)
                    }
                }
                .disabled(isSaving)
            }
        }
    }
}

public struct SmartRecommendationsSettingsView: View {
    @ObservedObject var host: LocalAgentHost

    public var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.indigo.opacity(0.14))
                            .frame(width: 48, height: 48)
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.title2)
                            .foregroundStyle(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("个性化推荐与操作卡片").font(.headline)
                        Text("v\(host.appVersion)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Toggle("", isOn: $host.smartActionCardsEnabled).labelsHidden()
                }
                Text("在助手回答下方自动展示上下文操作卡片：长回复一键压缩或存为记忆、代码片段一键存为工作区文件、以及旁白追问快捷入口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                componentRow(title: "操作卡片显示", detail: "在回答末尾展示可执行操作卡片", active: host.smartActionCardsEnabled)
                componentRow(title: "记忆与压缩建议", detail: "长对话自动提示存入 Bot 记忆或 /compact 压缩上下文", active: host.smartActionCardsEnabled)
                componentRow(title: "工作区与沙盒联动", detail: "检测到代码片段时一键导出到工作区文件", active: host.smartActionCardsEnabled)
            } header: {
                Text("包含的组件")
            } footer: {
                Text("共 3 个 · \(host.smartActionCardsEnabled ? 3 : 0) 运行中")
            }

            Section("高级") {
                LabeledContent("包名", value: "@dsbot/ios-smart-action-cards")
                LabeledContent("代码来源", value: "内置")
                LabeledContent("当前版本", value: host.appVersion)
            }
        }
        .navigationTitle("个性化推荐")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func componentRow(title: String, detail: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? DSTheme.success : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(active ? "运行中" : "已关闭")
                    .font(.caption)
                    .foregroundStyle(active ? DSTheme.success : .secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
