import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var windowTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                DropZone(title: "解压", subtitle: "拖入压缩包", symbol: "arrow.down.doc",
                         tint: .blue, formats: "zip · rar · 7z · tar · gz · xz · iso …") { urls in
                    model.extract(urls)
                } choose: {
                    model.extract(model.chooseFiles(archivesOnly: true))
                }
                DropZone(title: "压缩", subtitle: "拖入文件或文件夹", symbol: "archivebox",
                         tint: .indigo, formats: "按下方设置生成压缩包") { urls in
                    model.compress(urls)
                } choose: {
                    model.compress(model.chooseFiles(archivesOnly: false))
                }
            }
            .frame(height: 176)
            .padding([.horizontal, .top], 16)

            CompressBar()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            Divider()
            TaskList()
        }
        .frame(minWidth: 640, minHeight: 540)
        .onDrop(of: [.fileURL], isTargeted: $windowTargeted) { providers in
            loadURLs(providers) { model.open($0) }
            return true
        }
        .sheet(item: $model.passwordPrompt) { task in
            PasswordSheet(task: task)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    let panel = NSOpenPanel()
                    panel.message = "选择要浏览的压缩包"
                    panel.prompt = "浏览"
                    if panel.runModal() == .OK, let url = panel.url { openWindow(value: url) }
                } label: {
                    Label("浏览压缩包", systemImage: "list.bullet.rectangle")
                }
                .help("不解压，先看看里面有什么")

                Button {
                    model.clearFinished()
                } label: {
                    Label("清除已完成", systemImage: "clear")
                }
                .disabled(!model.tasks.contains { $0.state.isFinished })
                .help("清除已完成的任务")
            }
        }
        .onAppear {
            model.openBrowser = { url in openWindow(value: url) }
            // 否则密码框一打开就抢焦点。
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }
}

/// 把拖进来的 NSItemProvider 解析成文件 URL。
func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [(Int, URL)] = []
    for (i, p) in providers.enumerated() where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append((i, url)); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        completion(urls.sorted { $0.0 < $1.0 }.map(\.1))
    }
}

struct DropZone: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let formats: String
    let drop: ([URL]) -> Void
    let choose: () -> Void

    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(tint)
                    .scaleEffect(targeted ? 1.15 : 1)
                Text(title).font(.title2.weight(.semibold))
                Text(targeted ? "松开开始\(title)" : subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(formats)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(targeted ? 0.16 : hovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(targeted ? 0.9 : 0.35),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1.2, dash: targeted ? [] : [6, 5]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: targeted)
        .onHover { hovering = $0 }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadURLs(providers, completion: drop)
            return true
        }
        .help("点击选择文件，或直接拖进来")
    }
}

struct CompressBar: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.compressFormat) private var format: ArchiveFormat = .zip
    @AppStorage(Prefs.compressLevel) private var level: CompressionLevel = .normal
    @AppStorage(Prefs.volumeSizeMB) private var volumeMB = 0
    @AppStorage(Prefs.separateArchives) private var separate = false
    @AppStorage(Prefs.excludeJunk) private var excludeJunk = true
    @State private var showPassword = false

    private let volumeChoices: [(Int, String)] = [
        (0, "不分卷"), (25, "25 MB（邮件附件）"), (100, "100 MB"), (500, "500 MB"),
        (1000, "1 GB"), (2000, "2 GB"), (4000, "4 GB（FAT32 U 盘）")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("格式", selection: $format) {
                    ForEach(ArchiveFormat.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 150)

                Picker("压缩率", selection: $level) {
                    ForEach(CompressionLevel.allCases) { lv in
                        if lv != .store || format.supportsStore { Text(lv.title).tag(lv) }
                    }
                }
                .frame(width: 150)
                .disabled(!format.supportsLevel)

                HStack(spacing: 4) {
                    Group {
                        if showPassword {
                            TextField("密码（可选）", text: $model.compressPassword)
                        } else {
                            SecureField("密码（可选）", text: $model.compressPassword)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showPassword ? "隐藏密码" : "显示密码")
                }
                .disabled(!format.supportsPassword)

                Menu {
                    Picker("分卷大小", selection: $volumeMB) {
                        ForEach(volumeChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Divider()
                    Toggle("多个项目分别压缩", isOn: $separate)
                    Toggle("排除 .DS_Store 等系统文件", isOn: $excludeJunk)
                } label: {
                    Label("更多", systemImage: "slider.horizontal.3")
                }
                .fixedSize()
            }
            .onChange(of: format) { f in
                if !f.supportsStore && level == .store { level = .normal }
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var hint: String {
        var parts = [format.hint]
        if !model.compressPassword.isEmpty {
            parts.append(format.supportsPassword
                         ? (format == .zip ? "AES-256 加密" : "AES-256 加密，文件名也加密")
                         : "\(format.title) 不支持密码")
        } else if format == .sevenZip && !SevenZip.isAvailable {
            parts.append("7z 加密需安装 7-Zip")
        }
        if volumeMB > 0 { parts.append("每卷 \(volumeChoices.first { $0.0 == volumeMB }?.1 ?? "\(volumeMB) MB")") }
        if separate { parts.append("分别压缩") }
        return parts.joined(separator: " · ")
    }
}

struct TaskList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.tasks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("还没有任务")
                    .foregroundStyle(.secondary)
                Text("也可以双击压缩包、拖到程序坞图标上，或在访达右键「服务」里使用")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.tasks) { task in
                    TaskRow(task: task)
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var task: ArchiveTask

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: task.iconPath))
                .resizable()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.verb)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(badgeColor.opacity(0.15)))
                        .foregroundStyle(badgeColor)
                    Text(task.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                status
            }

            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !task.outputs.isEmpty {
                Button("在访达中显示") { model.reveal(task) }
            }
            if case .extract(let src, _) = task.kind {
                Button("浏览压缩包内容") { model.browse(src.url) }
            }
            Divider()
            Button("从列表移除") { model.remove(task) }
        }
    }

    private var badgeColor: Color {
        switch task.kind {
        case .extract: return .blue
        case .compress: return .indigo
        case .test: return .teal
        }
    }

    @ViewBuilder private var status: some View {
        switch task.state {
        case .waiting:
            Text("排队中…").font(.caption).foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: 3) {
                if task.progress < 0 {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: task.progress).progressViewStyle(.linear)
                }
                Text(task.progress >= 0 ? "\(Int(task.progress * 100))%  \(task.detail)" : task.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .needsPassword(let wrong):
            Label(wrong ? "密码不正确，请重新输入" : "需要密码", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .done:
            Label(doneText, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
        case .cancelled:
            Text("已取消").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var doneText: String {
        guard let first = task.outputs.first else { return task.summary }
        let where_ = task.outputs.count > 1 && task.kind.isExtract
            ? "\(task.outputs.count) 个项目" : "「\(first.lastPathComponent)」"
        switch task.kind {
        case .extract: return "已解压为 \(where_) · \(task.summary)"
        case .compress: return "\(task.summary)"
        case .test: return task.summary
        }
    }

    @ViewBuilder private var actions: some View {
        switch task.state {
        case .running, .waiting:
            iconButton("xmark.circle.fill", "取消") { model.cancel(task) }
        case .needsPassword:
            Button("输入密码") { model.passwordPrompt = task }
        case .done:
            if !task.outputs.isEmpty {
                iconButton("magnifyingglass.circle.fill", "在访达中显示") { model.reveal(task) }
            }
        case .failed:
            if task.notWritable {
                Button("换个位置…") { model.retryElsewhere(task) }
            }
            iconButton("arrow.clockwise.circle.fill", "重试") { model.retry(task) }
        case .cancelled:
            iconButton("arrow.clockwise.circle.fill", "重试") { model.retry(task) }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

extension ArchiveTask.Kind {
    var isExtract: Bool {
        if case .extract = self { return true }
        return false
    }
}

struct PasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var task: ArchiveTask
    @State private var password = ""
    @State private var reveal = false
    @State private var remember = true
    @AppStorage(Prefs.rememberPasswords) private var rememberAllowed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("「\(task.archiveName)」已加密").font(.headline)
                    Text(isWrong ? "密码不正确，请再试一次。" : "请输入解压密码。")
                        .font(.callout)
                        .foregroundStyle(isWrong ? .red : .secondary)
                }
            }

            HStack {
                Group {
                    if reveal {
                        TextField("密码", text: $password)
                    } else {
                        SecureField("密码", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            if rememberAllowed {
                Toggle("记住这个密码（存进钥匙串，下次自动尝试）", isOn: $remember)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.dismissPassword(task) }
                    .keyboardShortcut(.cancelAction)
                Button(task.kind.isExtract ? "解压" : "继续", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var isWrong: Bool {
        if case .needsPassword(let wrong) = task.state { return wrong }
        return false
    }

    private func submit() {
        guard !password.isEmpty else { return }
        model.submitPassword(task, password: password, remember: remember && rememberAllowed)
    }
}
