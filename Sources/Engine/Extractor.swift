import Foundation

enum FolderMode: String, CaseIterable, Identifiable, Codable {
    case smart, always, never

    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: return "智能（只有一个项目时直接放出，否则新建同名文件夹）"
        case .always: return "总是新建同名文件夹"
        case .never: return "直接解压到目标位置"
        }
    }
}

struct ExtractOptions {
    var destination: URL
    var folderMode: FolderMode = .smart
    var skipMacJunk = true
    var encoding: NameEncoding = .auto
    /// 用户这次亲手输入的密码。
    var password: String?
    /// 记住的密码，自动逐个尝试。
    var candidatePasswords: [String] = []
    /// 只解压这些路径（目录包含其下所有内容）。
    var selection: Set<String>?
    /// 输出时去掉的公共前缀目录。
    var stripPrefix: String?
    var propagateQuarantine = true
}

struct ExtractResult {
    var outputs: [URL] = []
    var fileCount = 0
    var skipped = 0
    var usedPassword: String?
    var usedSevenZip = false
}

struct TestReport {
    var fileCount = 0
    var bytes: Int64 = 0
    var usedPassword: String?
}

struct ArchiveListing {
    var items: [ArchiveItem]
    var formatName: String
    var isCompressedStream: Bool
    var hasEncrypted: Bool
    /// 非 nil 表示有非 Unicode 文件名，值是实际采用的编码。
    var legacyEncoding: String.Encoding?

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var fileCount: Int { items.lazy.filter { !$0.isDirectory }.count }
}

enum Extractor {

    // MARK: 列目录

    static func list(_ src: ArchiveSource, encoding: NameEncoding = .auto,
                     cancel: CancelToken? = nil) throws -> ArchiveListing {
        do {
            return try scan(src, encoding: encoding, raw: false, cancel: cancel)
        } catch ArchiveError.unsupportedFormat {
            return try scan(src, encoding: encoding, raw: true, cancel: cancel)
        }
    }

    private static func scan(_ src: ArchiveSource, encoding: NameEncoding, raw: Bool,
                             cancel: CancelToken?) throws -> ArchiveListing {
        let reader = try Reader.open(src.volumes, raw: raw)
        if raw && !reader.isCompressedStream { throw ArchiveError.unsupportedFormat }

        struct Pending { let name: RawName; let dir, link: Bool; let size: Int64; let date: Date?; let enc: Bool }
        var pending: [Pending] = []
        while let e = try reader.next() {
            try cancel?.check()
            let name: RawName = raw ? .text(src.displayName) : (reader.rawName(e) ?? .text("未命名"))
            pending.append(Pending(name: name, dir: EntryInfo.isDirectory(e), link: EntryInfo.isSymlink(e),
                                   size: EntryInfo.size(e), date: EntryInfo.modified(e),
                                   enc: archive_entry_is_encrypted(e) != 0))
            if raw { break }
        }

        let legacy = pending.compactMap { p -> [UInt8]? in
            if case .bytes(let b) = p.name { return b }
            return nil
        }
        let chosen: String.Encoding? = legacy.isEmpty ? nil : (encoding.encoding ?? Charset.detect(legacy))

        var items: [ArchiveItem] = []
        for (i, p) in pending.enumerated() {
            guard let path = PathSanitizer.clean(Charset.decode(p.name, using: chosen),
                                                 windowsSeparators: reader.isZip) else { continue }
            items.append(ArchiveItem(id: i, path: path, isDirectory: p.dir, isSymlink: p.link,
                                     size: p.size, modified: p.date, encrypted: p.enc))
        }

        var format = raw ? reader.filterName.uppercased() : reader.formatName
        if reader.isCompressedStream && !raw { format += " + " + reader.filterName }
        return ArchiveListing(items: items, formatName: format, isCompressedStream: reader.isCompressedStream,
                              hasEncrypted: items.contains { $0.encrypted }, legacyEncoding: chosen)
    }

    // MARK: 解压

    static func extract(_ src: ArchiveSource, options: ExtractOptions, cancel: CancelToken,
                        progress: @escaping ProgressHandler) throws -> ExtractResult {
        let fm = FileManager.default
        let tmp = options.destination.appendingPathComponent(".qingya-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        } catch {
            throw ArchiveError.notWritable(options.destination.path)
        }

        var result = ExtractResult()
        do {
            do {
                progress(-1, "正在读取压缩包…")
                let plan = try prepare(src, options: options, cancel: cancel)
                result.usedPassword = plan.password
                try run(src, plan: plan, options: options, root: tmp, result: &result,
                        cancel: cancel, progress: progress)
            } catch let error as ArchiveError
                        where (error == .unsupportedEncryption || error == .unsupportedFormat)
                        && SevenZip.isAvailable && options.selection == nil {
                try? fm.removeItem(at: tmp)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
                result = ExtractResult()
                result.usedPassword = try SevenZip.extractTrying(src, into: tmp, options: options,
                                                                 cancel: cancel, progress: progress)
                result.usedSevenZip = true
                result.fileCount = countFiles(in: tmp)
            }
            try cancel.check()
            result.outputs = try finalize(tmp: tmp, destination: options.destination,
                                          name: src.displayName, mode: options.folderMode)
            return result
        } catch {
            try? fm.removeItem(at: tmp)
            if case ArchiveError.wrongPassword = error, options.password == nil {
                throw ArchiveError.passwordRequired
            }
            throw error
        }
    }

    /// 完整读一遍所有数据但不落盘，校验 CRC / 密码 / 截断。
    static func test(_ src: ArchiveSource, password: String?, candidates: [String],
                     cancel: CancelToken, progress: @escaping ProgressHandler) throws -> TestReport {
        var options = ExtractOptions(destination: URL(fileURLWithPath: NSTemporaryDirectory()))
        options.password = password
        options.candidatePasswords = candidates
        options.skipMacJunk = false
        do {
            let plan = try prepare(src, options: options, cancel: cancel)
            var result = ExtractResult()
            let bytes = try run(src, plan: plan, options: options, root: nil, result: &result,
                                cancel: cancel, progress: progress)
            return TestReport(fileCount: result.fileCount, bytes: bytes, usedPassword: plan.password)
        } catch ArchiveError.wrongPassword where password == nil {
            throw ArchiveError.passwordRequired
        }
    }

    // MARK: 内部

    private struct Plan {
        var raw = false
        var encoding: String.Encoding?
        var totalBytes: Int64?
        var passwords: [String] = []
        var password: String?
        var windowsSeparators = false
    }

    private static func prepare(_ src: ArchiveSource, options: ExtractOptions,
                                cancel: CancelToken) throws -> Plan {
        let first: Reader
        do {
            first = try Reader.open(src.volumes)
        } catch ArchiveError.unsupportedFormat {
            let r = try Reader.open(src.volumes, raw: true)
            guard try r.next() != nil, r.isCompressedStream else { throw ArchiveError.unsupportedFormat }
            return Plan(raw: true)
        }

        // tar.gz 之类只能顺序读：不预扫描，进度按已读压缩字节算，密码全交给 libarchive 自己试。
        if first.isCompressedStream {
            var plan = Plan()
            plan.encoding = options.encoding.encoding
            plan.passwords = orderedPasswords(options)
            plan.password = options.password
            return plan
        }

        // zip / 7z / rar 等：目录区读起来很快，先扫一遍拿到编码、总大小、加密情况。
        let listing = try list(src, encoding: options.encoding, cancel: cancel)
        var plan = Plan()
        plan.encoding = listing.legacyEncoding
        plan.windowsSeparators = first.isZip
        let chosen = listing.items.filter { item in
            !item.isDirectory && (options.selection.map { isSelected(item.path, $0) } ?? true)
        }
        plan.totalBytes = chosen.reduce(0) { $0 + $1.size }

        if chosen.contains(where: { $0.encrypted }) || listing.hasEncrypted {
            let pw = try resolvePassword(src, options: options, cancel: cancel)
            plan.passwords = [pw]
            plan.password = pw
        }
        return plan
    }

    private static func orderedPasswords(_ options: ExtractOptions) -> [String] {
        var seen = Set<String>()
        return ([options.password].compactMap { $0 } + options.candidatePasswords)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func resolvePassword(_ src: ArchiveSource, options: ExtractOptions,
                                        cancel: CancelToken) throws -> String {
        for pw in orderedPasswords(options).prefix(60) {
            try cancel.check()
            if try probe(src, password: pw) { return pw }
        }
        throw options.password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
    }

    /// 用第一个加密文件验证密码。传统 ZipCrypto 的校验字节有 1/256 误判，
    /// 所以小文件整个读完让 CRC 把关。
    private static func probe(_ src: ArchiveSource, password: String) throws -> Bool {
        let reader = try Reader.open(src.volumes, passwords: [password])
        while let e = try reader.next() {
            guard archive_entry_is_encrypted(e) != 0, EntryInfo.isRegular(e), EntryInfo.size(e) > 0 else { continue }
            var buf: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            var read: Int64 = 0
            while read < 8 << 20 {
                let r = archive_read_data_block(reader.handle, &buf, &size, &offset)
                if r == ARCHIVE_EOF { return true }
                if r < ARCHIVE_WARN {
                    switch LA.classify(reader.errorText) {
                    case .wrongPassword, .passwordRequired: return false
                    case .unsupportedEncryption: throw ArchiveError.unsupportedEncryption
                    default: return false
                    }
                }
                read += Int64(size)
            }
            return true
        }
        return true
    }

    static func isSelected(_ path: String, _ selection: Set<String>) -> Bool {
        if selection.contains(path) { return true }
        var p = path as NSString
        while p.length > 0 {
            p = p.deletingLastPathComponent as NSString
            if selection.contains(p as String) { return true }
        }
        return false
    }

    /// root 为 nil 时只读不写（测试模式）。返回读出的字节数。
    @discardableResult
    private static func run(_ src: ArchiveSource, plan: Plan, options: ExtractOptions, root: URL?,
                            result: inout ExtractResult, cancel: CancelToken,
                            progress: @escaping ProgressHandler) throws -> Int64 {
        let reader = try Reader.open(src.volumes, passwords: plan.passwords, raw: plan.raw)

        var disk: OpaquePointer?
        if root != nil {
            disk = archive_write_disk_new()
            archive_write_disk_set_options(disk, QY_EXTRACT_TIME | QY_EXTRACT_SECURE_SYMLINKS | QY_EXTRACT_SECURE_NODOTDOT)
            archive_write_disk_set_standard_lookup(disk)
        }
        defer { if let disk { archive_write_free(disk) } }

        let quarantine = (root != nil && options.propagateQuarantine) ? Quarantine.read(src.url) : nil
        if let q = quarantine, let root { Quarantine.apply(q, to: root.path) }

        let archiveSize = max(src.totalSize, 1)
        let throttle = Throttle()
        var done: Int64 = 0
        let rootPath = root?.path ?? ""

        func report(_ name: String) {
            guard throttle.ready() else { return }
            let fraction: Double
            if let total = plan.totalBytes, total > 0 {
                fraction = Double(done) / Double(total)
            } else {
                fraction = Double(reader.compressedBytesRead) / Double(archiveSize)
            }
            progress(min(1, fraction), name)
        }

        func relative(_ raw: RawName) -> String? {
            PathSanitizer.clean(Charset.decode(raw, using: plan.encoding), windowsSeparators: plan.windowsSeparators)
        }

        func stripped(_ rel: String) -> String? {
            guard let prefix = options.stripPrefix, !prefix.isEmpty else { return rel }
            guard rel.hasPrefix(prefix + "/") else { return nil }
            return String(rel.dropFirst(prefix.count + 1))
        }

        while let entry = try reader.next() {
            try cancel.check()

            let rel: String
            if plan.raw {
                rel = src.displayName
            } else {
                guard let raw = reader.rawName(entry), let r = relative(raw) else {
                    result.skipped += 1
                    continue
                }
                rel = r
            }
            if options.skipMacJunk && PathSanitizer.isMacJunk(rel) { continue }
            if let sel = options.selection, !isSelected(rel, sel) { continue }
            guard let outRel = stripped(rel) else { continue }
            let isDir = EntryInfo.isDirectory(entry)

            if let disk {
                let target = rootPath + "/" + outRel
                archive_entry_set_pathname_utf8(entry, target)
                if let raw = reader.rawHardlink(entry) {
                    guard let linkRel = relative(raw).flatMap(stripped) else { result.skipped += 1; continue }
                    archive_entry_set_hardlink_utf8(entry, rootPath + "/" + linkRel)
                }
                if let raw = reader.rawSymlink(entry) {
                    archive_entry_set_symlink_utf8(entry, Charset.decode(raw, using: plan.encoding))
                }
                let r = archive_write_header(disk, entry)
                if r == ARCHIVE_FATAL {
                    throw ArchiveError.failed("写入「\(outRel)」失败：\(LA.errorText(disk))")
                }
                if r < ARCHIVE_WARN { result.skipped += 1; continue }
            }

            if EntryInfo.isRegular(entry) {
                var buf: UnsafeRawPointer?
                var size = 0
                var offset: Int64 = 0
                while true {
                    let r = archive_read_data_block(reader.handle, &buf, &size, &offset)
                    if r == ARCHIVE_EOF { break }
                    if r < ARCHIVE_WARN {
                        let error = LA.classify(reader.errorText)
                        switch error {
                        case .passwordRequired, .wrongPassword, .unsupportedEncryption: throw error
                        default: throw ArchiveError.failed("「\(outRel)」出错：\(error.localizedDescription)")
                        }
                    }
                    if size > 0, let disk, archive_write_data_block(disk, buf, size, offset) < ARCHIVE_WARN {
                        throw ArchiveError.failed("写入「\(outRel)」失败：\(LA.errorText(disk))")
                    }
                    done += Int64(size)
                    try cancel.check()
                    report(outRel)
                }
            }

            if let disk {
                if archive_write_finish_entry(disk) == ARCHIVE_FATAL {
                    throw ArchiveError.failed("写入「\(outRel)」失败：\(LA.errorText(disk))")
                }
                if let q = quarantine { Quarantine.apply(q, to: rootPath + "/" + outRel) }
            }
            if !isDir { result.fileCount += 1 }
            report(outRel)
        }

        if let disk, archive_write_close(disk) < ARCHIVE_WARN {
            throw ArchiveError.failed("收尾失败：\(LA.errorText(disk))")
        }
        return done
    }

    /// 临时目录 → 最终位置。永不覆盖已有文件，重名时自动加序号。
    static func finalize(tmp: URL, destination: URL, name: String, mode: FolderMode) throws -> [URL] {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        guard !items.isEmpty else {
            try? fm.removeItem(at: tmp)
            return []
        }

        func moveOut(_ item: URL) throws -> URL {
            let target = fm.uniqueURL(in: destination, name: item.lastPathComponent, isDirectory: fm.isDirectory(item))
            try fm.moveItem(at: item, to: target)
            return target
        }

        func wrapInFolder() throws -> URL {
            let target = fm.uniqueURL(in: destination, name: name, isDirectory: true)
            try fm.moveItem(at: tmp, to: target)
            return target
        }

        switch mode {
        case .smart where items.count == 1,
             .always where items.count == 1 && items[0].lastPathComponent == name && fm.isDirectory(items[0]):
            let out = try moveOut(items[0])
            try? fm.removeItem(at: tmp)
            return [out]
        case .smart, .always:
            return [try wrapInFolder()]
        case .never:
            let outs = try items.map(moveOut)
            try? fm.removeItem(at: tmp)
            return outs
        }
    }

    private static func countFiles(in dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var n = 0
        for case let url as URL in e where !((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) {
            n += 1
        }
        return n
    }
}

/// 从网上下载的压缩包带隔离属性；解压出来的东西也要带上，Gatekeeper 才会照常检查。
/// 系统「归档实用工具」和 The Unarchiver 都这样做。
enum Quarantine {
    static let key = "com.apple.quarantine"

    static func read(_ url: URL) -> [UInt8]? {
        let len = getxattr(url.path, key, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        let n = getxattr(url.path, key, &buf, len, 0, 0)
        return n > 0 ? Array(buf.prefix(n)) : nil
    }

    static func apply(_ value: [UInt8], to path: String) {
        _ = setxattr(path, key, value, value.count, 0, XATTR_NOFOLLOW)
    }
}
