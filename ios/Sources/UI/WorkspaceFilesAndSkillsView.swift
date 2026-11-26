import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 8. Sandboxed Workspace Files Browser (`Documents/dsh-home/files/`)

public struct WorkspaceFilesView: View {
    @ObservedObject var host: LocalAgentHost
    private struct FileEntry: Identifiable {
        let id: String
        let url: URL
        let name: String
        let byteCount: Int
        let isDirectory: Bool

        var iconName: String {
            if isDirectory { return "folder.fill" }
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp"].contains(ext) { return "photo.fill" }
            if ext == "pdf" { return "doc.richtext.fill" }
            if ["zip", "tar", "gz", "tgz", "rar", "7z"].contains(ext) { return "doc.zipper" }
            if ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext) { return "film.fill" }
            if ["mp3", "m4a", "wav", "aac", "flac"].contains(ext) { return "waveform" }
            if ["swift", "py", "js", "mjs", "ts", "tsx", "jsx", "json", "yml", "yaml", "sh", "html", "css", "sql", "go", "rs", "c", "cpp", "h"].contains(ext) {
                return "chevron.left.forwardslash.chevron.right"
            }
            return "doc.text.fill"
        }

        var iconColor: Color {
            if isDirectory { return .orange }
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif"].contains(ext) { return .pink }
            if ext == "pdf" { return .red }
            if ["zip", "tar", "gz", "tgz", "rar", "7z"].contains(ext) { return .purple }
            return DSTheme.brand
        }
    }

    @State private var entries: [FileEntry] = []
    @State private var searchText = ""
    @State private var selectedPreview: (url: URL, name: String, content: String, isEditable: Bool)?
    @State private var editedPreviewContent = ""
    @State private var isEditingPreview = false
    @State private var showNewFile = false
    @State private var newFileName = ""
    @State private var newFileContent = ""
    @State private var status = ""

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var filesRoot: URL {
        let dir = host.workspace.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var filteredEntries: [FileEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    public var body: some View {
        List {
            Section {
                Text("此目录供智能体通过 read / write / edit / apply_patch / glob / grep 安全读写（写入与修改均需经过原生审批）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("工作区文件（files/ · \(filteredEntries.count) 项）") {
                if filteredEntries.isEmpty {
                    DSEmptyStateView(
                        icon: "folder.badge.plus",
                        title: entries.isEmpty ? "工作区暂无文件" : "无匹配文件",
                        subtitle: entries.isEmpty ? "点击右上角新建文本/代码文件，粘贴剪贴板文本，或从系统文件 App 导入任意本地文件与目录。" : "尝试更换搜索关键词。",
                        actionTitle: entries.isEmpty ? "导入本地文件" : nil
                    ) {
                        presentWorkspaceImporter()
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredEntries) { entry in
                        Button {
                            preview(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.iconName)
                                    .foregroundStyle(entry.iconColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.subheadline.weight(.medium))
                                    Text(entry.isDirectory ? "目录 · 点击查看内容" : ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contextMenu {
                            #if canImport(UIKit)
                            Button {
                                UIPasteboard.general.string = "files/\(entry.name)"
                                status = "已复制路径：files/\(entry.name)"
                                DSHaptics.impact(.light)
                            } label: {
                                Label("复制工作区路径", systemImage: "doc.on.doc")
                            }
                            #endif
                            if !entry.isDirectory {
                                ShareLink(item: entry.url) {
                                    Label("分享 / 导出文件", systemImage: "square.and.arrow.up")
                                }
                            }
                            Button(role: .destructive) {
                                try? FileManager.default.removeItem(at: entry.url)
                                reload()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                try? FileManager.default.removeItem(at: entry.url)
                                reload()
                            }
                        }
                    }
                }
            }
            if !status.isEmpty {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $searchText, prompt: "筛选工作区文件名")
        .navigationTitle("工作区文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                #if canImport(UIKit)
                Button {
                    let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else {
                        status = "剪贴板为空。"
                        return
                    }
                    do {
                        let stamp = Int(Date().timeIntervalSince1970)
                        let imported = try host.importRawDataToWorkspace(Data(text.utf8), suggestedName: "clipboard_\(stamp).txt")
                        status = "已保存剪贴板文本：files/\(imported.relativePath)"
                        DSHaptics.notify(.success)
                        reload()
                    } catch {
                        status = "保存失败：\(error.localizedDescription)"
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .help("粘贴剪贴板文本存为文件")
                #endif
                Button { showNewFile = true } label: { Image(systemName: "doc.badge.plus") }
                    .help("新建文本或代码文件")
                Button { presentWorkspaceImporter() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("从手机导入任意文件或目录")
            }
        }
        .sheet(isPresented: $showNewFile) {
            NavigationStack {
                Form {
                    TextField("文件名（如 notes.md）", text: $newFileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $newFileContent)
                        .font(.caption.monospaced())
                        .frame(minHeight: 160)
                }
                .navigationTitle("新建工作区文件")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { showNewFile = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            let clean = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "/", with: "_")
                                .replacingOccurrences(of: "..", with: "_")
                            guard !clean.isEmpty else { return }
                            let dest = filesRoot.appendingPathComponent(clean, isDirectory: false)
                            do {
                                try Data(newFileContent.utf8).write(to: dest, options: .atomic)
                                status = "已创建：files/\(clean)"
                                newFileName = ""
                                newFileContent = ""
                                showNewFile = false
                                reload()
                            } catch { status = "创建失败：\(error.localizedDescription)" }
                        }
                        .disabled(newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedPreview != nil },
            set: { if !$0 { selectedPreview = nil; isEditingPreview = false } }
        )) {
            if let preview = selectedPreview {
                NavigationStack {
                    Group {
                        if isEditingPreview && preview.isEditable {
                            TextEditor(text: $editedPreviewContent)
                                .font(.caption.monospaced())
                                .padding(8)
                        } else {
                            ScrollView {
                                Text(preview.content)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .navigationTitle(preview.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if preview.isEditable {
                                if isEditingPreview {
                                    Button("保存") {
                                        do {
                                            try Data(editedPreviewContent.utf8).write(to: preview.url, options: .atomic)
                                            selectedPreview = (preview.url, preview.name, editedPreviewContent, true)
                                            isEditingPreview = false
                                            status = "已保存：files/\(preview.name)"
                                            reload()
                                        } catch {
                                            status = "保存失败：\(error.localizedDescription)"
                                        }
                                    }
                                    .fontWeight(.semibold)
                                } else {
                                    Button("编辑") {
                                        editedPreviewContent = preview.content
                                        isEditingPreview = true
                                    }
                                }
                            }
                            ShareLink(item: preview.url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            Button("完成") {
                                selectedPreview = nil
                                isEditingPreview = false
                            }
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private func presentWorkspaceImporter() {
        #if canImport(UIKit)
        NativeDocumentPicker.present(allowsMultipleSelection: true) { urls in
            guard !urls.isEmpty else { return }
            var importedNames: [String] = []
            var lastError: String?
            for url in urls {
                do {
                    let imported = try host.importFileToWorkspace(from: url)
                    importedNames.append(imported.relativePath)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            if !importedNames.isEmpty {
                status = importedNames.count == 1
                    ? "已导入：files/\(importedNames[0])"
                    : "已导入 \(importedNames.count) 个文件到 files/"
                DSHaptics.notify(.success)
                reload()
            } else if let lastError {
                status = "导入失败：\(lastError)"
                DSHaptics.notify(.error)
            }
        }
        #endif
    }

    private func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: filesRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            entries = []
            return
        }
        entries = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isSymbolicLink != true else { return nil }
            let isDir = values?.isDirectory == true
            guard isDir || values?.isRegularFile == true else { return nil }
            return FileEntry(id: url.lastPathComponent, url: url, name: url.lastPathComponent, byteCount: values?.fileSize ?? 0, isDirectory: isDir)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func preview(_ entry: FileEntry) {
        if entry.isDirectory {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: entry.url.path))?.sorted() ?? []
            let body = children.isEmpty
                ? "空目录（files/\(entry.name)）"
                : "目录内容（共 \(children.count) 项）：\n\n" + children.prefix(200).map { "• \($0)" }.joined(separator: "\n")
            selectedPreview = (entry.url, entry.name, body, false)
            isEditingPreview = false
            return
        }
        // O(1) bounded 64 KB read via FileHandle so large imported files never spike iOS Jetsam memory.
        let maxPreviewBytes = 65_536
        guard let handle = try? FileHandle(forReadingFrom: entry.url) else {
            status = "无法读取文件。"
            return
        }
        defer { try? handle.close() }
        let slice = (try? handle.read(upToCount: maxPreviewBytes)) ?? Data()
        let totalBytes = entry.byteCount > 0 ? entry.byteCount : slice.count
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let decoded: String? = {
            if !slice.contains(0), let utf8 = String(data: slice, encoding: .utf8) { return utf8 }
            if !slice.contains(0), let gb = String(data: slice, encoding: gb18030) { return gb }
            if let utf16 = String(data: slice, encoding: .utf16) { return utf16 }
            return nil
        }()
        if let text = decoded {
            let truncated = totalBytes > maxPreviewBytes
            selectedPreview = (entry.url, entry.name, truncated ? text + "\n…(已截断，仅只读预览)" : text, !truncated)
            isEditingPreview = false
        } else {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
            selectedPreview = (entry.url, entry.name, "二进制文件（\(sizeStr)），可使用右上角分享导出，或让智能体通过 python_exec 分析处理。", false)
            isEditingPreview = false
        }
    }
}

// MARK: - 9. DSH Skills Manager (`Documents/dsh-home/files/skills/<name>/SKILL.md`)

public struct SkillsManagerView: View {
    @ObservedObject var host: LocalAgentHost
    private struct SkillEntry: Identifiable {
        let id: String
        let name: String
        let fileURL: URL
        let content: String
    }

    @State private var skills: [SkillEntry] = []
    @State private var searchText = ""
    @State private var editingSkill: SkillEntry?
    @State private var editContent = ""
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newContent = """
    ---
    name: my-skill
    description: 描述这个技能何时触发以及完成什么任务
    ---

    # 使用说明
    1. 步骤一
    2. 步骤二
    """
    @State private var status = ""

    public init(host: LocalAgentHost) {
        self.host = host
    }

    private var skillsRoot: URL {
        let fm = FileManager.default
        let dir = LocalAgentTransport.defaultWorkspace
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Non-destructively migrate any legacy skills stored at `<workspace>/skills/` into `<workspace>/files/skills/`
        let legacyDir = LocalAgentTransport.defaultWorkspace.appendingPathComponent("skills", isDirectory: true)
        if let legacyItems = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for item in legacyItems {
                let srcFile = item.hasDirectoryPath ? item.appendingPathComponent("SKILL.md") : item
                guard srcFile.pathExtension.lowercased() == "md", fm.fileExists(atPath: srcFile.path) else { continue }
                let folder = item.hasDirectoryPath ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
                let dstDir = dir.appendingPathComponent(folder, isDirectory: true)
                let dstFile = dstDir.appendingPathComponent("SKILL.md")
                if !fm.fileExists(atPath: dstFile.path) {
                    try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                    try? fm.copyItem(at: srcFile, to: dstFile)
                }
            }
        }
        return dir
    }

    private func skillSummary(_ content: String) -> String {
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("description:") {
                let value = trimmed.dropFirst("description:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { return value }
            }
        }
        return content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "---" && !$0.lowercased().hasPrefix("name:") }
            .prefix(2)
            .joined(separator: " ")
    }

    private var filteredSkills: [SkillEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || skillSummary($0.content).localizedCaseInsensitiveContains(query)
        }
    }

    public var body: some View {
        List {
            Section {
                Text("管理本机 DSH Skill 技能（skills/<名称>/SKILL.md）。已挂载官方 dsh-skill-filesystem 与 dsh-tool-skill，智能体可在对话中自动发现并调用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("已安装技能（\(filteredSkills.count)）") {
                if filteredSkills.isEmpty {
                    DSEmptyStateView(
                        icon: "wand.and.stars",
                        title: skills.isEmpty ? "暂无自定义技能" : "无匹配技能",
                        subtitle: skills.isEmpty ? "点击右上角 + 新建一个 SKILL.md，赋予智能体可复用的标准作业流程。" : "尝试更换搜索关键词。",
                        actionTitle: skills.isEmpty ? "新建 SKILL.md" : nil
                    ) {
                        showCreate = true
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredSkills) { skill in
                        Button {
                            editingSkill = skill
                            editContent = skill.content
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.name).font(.subheadline.weight(.semibold))
                                Text(skillSummary(skill.content))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                try? FileManager.default.removeItem(at: skill.fileURL.deletingLastPathComponent())
                                reload()
                            }
                        }
                    }
                }
            }
            if !status.isEmpty {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $searchText, prompt: "搜索技能名称或描述")
        .navigationTitle("Skill 技能管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Label("新建", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    TextField("技能目录名（英文/数字/连字符）", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $newContent)
                        .font(.caption.monospaced())
                        .frame(minHeight: 200)
                }
                .navigationTitle("新建 SKILL.md")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { showCreate = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            let safe = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()
                                .map { ($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")) ? $0 : "-" }
                            let folder = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                            guard !folder.isEmpty else { return }
                            let dir = skillsRoot.appendingPathComponent(folder, isDirectory: true)
                            let file = dir.appendingPathComponent("SKILL.md", isDirectory: false)
                            do {
                                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                                try Data(newContent.utf8).write(to: file, options: .atomic)
                                status = "已保存技能：\(folder)/SKILL.md"
                                newName = ""
                                showCreate = false
                                reload()
                            } catch { status = "保存失败：\(error.localizedDescription)" }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(item: $editingSkill) { target in
            NavigationStack {
                Form {
                    TextEditor(text: $editContent)
                        .font(.caption.monospaced())
                        .frame(minHeight: 260)
                }
                .navigationTitle(target.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { editingSkill = nil } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            do {
                                try Data(editContent.utf8).write(to: target.fileURL, options: .atomic)
                                status = "已更新技能：\(target.name)"
                                editingSkill = nil
                                reload()
                            } catch { status = "更新失败：\(error.localizedDescription)" }
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            skills = []
            return
        }
        skills = dirs.compactMap { dir in
            let file = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: file.path),
                  let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return SkillEntry(id: dir.lastPathComponent, name: dir.lastPathComponent, fileURL: file, content: content)
        }.sorted { $0.name < $1.name }
    }
}
