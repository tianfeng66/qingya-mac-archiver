import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            ExtractSettings().tabItem { Label("解压", systemImage: "arrow.down.doc") }
            CompressSettings().tabItem { Label("压缩", systemImage: "archivebox") }
            PasswordSettings().tabItem { Label("密码", systemImage: "key") }
            IntegrationSettings().tabItem { Label("系统集成", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 540)
        .padding(.vertical, 8)
    }
}

/// 「指定文件夹」时出现的路径选择行。
struct FolderPickerRow: View {
    @Binding var path: String

    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().frame(width: 16, height: 16)
            Text((path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button("选择…") {
                if let url = AppModel.shared.chooseFolder(message: "选择文件夹", start: URL(fileURLWithPath: path)) {
                    path = url.path
                }
            }
        }
    }
}

struct ExtractSettings: View {
    @AppStorage(Prefs.extractDestination) private var destination: DestinationMode = .sameFolder
    @AppStorage(Prefs.extractFixedPath) private var fixedPath = ""
    @AppStorage(Prefs.folderMode) private var folderMode: FolderMode = .smart
    @AppStorage(Prefs.revealAfterExtract) private var reveal = true
    @AppStorage(Prefs.trashAfterExtract) private var trash = false
    @AppStorage(Prefs.skipMacJunk) private var skipJunk = true
    @AppStorage(Prefs.nameEncoding) private var encoding: NameEncoding = .auto
    @AppStorage(Prefs.quitAfterFinderOpen) private var quitAfter = false
    @AppStorage(Prefs.browseOnOpen) private var browseOnOpen = false

    var body: some View {
        Form {
            Picker("双击压缩包时", selection: $browseOnOpen) {
                Text("直接解压").tag(false)
                Text("先浏览内容").tag(true)
            }
            .pickerStyle(.segmented)

            Picker("解压到", selection: $destination) {
                ForEach(DestinationMode.allCases) { Text($0.title).tag($0) }
            }
            if destination == .fixed { FolderPickerRow(path: $fixedPath) }

            Picker("文件夹", selection: $folderMode) {
                ForEach(FolderMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Picker("文件名编码", selection: $encoding) {
                ForEach(NameEncoding.allCases) { Text($0.title).tag($0) }
            }
            Text("Windows 上压缩的 zip 常用 GBK 等本地编码。自动识别能处理绝大多数情况，个别仍乱码时可在「浏览压缩包」里临时切换。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("完成后在访达中显示", isOn: $reveal)
            Toggle("解压成功后把压缩包移到废纸篓", isOn: $trash)
            Toggle("跳过 __MACOSX 和 ._ 开头的 Mac 资源文件", isOn: $skipJunk)
            Toggle("从访达双击打开时，全部完成后自动退出", isOn: $quitAfter)
        }
        .formStyle(.grouped)
    }
}

struct CompressSettings: View {
    @AppStorage(Prefs.compressDestination) private var destination: DestinationMode = .sameFolder
    @AppStorage(Prefs.compressFixedPath) private var fixedPath = ""
    @AppStorage(Prefs.compressFormat) private var format: ArchiveFormat = .zip
    @AppStorage(Prefs.compressLevel) private var level: CompressionLevel = .normal
    @AppStorage(Prefs.excludeJunk) private var excludeJunk = true
    @AppStorage(Prefs.separateArchives) private var separate = false
    @AppStorage(Prefs.revealAfterCompress) private var reveal = true

    var body: some View {
        Form {
            Picker("保存到", selection: $destination) {
                ForEach(DestinationMode.allCases) { Text($0.title).tag($0) }
            }
            if destination == .fixed { FolderPickerRow(path: $fixedPath) }

            Picker("默认格式", selection: $format) {
                ForEach(ArchiveFormat.allCases) { Text("\($0.title) — \($0.hint)").tag($0) }
            }
            Picker("压缩率", selection: $level) {
                ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
            }
            Toggle("排除 .DS_Store、._ 资源文件等系统垃圾", isOn: $excludeJunk)
            Toggle("拖入多个项目时分别压缩", isOn: $separate)
            Toggle("完成后在访达中显示", isOn: $reveal)

            Section {
                Text("单个文件：「报告.docx」→「报告.zip」；文件夹保留原名；多个项目用所在文件夹命名。重名时自动加序号，不会覆盖。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PasswordSettings: View {
    @ObservedObject private var store = PasswordStore.shared
    @AppStorage(Prefs.rememberPasswords) private var remember = true
    @State private var newPassword = ""
    @State private var reveal = false

    var body: some View {
        Form {
            Toggle("记住解压成功的密码（保存在钥匙串中）", isOn: $remember)
            Text("遇到加密压缩包时会先自动尝试这些密码，都不对才请你输入。")
                .font(.caption).foregroundStyle(.secondary)

            Section("已保存的密码") {
                if store.saved.isEmpty {
                    Text("还没有").foregroundStyle(.secondary)
                }
                ForEach(store.saved, id: \.self) { pw in
                    HStack {
                        Text(reveal ? pw : String(repeating: "•", count: min(max(pw.count, 6), 16)))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            store.remove(pw)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("添加常用密码", text: $newPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("添加", action: add).disabled(newPassword.isEmpty)
                }
                Toggle("显示密码", isOn: $reveal)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.loadIfNeeded() }
    }

    private func add() {
        store.remember(newPassword, persist: true)
        newPassword = ""
    }
}

struct IntegrationSettings: View {
    @State private var message = ""

    private static let archiveTypes: [UTType] = [
        .zip, .gzip, .bz2,
        UTType("org.7-zip.7-zip-archive"), UTType("com.rarlab.rar-archive"),
        UTType("public.tar-archive"), UTType("org.gnu.gnu-zip-tar-archive"),
        UTType("org.tukaani.xz-archive"), UTType("com.tian.qingya.split-volume")
    ].compactMap { $0 }

    var body: some View {
        Form {
            Section("默认打开方式") {
                Text("设为默认后，双击 zip / rar / 7z / tar / gz 等压缩包会直接用轻压解压。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("设为压缩包的默认打开方式", action: makeDefault)
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }

            Section("访达右键菜单") {
                Text("在访达里选中文件 → 右键 →「服务」→「用轻压压缩」/「用轻压解压」。第一次需要到「系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件和文件夹」里勾选。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开键盘快捷键设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }

            Section("程序坞") {
                Text("把文件拖到程序坞里的轻压图标上：压缩包会被解压，其他文件会按默认格式压缩。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("7-Zip 增强（可选）") {
                if let exe = SevenZip.executable {
                    Label("已启用：\(exe.path)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("加密的 RAR / 7z 会自动交给 7-Zip；7z 格式支持设置密码并加密文件名。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("未安装", systemImage: "info.circle").foregroundStyle(.secondary)
                    Text("系统自带的解压引擎不支持带密码的 RAR / 7z。需要时在终端运行 brew install sevenzip，重启轻压即可自动启用。")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func makeDefault() {
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var failed = 0
        for type in Self.archiveTypes {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if error != nil { failed += 1 }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            message = failed == 0 ? "已设置 ✓" : "部分类型设置失败（\(failed) 个）"
        }
    }
}
