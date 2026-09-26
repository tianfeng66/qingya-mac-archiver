import Foundation

/// libarchive 读句柄的薄封装。
final class Reader {
    let handle: OpaquePointer

    private init(_ handle: OpaquePointer) { self.handle = handle }

    deinit { archive_read_free(handle) }

    /// - Parameter raw: 只启用 raw 格式，用来解单个 `.gz` / `.xz` 这类「压缩的单文件」。
    static func open(_ volumes: [URL], passwords: [String] = [], raw: Bool = false) throws -> Reader {
        _ = LA.setup
        guard let a = archive_read_new() else { throw ArchiveError.failed("内存不足") }
        archive_read_support_filter_all(a)
        if raw {
            archive_read_support_format_raw(a)
        } else {
            archive_read_support_format_all(a)
            archive_read_support_format_empty(a)
            // 让没有 UTF-8 标记的 zip 文件名按字节原样透出（Latin-1 一一映射），编码由我们自己判断。
            _ = archive_read_set_options(a, "zip:hdrcharset=ISO-8859-1")
        }
        for p in passwords { archive_read_add_passphrase(a, p) }

        var paths: [UnsafeMutablePointer<CChar>?] = volumes.map { strdup($0.path) }
        defer { paths.forEach { free($0) } }
        paths.append(nil)
        let r = paths.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                archive_read_open_filenames(a, $0, 1 << 16)
            }
        }
        if r != ARCHIVE_OK {
            let message = LA.errorText(a)
            archive_read_free(a)
            throw LA.classify(message)
        }
        return Reader(a)
    }

    /// 读下一个条目头；到末尾返回 nil。
    func next() throws -> OpaquePointer? {
        var entry: OpaquePointer?
        while true {
            switch archive_read_next_header(handle, &entry) {
            case ARCHIVE_OK, ARCHIVE_WARN: return entry
            case ARCHIVE_EOF: return nil
            case ARCHIVE_RETRY: continue
            default: throw LA.classify(LA.errorText(handle))
            }
        }
    }

    var errorText: String { LA.errorText(handle) }
    var formatCode: Int32 { archive_format(handle) & LA.formatMask }
    var isZip: Bool { formatCode == LA.formatZip }
    var formatName: String { LA.string(archive_format_name(handle)) ?? "未知" }

    /// 有外层压缩流（tar.gz 等）时 >1。这类包只能顺序读，预扫描等于解压一遍。
    var isCompressedStream: Bool { archive_filter_count(handle) > 1 }
    var filterName: String { LA.string(archive_filter_name(handle, 0)) ?? "" }
    var compressedBytesRead: Int64 { archive_filter_bytes(handle, -1) }

    func rawName(_ entry: OpaquePointer) -> RawName? {
        guard let p = archive_entry_pathname(entry) else {
            return LA.string(archive_entry_pathname_utf8(entry)).map { .text($0.precomposed) }
        }
        return rawText(p)
    }

    /// 链接目标和文件名走同一套编码规则。
    func rawSymlink(_ entry: OpaquePointer) -> RawName? {
        archive_entry_symlink(entry).map(rawText)
    }

    func rawHardlink(_ entry: OpaquePointer) -> RawName? {
        archive_entry_hardlink(entry).map(rawText)
    }

    private func rawText(_ p: UnsafePointer<CChar>) -> RawName {
        let bytes = Array(UnsafeRawBufferPointer(start: p, count: strlen(p)))
        let text = String(bytes: bytes, encoding: .utf8)

        if isZip, let text {
            let normalized = text.precomposed
            let scalars = normalized.unicodeScalars
            if scalars.contains(where: { $0.value >= 0x80 }) && scalars.allSatisfy({ $0.value <= 0xFF }) {
                let original = scalars.map { UInt8($0.value) }
                if let utf8 = String(bytes: original, encoding: .utf8) { return .text(utf8.precomposed) }
                return .bytes(original)
            }
            return .text(normalized)
        }
        if let text { return .text(text.precomposed) }
        return .bytes(bytes)
    }
}

// MARK: - 条目信息

struct ArchiveItem: Identifiable, Hashable {
    let id: Int
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date?
    let encrypted: Bool

    var name: String { (path as NSString).lastPathComponent }
}

enum EntryInfo {
    static func type(_ e: OpaquePointer) -> Int32 { Int32(archive_entry_filetype(e)) & QY_AE_IFMT }
    static func isDirectory(_ e: OpaquePointer) -> Bool { type(e) == QY_AE_IFDIR }
    static func isRegular(_ e: OpaquePointer) -> Bool { type(e) == QY_AE_IFREG }
    static func isSymlink(_ e: OpaquePointer) -> Bool { type(e) == QY_AE_IFLNK }
    static func size(_ e: OpaquePointer) -> Int64 {
        archive_entry_size_is_set(e) != 0 ? archive_entry_size(e) : 0
    }
    static func modified(_ e: OpaquePointer) -> Date? {
        archive_entry_mtime_is_set(e) != 0 ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(e))) : nil
    }
}

/// 把压缩包里的路径变成安全的相对路径；含 `..` 的直接拒绝（Zip Slip）。
enum PathSanitizer {
    static func clean(_ path: String, windowsSeparators: Bool) -> String? {
        let p = windowsSeparators ? path.replacingOccurrences(of: "\\", with: "/") : path
        var parts: [String] = []
        for comp in p.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { return nil }
            parts.append(String(comp))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// macOS 打包时顺带塞进去的资源分叉和 Finder 元数据。
    static func isMacJunk(_ relative: String) -> Bool {
        let comps = relative.split(separator: "/")
        if comps.first == "__MACOSX" { return true }
        guard let last = comps.last else { return false }
        return last.hasPrefix("._")
    }
}
