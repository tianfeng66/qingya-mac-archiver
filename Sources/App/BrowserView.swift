import SwiftUI
import UniformTypeIdentifiers

struct TreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    var size: Int64
    let modified: Date?
    let encrypted: Bool
    var children: [TreeNode]?
}

@MainActor
final class BrowserModel: ObservableObject {
    let source: ArchiveSource
    @Published var listing: ArchiveListing?
    @Published var tree: [TreeNode] = []
    @Published var error: String?
    @Published var loading = true
    @Published var encoding: NameEncoding = Prefs.encoding
    @Published var previewing = false
    @Published var askPassword = false
    @Published var passwordWrong = false

    private var pendingPreview: String?
    private var password: String?

    init(url: URL) {
        source = ArchiveSource(url)
        load()
    }

    func load() {
        loading = true
        error = nil
        let src = source, enc = encoding
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Extractor.list(src, encoding: enc) }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let l):
                    self.listing = l
                    self.tree = Self.buildTree(l.items)
                case .failure(let e):
                    self.error = e.localizedDescription
                }
            }
        }
    }

    static func buildTree(_ items: [ArchiveItem]) -> [TreeNode] {
        final class Box {
            var node: TreeNode
            var kids: [String: Box] = [:]
            init(_ n: TreeNode) { node = n }
        }
        let root = Box(TreeNode(id: "", name: "", isDirectory: true, size: 0, modified: nil, encrypted: false, children: []))

        for item in items {
            let comps = item.path.split(separator: "/").map(String.init)
            var cur = root
            var path = ""
            for (i, c) in comps.enumerated() {
                path = path.isEmpty ? c : path + "/" + c
                let last = i == comps.count - 1
                if let next = cur.kids[c] {
                    if last && !item.isDirectory { next.node.size = item.size }
                    cur = next
                } else {
                    let isDir = !last || item.isDirectory
                    let n = TreeNode(id: path, name: c, isDirectory: isDir, size: last ? item.size : 0,
                                     modified: last ? item.modified : nil, encrypted: last && item.encrypted,
                                     children: isDir ? [] : nil)
                    let b = Box(n)
                    cur.kids[c] = b
                    cur = b
                }
            }
        }

        func finish(_ b: Box) -> TreeNode {
            var n = b.node
            guard n.isDirectory else { return n }
            let kids = b.kids.values.map(finish).sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            n.children = kids.isEmpty ? nil : kids
            n.size = kids.reduce(0) { $0 + $1.size }
            return n
        }
        return finish(root).children ?? []
    }

    func flatMatches(_ query: String) -> [TreeNode] {
        var out: [TreeNode] = []
        func walk(_ nodes: [TreeNode]) {
            for n in nodes {
                if n.name.localizedCaseInsensitiveContains(query) {
                    var leaf = n
                    leaf.children = nil
                    out.append(leaf)
                }
                if let c = n.children { walk(c) }
            }
        }
        walk(tree)
        return out
    }

    func node(_ id: String) -> TreeNode? {
        func find(_ nodes: [TreeNode]) -> TreeNode? {
            for n in nodes {
                if n.id == id { return n }
                if let c = n.children, let hit = find(c) { return hit }
            }
            return nil
        }
        return find(tree)
    }

    /// 解到临时目录后用默认程序打开。
    func preview(_ path: String) {
        guard let node = node(path) else { return }
        previewing = true
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("qingya-preview/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var o = ExtractOptions(destination: tmp)
        o.folderMode = .never
        o.encoding = encoding
        o.selection = [path]
        o.stripPrefix = (path as NSString).deletingLastPathComponent
        o.password = password
        o.candidatePasswords = PasswordStore.shared.candidates
        o.propagateQuarantine = true
        let src = source
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Extractor.extract(src, options: o, cancel: CancelToken(), progress: { _, _ in }) }
            DispatchQueue.main.async {
                self.previewing = false
                switch result {
                case .success(let r):
                    if let pw = r.usedPassword { PasswordStore.shared.remember(pw, persist: false) }
                    if let url = r.outputs.first {
                        if node.isDirectory {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }
                case .failure(ArchiveError.passwordRequired):
                    self.pendingPreview = path
                    self.passwordWrong = false
                    self.askPassword = true
                case .failure(ArchiveError.wrongPassword):
                    self.pendingPreview = path
                    self.passwordWrong = true
                    self.askPassword = true
                case .failure(let e):
                    self.error = e.localizedDescription
                }
            }
        }
    }

    func submitPassword(_ pw: String) {
        password = pw
        askPassword = false
        if let p = pendingPreview { preview(p) }
    }

    /// 选中项的公共父目录，解压时去掉它，免得带出一串上层空目录。
    static func commonParent(_ paths: [String]) -> String {
        let parents = paths.map { ($0 as NSString).deletingLastPathComponent.split(separator: "/").map(String.init) }
        guard var common = parents.first else { return "" }
        for p in parents.dropFirst() {
            common = Array(zip(common, p).prefix { $0 == $1 }.map(\.0))
        }
        return common.joined(separator: "/")
    }
}

struct BrowserView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var vm: BrowserModel
    @State private var selection = Set<String>()
    @State private var expanded = Set<String>()
    @State private var query = ""

    init(url: URL) {
        _vm = StateObject(wrappedValue: BrowserModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle(vm.source.fileName)
        .searchable(text: $query, placement: .toolbar, prompt: "搜索文件名")
        .toolbar { toolbar }
        .sheet(isPresented: $vm.askPassword) {
            BrowserPasswordSheet(name: vm.source.fileName, wrong: vm.passwordWrong) { vm.submitPassword($0) }
        }
    }

    @ViewBuilder private var content: some View {
        if vm.loading {
            ProgressView("正在读取目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.error, vm.listing == nil {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                header
                List(selection: $selection) {
                    if query.isEmpty {
                        ForEach(vm.tree) { OutlineRow(node: $0, expanded: $expanded) }
                    } else {
                        ForEach(vm.flatMatches(query)) { NodeRow(node: $0, showPath: true).tag($0.id) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onAppear { autoExpand(vm.tree) }
                .onChange(of: vm.tree) { autoExpand($0) }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        Button("打开") { vm.preview(id) }
                    }
                    if !ids.isEmpty {
                        Button("解压所选到…") { extractSelected(ids) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { vm.preview(id) }
                }
                if let error = vm.error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(6)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28)
            Text("大小").frame(width: 90, alignment: .trailing)
            Text("修改日期").frame(width: 140, alignment: .leading).padding(.leading, 12)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let l = vm.listing {
                Text("\(l.fileCount) 个文件 · 原始 \(ByteFormat.string(l.totalSize)) · 压缩后 \(ByteFormat.string(vm.source.totalSize))\(ratio(l))")
                if vm.source.volumes.count > 1 { tag("\(vm.source.volumes.count) 个分卷", .purple) }
                if l.hasEncrypted { tag("已加密", .orange) }
                tag(l.formatName, .gray)
            }
            if vm.previewing { ProgressView().controlSize(.small) }
            Spacer()
            if !selection.isEmpty { Text("已选 \(selection.count) 项") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func ratio(_ l: ArchiveListing) -> String {
        guard l.totalSize > 0 else { return "" }
        let r = Double(vm.source.totalSize) / Double(l.totalSize)
        return r < 1 ? String(format: " · 压缩率 %.0f%%", r * 100) : ""
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if vm.listing?.legacyEncoding != nil || vm.encoding != .auto {
                Picker("文件名编码", selection: $vm.encoding) {
                    ForEach(NameEncoding.allCases) { enc in
                        if enc == .auto, let detected = vm.listing?.legacyEncoding.flatMap(NameEncoding.init(encoding:)) {
                            Text("自动识别（\(detected.shortTitle)）").tag(enc)
                        } else {
                            Text(enc.title).tag(enc)
                        }
                    }
                }
                .frame(width: 190)
                .help("文件名乱码时换一种编码试试")
                .onChange(of: vm.encoding) { _ in vm.load() }
            }

            Button {
                app.test(vm.source.url)
            } label: {
                Label("测试", systemImage: "checkmark.shield")
            }
            .help("完整读一遍，检查文件是否损坏、密码是否正确")

            Button {
                extractSelected(selection)
            } label: {
                Label("解压所选", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(selection.isEmpty)
            .help("只解压选中的文件和文件夹")

            Button {
                app.extract([vm.source.url], encoding: vm.encoding)
            } label: {
                Label("全部解压", systemImage: "square.and.arrow.down")
            }
            .help("按设置解压全部内容")
        }
    }

    /// 只有一个顶层文件夹时（最常见的打包方式）直接展开。
    private func autoExpand(_ tree: [TreeNode]) {
        if tree.count == 1, tree[0].isDirectory { expanded.insert(tree[0].id) }
    }

    private func extractSelected(_ ids: Set<String>) {
        guard !ids.isEmpty, let dest = app.chooseFolder(message: "把选中的 \(ids.count) 项解压到…",
                                                          start: vm.source.directory) else { return }
        let prefix = BrowserModel.commonParent(Array(ids))
        app.extract([vm.source.url], destination: dest, selection: ids,
                    stripPrefix: prefix.isEmpty ? nil : prefix, encoding: vm.encoding)
    }
}

struct OutlineRow: View {
    let node: TreeNode
    @Binding var expanded: Set<String>

    var body: some View {
        if let kids = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(node.id) },
                set: { open in
                    if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                }
            )) {
                ForEach(kids) { OutlineRow(node: $0, expanded: $expanded) }
            } label: {
                NodeRow(node: node, showPath: false)
            }
            .tag(node.id)
        } else {
            NodeRow(node: node, showPath: false).tag(node.id)
        }
    }
}

struct NodeRow: View {
    let node: TreeNode
    let showPath: Bool

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                if showPath && node.id.contains("/") {
                    Text((node.id as NSString).deletingLastPathComponent)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            if node.encrypted {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Text(node.isDirectory && node.size == 0 ? "--" : ByteFormat.string(node.size))
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(node.modified.map { Self.dateFormat.string(from: $0) } ?? "")
                .frame(width: 140, alignment: .leading)
                .padding(.leading, 12)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private var icon: NSImage {
        if node.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = (node.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

struct BrowserPasswordSheet: View {
    let name: String
    let wrong: Bool
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("「\(name)」已加密").font(.headline)
            Text(wrong ? "密码不正确，请再试一次。" : "预览需要输入解压密码。")
                .font(.callout)
                .foregroundStyle(wrong ? .red : .secondary)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !password.isEmpty { submit(password) } }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确定") { submit(password) }.keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
