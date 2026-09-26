import Foundation

/// 一个待解压的压缩包；分卷压缩包会带上所有卷。
struct ArchiveSource: Hashable, Identifiable {
    let url: URL
    let volumes: [URL]

    var id: URL { volumes.first ?? url }
    var fileName: String { url.lastPathComponent }
    var displayName: String { ArchiveKind.baseName(of: volumes.first ?? url) }
    var directory: URL { url.deletingLastPathComponent() }
    var totalSize: Int64 { volumes.reduce(0) { $0 + FileManager.default.fileSize($1) } }

    init(_ url: URL) {
        let volumes = ArchiveKind.volumes(for: url)
        self.url = volumes.first ?? url
        self.volumes = volumes
    }
}

enum ArchiveKind {
    /// 这些扩展名被当成压缩包（拖进窗口、双击时走解压）。
    static let extensions: Set<String> = [
        "zip", "zipx", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz",
        "zst", "tzst", "lz4", "lzma", "tlz", "z", "taz", "cab", "iso", "lzh", "lha",
        "cpio", "xar", "cbz", "cbr", "cb7", "deb", "rpm", "ar", "warc"
    ]

    /// 用于从文件名里剥掉的「压缩」后缀，剥完得到解压文件夹名。
    private static let strippable: Set<String> = extensions.union(["001"])

    static func isArchive(_ url: URL) -> Bool {
        guard !FileManager.default.isDirectory(url) else { return false }
        let name = url.lastPathComponent.lowercased()
        if name.range(of: #"\.(\d{3}|r\d{2})$"#, options: .regularExpression) != nil { return true }
        return extensions.contains(url.pathExtension.lowercased())
    }

    static func baseName(of url: URL) -> String {
        var name = url.lastPathComponent
        for pattern in [#"\.\d{3}$"#, #"\.part\d+\.rar$"#] {
            if let r = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                name.removeSubrange(r)
            }
        }
        while true {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, strippable.contains(ext) else { break }
            let stripped = (name as NSString).deletingPathExtension
            guard !stripped.isEmpty else { break }
            name = stripped
        }
        return name.isEmpty ? "解压结果" : name
    }

    /// 找齐分卷：`x.7z.001/.002…`、`x.part1.rar/part2…`、`x.rar + x.r00/r01…`。
    static func volumes(for url: URL) -> [URL] {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent

        func collect(_ make: (Int) -> String, from start: Int) -> [URL] {
            var result: [URL] = []
            var i = start
            while true {
                let candidate = dir.appendingPathComponent(make(i))
                guard fm.fileExists(atPath: candidate.path) else { break }
                result.append(candidate)
                i += 1
            }
            return result
        }

        if let m = name.firstMatch(#"^(.*)\.(\d{3})$"#) {
            let base = m[1]
            let found = collect({ base + String(format: ".%03d", $0) }, from: 1)
            return found.isEmpty ? [url] : found
        }

        if let m = name.firstMatch(#"^(.*)\.part(\d+)\.rar$"#, caseInsensitive: true) {
            let base = m[1], width = m[2].count
            let ext = (name as NSString).pathExtension
            let found = collect({ base + ".part" + String(format: "%0\(width)d", $0) + "." + ext }, from: 1)
            return found.isEmpty ? [url] : found
        }

        let lower = name.lowercased()
        if lower.range(of: #"\.r\d{2}$"#, options: .regularExpression) != nil {
            let rar = url.deletingPathExtension().appendingPathExtension("rar")
            if fm.fileExists(atPath: rar.path) { return volumes(for: rar) }
        }
        if lower.hasSuffix(".rar") {
            let stem = url.deletingPathExtension().lastPathComponent
            let old = collect({ stem + String(format: ".r%02d", $0) }, from: 0)
            return [url] + old
        }
        return [url]
    }
}

extension String {
    /// 返回整体及各捕获组。
    func firstMatch(_ pattern: String, caseInsensitive: Bool = false) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }
}

// MARK: - 压缩格式

enum ArchiveFormat: String, CaseIterable, Identifiable, Codable {
    case zip, sevenZip = "7z", tar, tgz = "tar.gz", tbz = "tar.bz2", txz = "tar.xz"

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7Z"
        case .tar: return "TAR"
        case .tgz: return "TAR.GZ"
        case .tbz: return "TAR.BZ2"
        case .txz: return "TAR.XZ"
        }
    }

    var hint: String {
        switch self {
        case .zip: return "兼容性最好，Windows / 手机都能直接打开"
        case .sevenZip: return "压缩率高，对方需要 7-Zip / 解压软件"
        case .tar: return "只打包不压缩，保留权限，速度最快"
        case .tgz: return "Linux / 服务器常用，兼容性好"
        case .tbz: return "比 gzip 小一点，也慢一点"
        case .txz: return "压缩率很高，适合大文件归档"
        }
    }

    var supportsLevel: Bool { self != .tar }
    var supportsStore: Bool { self == .zip || self == .sevenZip }

    /// zip 用 libarchive 的 AES-256；7z 加密需要外部 7-Zip。
    var supportsPassword: Bool {
        switch self {
        case .zip: return true
        case .sevenZip: return SevenZip.isAvailable
        default: return false
        }
    }
}

enum CompressionLevel: Int, CaseIterable, Identifiable, Codable {
    case store = 0, fast = 1, normal = 5, best = 9

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .store: return "仅存储"
        case .fast: return "快速"
        case .normal: return "标准"
        case .best: return "最高"
        }
    }
}
