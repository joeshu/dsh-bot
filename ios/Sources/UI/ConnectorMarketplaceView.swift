import SwiftUI

public struct ConnectorCatalogItem: Identifiable, Hashable {
    public enum AuthKind: String, Hashable {
        case none
        case oauth
        case key

        var badgeLabel: String {
            switch self {
            case .none: return "免认证即连"
            case .oauth: return "Token / OAuth"
            case .key: return "API Key"
            }
        }
    }

    public let id: String
    public let name: String
    public let category: String
    public let subtitle: String
    public let endpoint: String
    public let auth: AuthKind
    public let icon: String
    public let tintHex: UInt

    var tintColor: Color {
        Color(
            red: Double((tintHex >> 16) & 0xFF) / 255.0,
            green: Double((tintHex >> 8) & 0xFF) / 255.0,
            blue: Double(tintHex & 0xFF) / 255.0
        )
    }

    public static let categories: [(id: String, title: String)] = [
        ("all", "全部"),
        ("dev", "开发"),
        ("docs", "文档与资料"),
        ("work", "协作办公"),
        ("design", "设计"),
        ("data", "数据"),
        ("search", "搜索"),
        ("commerce", "商业")
    ]

    public static let catalog: [ConnectorCatalogItem] = [
        // 开发
        .init(id: "github", name: "GitHub", category: "dev", subtitle: "仓库、Issue 和拉取请求", endpoint: "https://api.githubcopilot.com/mcp/", auth: .oauth, icon: "chevron.left.forwardslash.chevron.right", tintHex: 0x1F2328),
        .init(id: "sentry", name: "Sentry", category: "dev", subtitle: "报错、链路和发布", endpoint: "https://mcp.sentry.dev/mcp", auth: .oauth, icon: "exclamationmark.triangle.fill", tintHex: 0x362D59),
        .init(id: "cloudflare", name: "Cloudflare", category: "dev", subtitle: "Workers、DNS 和账号资源", endpoint: "https://bindings.mcp.cloudflare.com/mcp", auth: .oauth, icon: "cloud.fill", tintHex: 0xF38020),
        .init(id: "vercel", name: "Vercel", category: "dev", subtitle: "项目、部署和日志", endpoint: "https://mcp.vercel.com", auth: .oauth, icon: "triangle.fill", tintHex: 0x111111),
        .init(id: "netlify", name: "Netlify", category: "dev", subtitle: "站点、部署和表单", endpoint: "https://netlify-mcp.netlify.app/mcp", auth: .oauth, icon: "globe.americas.fill", tintHex: 0x00C7B7),
        .init(id: "postman", name: "Postman", category: "dev", subtitle: "集合、请求和工作区", endpoint: "https://mcp.postman.com/mcp", auth: .oauth, icon: "paperplane.fill", tintHex: 0xFF6C37),

        // 文档与资料
        .init(id: "notion", name: "Notion", category: "docs", subtitle: "页面、数据库和知识库", endpoint: "https://mcp.notion.com/mcp", auth: .oauth, icon: "doc.text.fill", tintHex: 0x191919),
        .init(id: "dropbox", name: "Dropbox", category: "docs", subtitle: "文件和文件夹", endpoint: "https://mcp.dropbox.com/mcp", auth: .oauth, icon: "shippingbox.fill", tintHex: 0x0061FF),
        .init(id: "box", name: "Box", category: "docs", subtitle: "文件、文件夹和元数据", endpoint: "https://mcp.box.com", auth: .oauth, icon: "archivebox.fill", tintHex: 0x0061D5),
        .init(id: "deepwiki", name: "DeepWiki", category: "docs", subtitle: "开源代码仓库文档与架构解读", endpoint: "https://mcp.deepwiki.com/mcp", auth: .none, icon: "book.closed.fill", tintHex: 0x4F46E5),
        .init(id: "context7", name: "Context7", category: "docs", subtitle: "最新开发库文档与代码示例", endpoint: "https://mcp.context7.com/mcp", auth: .none, icon: "books.vertical.fill", tintHex: 0x0EA5E9),
        .init(id: "mslearn", name: "Microsoft Learn", category: "docs", subtitle: "微软官方文档与参考手册", endpoint: "https://learn.microsoft.com/api/mcp", auth: .none, icon: "graduationcap.fill", tintHex: 0x0078D4),
        .init(id: "cloudflare-docs", name: "Cloudflare Docs", category: "docs", subtitle: "Cloudflare 产品官方文档", endpoint: "https://docs.mcp.cloudflare.com/mcp", auth: .none, icon: "doc.plaintext.fill", tintHex: 0xF38020),

        // 协作办公
        .init(id: "linear", name: "Linear", category: "work", subtitle: "Issue、项目与迭代周期", endpoint: "https://mcp.linear.app/mcp", auth: .oauth, icon: "checklist", tintHex: 0x5E6AD2),
        .init(id: "atlassian", name: "Atlassian", category: "work", subtitle: "Jira 工单与 Confluence 文档", endpoint: "https://mcp.atlassian.com/v1/mcp", auth: .oauth, icon: "square.stack.3d.up.fill", tintHex: 0x0052CC),
        .init(id: "slack", name: "Slack", category: "work", subtitle: "频道与团队消息", endpoint: "https://mcp.slack.com/mcp", auth: .oauth, icon: "number.square.fill", tintHex: 0x4A154B),
        .init(id: "asana", name: "Asana", category: "work", subtitle: "任务、项目与工作区", endpoint: "https://mcp.asana.com/v2/mcp", auth: .oauth, icon: "circle.grid.3x3.fill", tintHex: 0xF06A6A),
        .init(id: "clickup", name: "ClickUp", category: "work", subtitle: "任务、列表与文档", endpoint: "https://mcp.clickup.com/mcp", auth: .oauth, icon: "checkmark.seal.fill", tintHex: 0x7B68EE),
        .init(id: "todoist", name: "Todoist", category: "work", subtitle: "待办事项与个人项目", endpoint: "https://ai.todoist.net/mcp", auth: .oauth, icon: "checkmark.circle.fill", tintHex: 0xE44332),
        .init(id: "monday", name: "monday.com", category: "work", subtitle: "看板、条目与工作流", endpoint: "https://mcp.monday.com/mcp", auth: .oauth, icon: "rectangle.3.group.fill", tintHex: 0xFF3D57),
        .init(id: "intercom", name: "Intercom", category: "work", subtitle: "客户会话、联系人与文章", endpoint: "https://mcp.intercom.com/mcp", auth: .oauth, icon: "bubble.left.and.bubble.right.fill", tintHex: 0x1F8DED),
        .init(id: "zapier", name: "Zapier", category: "work", subtitle: "自动化流程与跨应用操作", endpoint: "https://mcp.zapier.com/api/mcp/mcp", auth: .oauth, icon: "bolt.fill", tintHex: 0xFF4F00),
        .init(id: "hubspot", name: "HubSpot", category: "work", subtitle: "联系人、商机与工单", endpoint: "https://mcp.hubspot.com/", auth: .oauth, icon: "person.2.fill", tintHex: 0xFF7A59),
        .init(id: "attio", name: "Attio", category: "work", subtitle: "CRM 记录、列表与备注", endpoint: "https://mcp.attio.com/mcp", auth: .oauth, icon: "tray.full.fill", tintHex: 0x1C1C1E),

        // 设计
        .init(id: "figma", name: "Figma", category: "design", subtitle: "设计稿、组件与评论", endpoint: "https://mcp.figma.com/mcp", auth: .oauth, icon: "paintbrush.pointed.fill", tintHex: 0xA259FF),
        .init(id: "canva", name: "Canva", category: "design", subtitle: "设计素材、文件夹与导出", endpoint: "https://mcp.canva.com/mcp", auth: .oauth, icon: "wand.and.stars", tintHex: 0x00C4CC),
        .init(id: "miro", name: "Miro", category: "design", subtitle: "在线白板与协作画布", endpoint: "https://mcp.miro.com/", auth: .oauth, icon: "rectangle.on.rectangle.angled", tintHex: 0xFFD02F),
        .init(id: "webflow", name: "Webflow", category: "design", subtitle: "网站、页面与 CMS 内容", endpoint: "https://mcp.webflow.com/mcp", auth: .oauth, icon: "safari.fill", tintHex: 0x146EF5),
        .init(id: "wix", name: "Wix", category: "design", subtitle: "站点、页面与内容管理", endpoint: "https://mcp.wix.com/mcp", auth: .oauth, icon: "sparkles.rectangle.stack.fill", tintHex: 0x0C6EFC),

        // 数据
        .init(id: "supabase", name: "Supabase", category: "data", subtitle: "数据库、数据表与项目配置", endpoint: "https://mcp.supabase.com/mcp", auth: .oauth, icon: "cylinder.split.1x2.fill", tintHex: 0x3ECF8E),
        .init(id: "neon", name: "Neon", category: "data", subtitle: "Postgres 数据库与分支", endpoint: "https://mcp.neon.tech/mcp", auth: .oauth, icon: "externaldrive.connected.to.line.below.fill", tintHex: 0x00E599),
        .init(id: "airtable", name: "Airtable", category: "data", subtitle: "多维表格、数据表与记录", endpoint: "https://mcp.airtable.com/mcp", auth: .oauth, icon: "tablecells.fill", tintHex: 0x18BFFF),
        .init(id: "huggingface", name: "Hugging Face", category: "data", subtitle: "模型、数据集与 Spaces", endpoint: "https://huggingface.co/mcp", auth: .none, icon: "cpu.fill", tintHex: 0xFFD21E),

        // 搜索
        .init(id: "exa", name: "Exa", category: "search", subtitle: "面向智能体的高质量网页搜索", endpoint: "https://mcp.exa.ai/mcp", auth: .none, icon: "magnifyingglass.circle.fill", tintHex: 0x2563EB),
        .init(id: "amap", name: "高德地图 Amap", category: "search", subtitle: "中国地图、地点检索与路线规划", endpoint: "https://mcp.amap.com/mcp", auth: .key, icon: "map.fill", tintHex: 0x1677FF),

        // 商业
        .init(id: "stripe", name: "Stripe", category: "commerce", subtitle: "支付、账单与客户管理", endpoint: "https://mcp.stripe.com", auth: .oauth, icon: "creditcard.fill", tintHex: 0x635BFF),
        .init(id: "paypal", name: "PayPal", category: "commerce", subtitle: "订单、支付与发票", endpoint: "https://mcp.paypal.com/mcp", auth: .oauth, icon: "dollarsign.circle.fill", tintHex: 0x003087),
        .init(id: "square", name: "Square", category: "commerce", subtitle: "收款、订单与商品目录", endpoint: "https://mcp.squareup.com/mcp", auth: .oauth, icon: "square.grid.2x2.fill", tintHex: 0x111111)
    ]

    public static func categoryTitle(_ id: String) -> String {
        categories.first(where: { $0.id == id })?.title ?? id
    }
}

public struct ConnectorMarketplaceView: View {
    @ObservedObject var host: LocalAgentHost
    @State private var selectedCategory = "all"
    @State private var searchText = ""
    @State private var savedConnectors: [(id: String, type: String, name: String, endpoint: String)] = []
    @State private var activeItem: ConnectorCatalogItem?
    @State private var showCustomSheet = false
    @State private var statusBanner = ""

    private var filteredCatalog: [ConnectorCatalogItem] {
        ConnectorCatalogItem.catalog.filter { item in
            let matchesCategory = selectedCategory == "all" || item.category == selectedCategory
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesSearch = q.isEmpty
                || item.name.lowercased().contains(q)
                || item.subtitle.lowercased().contains(q)
                || item.endpoint.lowercased().contains(q)
            return matchesCategory && matchesSearch
        }
    }

    private var groupedCategories: [(id: String, title: String, items: [ConnectorCatalogItem])] {
        let cats = ConnectorCatalogItem.categories.filter { $0.id != "all" }
        return cats.compactMap { cat in
            let items = filteredCatalog.filter { $0.category == cat.id }
            return items.isEmpty ? nil : (cat.id, cat.title, items)
        }
    }

    private func isConfigured(_ item: ConnectorCatalogItem) -> Bool {
        savedConnectors.contains { $0.name.caseInsensitiveCompare(item.name) == .orderedSame || $0.endpoint == item.endpoint }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Category capsule bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ConnectorCatalogItem.categories, id: \.id) { cat in
                            let selected = selectedCategory == cat.id
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedCategory = cat.id
                                }
                            } label: {
                                Text(cat.title)
                                    .font(.subheadline.weight(selected ? .semibold : .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(selected ? Color.primary : Color(.secondarySystemGroupedBackground))
                                    .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }

                if !statusBanner.isEmpty {
                    Text(statusBanner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                if !savedConnectors.isEmpty && selectedCategory == "all" && searchText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已配置连接器 (\(savedConnectors.count))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)

                        VStack(spacing: 0) {
                            ForEach(Array(savedConnectors.enumerated()), id: \.element.id) { idx, c in
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(DSTheme.brand.opacity(0.14))
                                            .frame(width: 40, height: 40)
                                        Image(systemName: "link.circle.fill")
                                            .foregroundStyle(DSTheme.brand)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name).font(.subheadline.weight(.semibold))
                                        Text(c.endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("探测") {
                                        Task { await probeConnector(id: c.id, name: c.name) }
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                    Button(role: .destructive) {
                                        Task { await deleteConnector(id: c.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                if idx < savedConnectors.count - 1 {
                                    Divider().padding(.leading, 66)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 16)
                    }
                }

                ForEach(groupedCategories, id: \.id) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)

                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                                Button {
                                    activeItem = item
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                .fill(item.tintColor)
                                                .frame(width: 42, height: 42)
                                            Image(systemName: item.icon)
                                                .font(.system(size: 18, weight: .semibold))
                                                .foregroundStyle(.white)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Text(item.name)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                if isConfigured(item) {
                                                    DSStatusBadge("已连接", color: DSTheme.success)
                                                } else if item.auth == .none {
                                                    DSStatusBadge("免认证", color: DSTheme.brand)
                                                }
                                            }
                                            Text(item.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if idx < group.items.count - 1 {
                                    Divider().padding(.leading, 68)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .searchable(text: $searchText, prompt: "搜索 38 个 Remote MCP 连接器")
        .navigationTitle("连接器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCustomSheet = true
                } label: {
                    Label("自定义", systemImage: "plus")
                }
            }
        }
        .sheet(item: $activeItem) { item in
            ConnectorSetupSheet(host: host, item: item) { msg in
                statusBanner = msg
                Task { await reload() }
            }
        }
        .sheet(isPresented: $showCustomSheet) {
            ConnectorSetupSheet(host: host, item: nil) { msg in
                statusBanner = msg
                Task { await reload() }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        if let c = try? await host.rpc()?.request("connectors.list") {
            let raw = c["connectors"] as? [[String: Any]] ?? []
            savedConnectors = raw.compactMap { d in
                guard let id = d["id"] as? String else { return nil }
                return (
                    id: id,
                    type: d["type"] as? String ?? "",
                    name: d["name"] as? String ?? "",
                    endpoint: d["endpoint"] as? String ?? ""
                )
            }
        }
    }

    private func probeConnector(id: String, name: String) async {
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            let result = try await rpc.request("mcp.listTools", params: ["connectorId": id], timeoutSeconds: 180)
            let tools = result["tools"] as? [[String: Any]] ?? []
            statusBanner = "\(name)：已连通，发现 \(tools.count) 个远程工具。"
        } catch {
            statusBanner = "\(name) 探测失败：\(error.localizedDescription)"
        }
    }

    private func deleteConnector(id: String) async {
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            _ = try await rpc.request("connectors.delete", params: ["id": id])
            await reload()
        } catch {
            statusBanner = error.localizedDescription
        }
    }
}

private struct ConnectorSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var host: LocalAgentHost
    let item: ConnectorCatalogItem?
    let onSaved: (String) -> Void

    @State private var name: String
    @State private var endpoint: String
    @State private var token = ""
    @State private var status = ""
    @State private var isWorking = false

    init(host: LocalAgentHost, item: ConnectorCatalogItem?, onSaved: @escaping (String) -> Void) {
        self.host = host
        self.item = item
        self.onSaved = onSaved
        _name = State(initialValue: item?.name ?? "")
        _endpoint = State(initialValue: item?.endpoint ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(item.tintColor)
                                    .frame(width: 48, height: 48)
                                Image(systemName: item.icon)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.headline)
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                DSStatusBadge(item.auth.badgeLabel, color: item.auth == .none ? DSTheme.success : DSTheme.brand)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Remote MCP 配置") {
                    TextField("连接器名称", text: $name)
                    TextField("HTTPS Endpoint URL", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField(item?.auth == .none ? "Token（此服务免认证，可留空）" : "Bearer Token / API Key（存入 Keychain）", text: $token)
                }

                Section {
                    Text("凭据仅保存在本机 iOS Keychain 中，远程 MCP 工具调用前仍遵循审批安全策略。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !status.isEmpty {
                    Section("状态") {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(item?.name ?? "自定义连接器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isWorking ? "保存中…" : "保存并连接") {
                        Task { await saveAndProbe() }
                    }
                    .disabled(isWorking || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveAndProbe() async {
        isWorking = true
        defer { isWorking = false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let rpc = host.rpc() else { throw IPCFrameError.channelClosed }
            _ = try await rpc.request("connectors.upsert", params: [
                "name": cleanName,
                "endpoint": cleanEndpoint,
                "token": cleanToken
            ])
            onSaved("已保存连接器：\(cleanName)")
            dismiss()
        } catch {
            status = error.localizedDescription
        }
    }
}
