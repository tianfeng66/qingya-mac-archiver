import AppKit
import SwiftUI

struct ExtractRequest {
    var destination: URL
    var folderMode: FolderMode
    var encoding: NameEncoding
    var skipMacJunk: Bool
    var selection: Set<String>?
    var stripPrefix: String?
    var reveal: Bool
    var trashArchive: Bool
}

struct CompressRequest {
    var items: [URL]
    var output: URL
    var options: CompressOptions
    var reveal: Bool
}

@MainActor
final class ArchiveTask: ObservableObject, Identifiable {
    enum Kind {
        case extract(ArchiveSource, ExtractRequest)
        case compress(CompressRequest)
        case test(ArchiveSource)
    }

    enum State: Equatable {
        case waiting, running, needsPassword(wrong: Bool), done, failed(String), cancelled

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    let id = UUID()
    var kind: Kind
    @Published var state: State = .waiting
    @Published var progress: Double = -1
    @Published var detail = ""
    @Published var summary = ""
    @Published var outputs: [URL] = []
    @Published var notWritable = false

    var password: String?
    var rememberPassword = true
    var cancelToken = CancelToken()
    var startedAt = Date()

    init(_ kind: Kind) { self.kind = kind }

    var title: String {
        switch kind {
        case .extract(let src, _): return src.fileName
        case .compress(let req): return req.output.lastPathComponent
        case .test(let src): return src.fileName
        }
    }

    var verb: String {
        switch kind {
        case .extract: return "解压"
        case .compress: return "压缩"
        case .test: return "测试"
        }
    }

    /// 任务图标取原文件的系统图标。
    var iconPath: String {
        switch kind {
        case .extract(let src, _), .test(let src): return src.url.path
        case .compress(let req): return req.items.first?.path ?? "/"
        }
    }

    var archiveName: String {
        switch kind {
        case .extract(let src, _), .test(let src): return src.fileName
        case .compress(let req): return req.output.lastPathComponent
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tasks: [ArchiveTask] = []
    @Published var passwordPrompt: ArchiveTask?
    /// 压缩密码只在本次运行有效，不落盘。
    @Published var compressPassword = ""

    let passwords = PasswordStore.shared
    /// 主窗口出现后才拿得到 openWindow；启动时从访达打开的请求先排队。
    var openBrowser: ((URL) -> Void)? {
        didSet {
            guard let openBrowser else { return }
            pendingBrowse.forEach(openBrowser)
            pendingBrowse = []
        }
    }
    private var pendingBrowse: [URL] = []
    /// 从访达双击启动时置位；任务全部成功后按设置自动退出。
    var launchedForFiles = false

    private let maxConcurrent = 2

    /// 等密码的不算：退出时不必为它弹确认。
    var hasActiveTasks: Bool {
        tasks.contains { $0.state == .running || $0.state == .waiting }
    }

    // MARK: 入口

    /// 自动分流：压缩包走解压，其他走压缩（同 Keka）。
    /// 设置了「打开时先浏览」则压缩包进浏览窗口（同 BetterZip）。
    func open(_ urls: [URL], fromFinder: Bool = false) {
        let archives = urls.filter(ArchiveKind.isArchive)
        let others = urls.filter { !ArchiveKind.isArchive($0) }
        if !archives.isEmpty {
            if fromFinder && Prefs.bool(Prefs.browseOnOpen) {
                archives.forEach(browse)
            } else {
                extract(archives)
            }
        }
        if !others.isEmpty { compress(others) }
    }

    func browse(_ url: URL) {
        if let openBrowser { openBrowser(url) } else { pendingBrowse.append(url) }
    }

    func extract(_ urls: [URL], destination: URL? = nil, selection: Set<String>? = nil,
                 stripPrefix: String? = nil, encoding: NameEncoding? = nil) {
        // 同一组分卷只解一次。
        var seen = Set<URL>()
        let sources = urls.map(ArchiveSource.init).filter { seen.insert($0.id).inserted }
        guard !sources.isEmpty else { return }

        var askedOnce: URL?
        for src in sources {
            let dest: URL
            if let destination {
                dest = destination
            } else {
                guard let d = extractDestination(for: src, asked: &askedOnce) else { return }
                dest = d
            }
            let req = ExtractRequest(destination: dest, folderMode: Prefs.folder,
                                     encoding: encoding ?? Prefs.encoding,
                                     skipMacJunk: Prefs.bool(Prefs.skipMacJunk),
                                     selection: selection, stripPrefix: stripPrefix,
                                     reveal: Prefs.bool(Prefs.revealAfterExtract),
                                     trashArchive: selection == nil && Prefs.bool(Prefs.trashAfterExtract))
            tasks.insert(ArchiveTask(.extract(src, req)), at: 0)
        }
        pump()
    }

    func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let format = Prefs.format
        var options = CompressOptions()
        options.format = format
        options.level = format.supportsLevel ? Prefs.level : .normal
        if options.level == .store && !format.supportsStore { options.level = .fast }
        options.excludeJunk = Prefs.bool(Prefs.excludeJunk)
        let mb = Prefs.int(Prefs.volumeSizeMB)
        options.volumeSize = mb > 0 ? Int64(mb) * 1_000_000 : nil
        if format.supportsPassword && !compressPassword.isEmpty { options.password = compressPassword }

        let groups: [[URL]] = Prefs.bool(Prefs.separateArchives) && urls.count > 1 ? urls.map { [$0] } : [urls]
        var askedOnce: URL?
        for items in groups {
            guard let dir = compressDestination(for: items, asked: &askedOnce) else { return }
            let output = FileManager.default.uniqueURL(in: dir, name: archiveName(for: items) + "." + format.fileExtension,
                                                       isDirectory: false, alsoAvoid: [".001"])
            let req = CompressRequest(items: items, output: output, options: options,
                                      reveal: Prefs.bool(Prefs.revealAfterCompress))
            tasks.insert(ArchiveTask(.compress(req)), at: 0)
        }
        pump()
    }

    func test(_ url: URL) {
        tasks.insert(ArchiveTask(.test(ArchiveSource(url))), at: 0)
        pump()
    }

    // MARK: 任务操作

    func cancel(_ task: ArchiveTask) {
        switch task.state {
        case .running: task.cancelToken.cancel()
        case .waiting, .needsPassword:
            task.state = .cancelled
            if passwordPrompt === task { passwordPrompt = nil }
            refreshPrompt()
        default: break
        }
    }

    func retry(_ task: ArchiveTask) {
        task.state = .waiting
        task.progress = -1
        task.summary = ""
        task.notWritable = false
        pump()
    }

    /// 目标位置不可写时换个地方重试。
    func retryElsewhere(_ task: ArchiveTask) {
        guard let dir = chooseFolder(message: "选择保存位置") else { return }
        switch task.kind {
        case .extract(let src, var req):
            req.destination = dir
            task.kind = .extract(src, req)
        case .compress(var req):
            req.output = FileManager.default.uniqueURL(in: dir, name: req.output.lastPathComponent,
                                                       isDirectory: false, alsoAvoid: [".001"])
            task.kind = .compress(req)
        case .test:
            break
        }
        retry(task)
    }

    func remove(_ task: ArchiveTask) {
        if !task.state.isFinished { cancel(task) }
        tasks.removeAll { $0 === task }
    }

    func clearFinished() {
        tasks.removeAll { $0.state.isFinished }
    }

    func reveal(_ task: ArchiveTask) {
        let urls = task.outputs.filter { FileManager.default.itemExists(at: $0) }
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.iconPath)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func submitPassword(_ task: ArchiveTask, password: String, remember: Bool) {
        task.password = password
        task.rememberPassword = remember
        passwordPrompt = nil
        retry(task)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshPrompt() }
    }

    func dismissPassword(_ task: ArchiveTask) {
        task.state = .failed("未输入密码")
        passwordPrompt = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshPrompt() }
        checkQuit()
    }

    private func refreshPrompt() {
        guard passwordPrompt == nil else { return }
        passwordPrompt = tasks.last { if case .needsPassword = $0.state { return true }; return false }
    }

    // MARK: 调度

    private func pump() {
        let running = tasks.filter { $0.state == .running }.count
        guard running < maxConcurrent else { return }
        // 列表是新任务在上，按加入顺序从底部开始跑。
        for task in tasks.reversed() where task.state == .waiting {
            if tasks.filter({ $0.state == .running }).count >= maxConcurrent { break }
            start(task)
        }
    }

    private func start(_ task: ArchiveTask) {
        task.state = .running
        task.progress = -1
        task.detail = ""
        task.startedAt = Date()
        let token = CancelToken()
        task.cancelToken = token

        let progress: ProgressHandler = { [weak task] fraction, detail in
            DispatchQueue.main.async {
                guard let task, task.state == .running else { return }
                task.progress = fraction
                task.detail = detail
            }
        }

        switch task.kind {
        case .extract(let src, let req):
            var o = ExtractOptions(destination: req.destination)
            o.folderMode = req.folderMode
            o.encoding = req.encoding
            o.skipMacJunk = req.skipMacJunk
            o.selection = req.selection
            o.stripPrefix = req.stripPrefix
            o.password = task.password
            o.candidatePasswords = passwords.candidates
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try Extractor.extract(src, options: o, cancel: token, progress: progress) }
                DispatchQueue.main.async { self.finishExtract(task, src: src, req: req, result: result) }
            }

        case .compress(let req):
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    try Compressor.compress(req.items, to: req.output, options: req.options, cancel: token, progress: progress)
                }
                DispatchQueue.main.async { self.finishCompress(task, req: req, result: result) }
            }

        case .test(let src):
            let pw = task.password
            let candidates = passwords.candidates
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    try Extractor.test(src, password: pw, candidates: candidates, cancel: token, progress: progress)
                }
                DispatchQueue.main.async { self.finishTest(task, result: result) }
            }
        }
    }

    private func elapsed(_ task: ArchiveTask) -> String {
        let s = Date().timeIntervalSince(task.startedAt)
        return s < 1 ? "不到 1 秒" : s < 60 ? "\(Int(s)) 秒" : "\(Int(s) / 60) 分 \(Int(s) % 60) 秒"
    }

    private func finishExtract(_ task: ArchiveTask, src: ArchiveSource, req: ExtractRequest,
                               result: Result<ExtractResult, Error>) {
        switch result {
        case .success(let r):
            task.state = .done
            task.progress = 1
            task.outputs = r.outputs
            var parts = ["\(r.fileCount) 个文件", elapsed(task)]
            if r.skipped > 0 { parts.append("跳过 \(r.skipped) 个不安全条目") }
            if r.usedSevenZip { parts.append("7-Zip") }
            if r.outputs.isEmpty { parts = ["压缩包是空的"] }
            task.summary = parts.joined(separator: " · ")
            if let pw = r.usedPassword {
                passwords.remember(pw, persist: task.rememberPassword && Prefs.bool(Prefs.rememberPasswords))
            }
            if req.trashArchive {
                for v in src.volumes { try? FileManager.default.trashItem(at: v, resultingItemURL: nil) }
            }
            if req.reveal && !r.outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(r.outputs)
            }
        case .failure(let error):
            handleFailure(task, error)
        }
        afterFinish()
    }

    private func finishCompress(_ task: ArchiveTask, req: CompressRequest, result: Result<[URL], Error>) {
        switch result {
        case .success(let outs):
            task.state = .done
            task.progress = 1
            task.outputs = outs
            let size = outs.reduce(Int64(0)) { $0 + FileManager.default.fileSize($1) }
            var parts = [ByteFormat.string(size), elapsed(task)]
            if outs.count > 1 { parts.insert("\(outs.count) 个分卷", at: 0) }
            if req.options.password != nil { parts.append("已加密") }
            task.summary = parts.joined(separator: " · ")
            if req.reveal { NSWorkspace.shared.activateFileViewerSelecting(outs) }
        case .failure(let error):
            handleFailure(task, error)
        }
        afterFinish()
    }

    private func finishTest(_ task: ArchiveTask, result: Result<TestReport, Error>) {
        switch result {
        case .success(let r):
            task.state = .done
            task.progress = 1
            task.summary = "完好无损 · \(r.fileCount) 个文件 · \(ByteFormat.string(r.bytes))"
            if let pw = r.usedPassword {
                passwords.remember(pw, persist: task.rememberPassword && Prefs.bool(Prefs.rememberPasswords))
            }
        case .failure(let error):
            handleFailure(task, error)
        }
        afterFinish()
    }

    private func handleFailure(_ task: ArchiveTask, _ error: Error) {
        switch error as? ArchiveError {
        case .cancelled?:
            task.state = .cancelled
        case .passwordRequired?:
            task.state = .needsPassword(wrong: false)
        case .wrongPassword?:
            task.state = .needsPassword(wrong: true)
        case .notWritable?:
            task.notWritable = true
            task.state = .failed(error.localizedDescription)
        default:
            task.state = .failed(error.localizedDescription)
        }
    }

    private func afterFinish() {
        refreshPrompt()
        pump()
        checkQuit()
    }

    private func checkQuit() {
        guard launchedForFiles, Prefs.bool(Prefs.quitAfterFinderOpen), !tasks.isEmpty,
              tasks.allSatisfy({ $0.state == .done }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if self.tasks.allSatisfy({ $0.state == .done }) { NSApp.terminate(nil) }
        }
    }

    // MARK: 位置

    private func extractDestination(for src: ArchiveSource, asked: inout URL?) -> URL? {
        switch Prefs.extractMode {
        case .sameFolder:
            if isWritable(src.directory) { return src.directory }
            return chooseFolder(message: "「\(src.fileName)」所在位置不能写入，请选择解压到哪里")
        case .ask:
            if let asked { return asked }
            asked = chooseFolder(message: "解压到…", start: src.directory)
            return asked
        case .fixed:
            let url = URL(fileURLWithPath: Prefs.string(Prefs.extractFixedPath))
            return isWritable(url) ? url : chooseFolder(message: "设置里的解压文件夹不可用，请重新选择")
        }
    }

    private func compressDestination(for items: [URL], asked: inout URL?) -> URL? {
        let parent = items[0].deletingLastPathComponent()
        switch Prefs.compressMode {
        case .sameFolder:
            if isWritable(parent) { return parent }
            return chooseFolder(message: "原位置不能写入，请选择压缩包保存到哪里")
        case .ask:
            if let asked { return asked }
            asked = chooseFolder(message: "压缩包保存到…", start: parent)
            return asked
        case .fixed:
            let url = URL(fileURLWithPath: Prefs.string(Prefs.compressFixedPath))
            return isWritable(url) ? url : chooseFolder(message: "设置里的保存文件夹不可用，请重新选择")
        }
    }

    /// 单个文件去掉扩展名，文件夹保留全名，多个项目用所在文件夹名（同 Bandizip）。
    private func archiveName(for items: [URL]) -> String {
        if items.count == 1 {
            let u = items[0]
            if FileManager.default.isDirectory(u) { return u.lastPathComponent }
            let stem = u.deletingPathExtension().lastPathComponent
            return stem.isEmpty ? u.lastPathComponent : stem
        }
        let parent = items[0].deletingLastPathComponent()
        let name = parent.lastPathComponent
        return (name.isEmpty || name == "/") ? "归档" : name
    }

    private func isWritable(_ url: URL) -> Bool {
        FileManager.default.isDirectory(url) && FileManager.default.isWritableFile(atPath: url.path)
    }

    func chooseFolder(message: String, start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let start { panel.directoryURL = start }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseFiles(archivesOnly: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.message = archivesOnly ? "选择要解压的压缩包" : "选择要压缩的文件或文件夹"
        panel.prompt = archivesOnly ? "解压" : "压缩"
        panel.canChooseFiles = true
        panel.canChooseDirectories = !archivesOnly
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}
