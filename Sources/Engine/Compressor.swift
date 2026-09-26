import Foundation

struct CompressOptions {
    var format: ArchiveFormat = .zip
    var level: CompressionLevel = .normal
    var password: String?
    /// 每卷字节数；nil 不分卷。分卷命名同 7-Zip：`x.zip.001`、`x.zip.002`…
    var volumeSize: Int64?
    var excludeJunk = true
}

enum Compressor {
    /// 这些东西不该进压缩包：Finder 元数据、资源分叉、Spotlight/回收站目录。
    static let junkNames: Set<String> = [".DS_Store", "__MACOSX", ".Spotlight-V100", ".Trashes",
                                         ".fseventsd", ".TemporaryItems", "Icon\r", ".localized"]

    static func isJunk(_ name: String) -> Bool {
        junkNames.contains(name) || name.hasPrefix("._")
    }

    /// 压缩 items 到 output（最终路径，已去重）。返回生成的文件（分卷时多个）。
    static func compress(_ items: [URL], to output: URL, options: CompressOptions, cancel: CancelToken,
                         progress: @escaping ProgressHandler) throws -> [URL] {
        let fm = FileManager.default
        let destination = output.deletingLastPathComponent()
        let tmp = destination.appendingPathComponent(".qingya-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        } catch {
            throw ArchiveError.notWritable(destination.path)
        }
        defer { try? fm.removeItem(at: tmp) }

        let staged: [URL]
        if options.format == .sevenZip && (options.password?.isEmpty == false || options.volumeSize != nil)
            && SevenZip.isAvailable {
            staged = try SevenZip.compress(items, to: tmp.appendingPathComponent(output.lastPathComponent),
                                           options: options, cancel: cancel, progress: progress)
        } else {
            staged = try compressWithLibarchive(items, into: tmp, name: output.lastPathComponent,
                                                options: options, excluding: tmp, cancel: cancel, progress: progress)
        }
        try cancel.check()

        // 分卷只有一卷时去掉 .001 后缀。
        if staged.count == 1 {
            let target = fm.uniqueURL(in: destination, name: output.lastPathComponent, isDirectory: false)
            try fm.moveItem(at: staged[0], to: target)
            return [target]
        }
        var outs: [URL] = []
        for url in staged {
            let target = fm.uniqueURL(in: destination, name: url.lastPathComponent, isDirectory: false)
            try fm.moveItem(at: url, to: target)
            outs.append(target)
        }
        return outs
    }

    // MARK: 收集文件

    struct Record {
        let url: URL
        let path: String
        let kind: Kind
        let size: Int64
        let modified: Date?
        let permissions: Int

        enum Kind { case file, directory, symlink(String) }
    }

    static func collect(_ items: [URL], excludeJunk: Bool, excluding: URL?,
                        cancel: CancelToken) throws -> [Record] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let fm = FileManager.default
        var records: [Record] = []
        let excludedPath = excluding?.standardizedFileURL.path

        func record(_ url: URL, path: String) -> Record? {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let perms = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0o644
            if v.isSymbolicLink == true {
                let dest = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                return Record(url: url, path: path, kind: .symlink(dest), size: 0, modified: v.contentModificationDate, permissions: perms)
            }
            if v.isDirectory == true {
                return Record(url: url, path: path, kind: .directory, size: 0, modified: v.contentModificationDate, permissions: perms)
            }
            return Record(url: url, path: path, kind: .file, size: Int64(v.fileSize ?? 0),
                          modified: v.contentModificationDate, permissions: perms)
        }

        for item in items {
            let top = item.lastPathComponent
            guard let root = record(item, path: top) else {
                throw ArchiveError.failed("无法读取「\(top)」")
            }
            records.append(root)
            guard case .directory = root.kind else { continue }

            let base = item.standardizedFileURL.path
            guard let walker = fm.enumerator(at: item, includingPropertiesForKeys: keys, options: [],
                                             errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker {
                try cancel.check()
                let name = url.lastPathComponent
                let full = url.standardizedFileURL.path
                if (excludeJunk && isJunk(name)) || full == excludedPath {
                    // 对文件调用 skipDescendants 会跳过「最近进入的目录」，只能对目录用。
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        walker.skipDescendants()
                    }
                    continue
                }
                guard full.hasPrefix(base + "/") else { continue }
                let rel = top + "/" + String(full.dropFirst(base.count + 1))
                if let r = record(url, path: rel) { records.append(r) }
            }
        }
        return records
    }

    // MARK: libarchive 写

    private static func compressWithLibarchive(_ items: [URL], into dir: URL, name: String,
                                               options: CompressOptions, excluding: URL,
                                               cancel: CancelToken,
                                               progress: @escaping ProgressHandler) throws -> [URL] {
        _ = LA.setup
        progress(-1, "正在统计文件…")
        let records = try collect(items, excludeJunk: options.excludeJunk, excluding: excluding, cancel: cancel)
        let total = max(records.reduce(Int64(0)) { $0 + $1.size }, 1)

        guard let a = archive_write_new() else { throw ArchiveError.failed("内存不足") }
        defer { archive_write_free(a) }
        try configure(a, options)

        let sink = VolumeSink(dir: dir, name: name, volumeSize: options.volumeSize)
        let context = Unmanaged.passUnretained(sink).toOpaque()
        let opened = archive_write_open2(a, context, nil, { _, ctx, buffer, length in
            let sink = Unmanaged<VolumeSink>.fromOpaque(ctx!).takeUnretainedValue()
            do {
                try sink.write(buffer!, length)
                return length
            } catch {
                sink.error = error
                return -1
            }
        }, { _, ctx in
            Unmanaged<VolumeSink>.fromOpaque(ctx!).takeUnretainedValue().close()
            return ARCHIVE_OK
        }, nil)

        return try withExtendedLifetime(sink) {
            guard opened == ARCHIVE_OK else { throw ArchiveError.failed("无法创建压缩包：\(LA.errorText(a))") }

            let throttle = Throttle()
            var done: Int64 = 0
            let chunk = 1 << 20

            for r in records {
                try cancel.check()
                guard let entry = archive_entry_new() else { throw ArchiveError.failed("内存不足") }
                defer { archive_entry_free(entry) }

                archive_entry_set_pathname_utf8(entry, r.path)
                archive_entry_set_perm(entry, mode_t(r.permissions & 0o7777))
                if let m = r.modified {
                    let t = m.timeIntervalSince1970
                    archive_entry_set_mtime(entry, time_t(t), Int((t - floor(t)) * 1e9))
                }
                switch r.kind {
                case .directory:
                    archive_entry_set_filetype(entry, UInt32(QY_AE_IFDIR))
                case .symlink(let target):
                    archive_entry_set_filetype(entry, UInt32(QY_AE_IFLNK))
                    archive_entry_set_symlink_utf8(entry, target)
                case .file:
                    archive_entry_set_filetype(entry, UInt32(QY_AE_IFREG))
                    archive_entry_set_size(entry, r.size)
                }

                if archive_write_header(a, entry) < ARCHIVE_WARN {
                    throw sink.error ?? ArchiveError.failed("写入「\(r.path)」失败：\(LA.errorText(a))")
                }

                if case .file = r.kind, r.size > 0 {
                    guard let fh = try? FileHandle(forReadingFrom: r.url) else {
                        throw ArchiveError.failed("无法读取「\(r.path)」，可能没有权限")
                    }
                    defer { try? fh.close() }
                    while let data = try fh.read(upToCount: chunk), !data.isEmpty {
                        let written = data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }
                        if written < 0 {
                            throw sink.error ?? ArchiveError.failed("写入「\(r.path)」失败：\(LA.errorText(a))")
                        }
                        done += Int64(data.count)
                        try cancel.check()
                        if throttle.ready() { progress(Double(done) / Double(total), r.path) }
                    }
                }
                if throttle.ready() { progress(Double(done) / Double(total), r.path) }
            }

            if archive_write_close(a) < ARCHIVE_WARN {
                throw sink.error ?? ArchiveError.failed("收尾失败：\(LA.errorText(a))")
            }
            if let error = sink.error { throw error }
            progress(1, "")
            return sink.files
        }
    }

    private static func configure(_ a: OpaquePointer, _ o: CompressOptions) throws {
        func option(_ s: String, required: Bool = true) throws {
            if archive_write_set_options(a, s) < ARCHIVE_WARN && required {
                throw ArchiveError.failed("压缩参数无效（\(s)）：\(LA.errorText(a))")
            }
        }
        let level = o.level

        switch o.format {
        case .zip:
            archive_write_set_format_zip(a)
            archive_write_add_filter_none(a)
            if level == .store {
                try option("zip:compression=store")
            } else {
                try option("zip:compression=deflate")
                try option("zip:compression-level=\(level == .normal ? 6 : level.rawValue)")
            }
            if let pw = o.password, !pw.isEmpty {
                try option("zip:encryption=aes256")
                archive_write_set_passphrase(a, pw)
            }
        case .sevenZip:
            archive_write_set_format_7zip(a)
            archive_write_add_filter_none(a)
            if level == .store {
                try option("7zip:compression=copy")
            } else {
                try option("7zip:compression=lzma2")
                try option("7zip:compression-level=\(level == .normal ? 6 : level.rawValue)")
            }
        case .tar, .tgz, .tbz, .txz:
            archive_write_set_format_pax_restricted(a)
            archive_write_set_bytes_in_last_block(a, 1)
            let lv = level == .store ? CompressionLevel.fast : level
            switch o.format {
            case .tgz:
                archive_write_add_filter_gzip(a)
                try option("gzip:compression-level=\(lv == .normal ? 6 : lv.rawValue)")
            case .tbz:
                archive_write_add_filter_bzip2(a)
                try option("bzip2:compression-level=\(lv == .normal ? 6 : lv.rawValue)")
            case .txz:
                archive_write_add_filter_xz(a)
                try option("xz:compression-level=\(lv == .normal ? 6 : lv.rawValue)")
                try option("xz:threads=0", required: false)
            default:
                archive_write_add_filter_none(a)
            }
        }
    }
}

/// 把 libarchive 输出的字节流写成一个或多个分卷文件。
final class VolumeSink {
    let dir: URL
    let name: String
    let volumeSize: Int64?
    private(set) var files: [URL] = []
    var error: Error?

    private var handle: FileHandle?
    private var written: Int64 = 0

    init(dir: URL, name: String, volumeSize: Int64?) {
        self.dir = dir
        self.name = name
        self.volumeSize = volumeSize.flatMap { $0 > 0 ? $0 : nil }
    }

    func write(_ buffer: UnsafeRawPointer, _ length: Int) throws {
        var offset = 0
        while offset < length {
            if handle == nil || (volumeSize.map { written >= $0 } ?? false) { try rotate() }
            var count = length - offset
            if let limit = volumeSize { count = min(count, Int(limit - written)) }
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer + offset), count: count, deallocator: .none)
            do {
                try handle!.write(contentsOf: data)
            } catch {
                throw ArchiveError.failed("写入压缩包失败，磁盘空间可能不足")
            }
            written += Int64(count)
            offset += count
        }
    }

    private func rotate() throws {
        try handle?.close()
        let fileName = volumeSize == nil ? name : name + String(format: ".%03d", files.count + 1)
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else {
            throw ArchiveError.notWritable(dir.deletingLastPathComponent().path)
        }
        handle = h
        files.append(url)
        written = 0
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
