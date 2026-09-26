import Foundation

enum ArchiveError: LocalizedError, Equatable {
    case cancelled
    case passwordRequired
    case wrongPassword
    case unsupportedEncryption
    case unsupportedFormat
    case notWritable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消"
        case .passwordRequired: return "需要密码"
        case .wrongPassword: return "密码不正确"
        case .unsupportedEncryption:
            return SevenZip.isAvailable
                ? "7-Zip 也无法解开这种加密"
                : "这种加密（常见于 RAR / 7z）系统自带引擎不支持。安装 7-Zip 后会自动启用：brew install sevenzip"
        case .unsupportedFormat: return "无法识别的压缩格式，或文件已损坏"
        case .notWritable(let path): return "没有权限写入「\(path)」"
        case .failed(let message): return message
        }
    }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var onCancel: [() -> Void] = []

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        let handlers = onCancel
        onCancel = []
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// 取消时立即回调（用于结束外部进程）。已取消则马上执行。
    func whenCancelled(_ handler: @escaping () -> Void) {
        lock.lock()
        if flag { lock.unlock(); handler(); return }
        onCancel.append(handler)
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw ArchiveError.cancelled }
    }
}

/// fraction 为 0...1；无法估算时传负数。
typealias ProgressHandler = (_ fraction: Double, _ detail: String) -> Void

enum LA {
    static let setup: Void = {
        // GUI 进程默认是 C locale，libarchive 在这种环境下转不了非 ASCII 文件名。
        setlocale(LC_CTYPE, "UTF-8")
    }()

    static let formatMask: Int32 = 0xFF0000
    static let formatZip: Int32 = 0x50000
    static let formatRaw: Int32 = 0x90000
    static let formatEmpty: Int32 = 0x60000

    static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

    static func errorText(_ archive: OpaquePointer?) -> String {
        string(archive_error_string(archive)) ?? "未知错误"
    }

    static func classify(_ message: String) -> ArchiveError {
        let m = message.lowercased()
        if m.contains("passphrase") {
            return m.contains("incorrect") ? .wrongPassword : .passwordRequired
        }
        if m.contains("encrypt") || m.contains("decrypt") { return .unsupportedEncryption }
        if m.contains("unrecognized archive format") { return .unsupportedFormat }
        if m.contains("can't launch external program") {
            // 系统自带的 libarchive 没编进 zstd / lz4，要靠命令行程序。
            return .failed("系统引擎不支持 zstd / lz4 压缩流，可在终端安装：brew install zstd lz4")
        }
        if m.contains("truncated") || m.contains("damaged") || m.contains("premature") || m.contains("signature") {
            return .failed("文件不完整或已损坏（\(message)）")
        }
        if m.contains("crc") || m.contains("checksum") {
            return .failed("数据校验失败，文件可能已损坏（\(message)）")
        }
        return .failed(message)
    }
}

extension String {
    var precomposed: String { precomposedStringWithCanonicalMapping }
}

extension FileManager {
    /// 不跟随符号链接的存在性判断，坏链接也算存在。
    func itemExists(at url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Finder 风格去重：「资料 2」「报告 2.txt」「备份 2.tar.gz」。
    /// `alsoAvoid` 里的后缀也要一起空出来（分卷：x.zip 与 x.zip.001 都不能已存在）。
    func uniqueURL(in dir: URL, name: String, isDirectory: Bool, alsoAvoid: [String] = []) -> URL {
        let (stem, ext) = isDirectory ? (name, "") : Self.splitExtension(name)
        var i = 1
        while true {
            let candidate = (i == 1 ? stem : "\(stem) \(i)") + ext
            let url = dir.appendingPathComponent(candidate)
            let taken = itemExists(at: url) || alsoAvoid.contains { itemExists(at: dir.appendingPathComponent(candidate + $0)) }
            if !taken { return url }
            i += 1
        }
    }

    /// 返回 (主名, 含点的扩展名)，识别 .tar.gz 这类双扩展名和 .zip.001 分卷。
    static func splitExtension(_ name: String) -> (String, String) {
        if let m = name.firstMatch(#"^(.+?)((\.tar)?\.[A-Za-z0-9]{1,5}\.\d{3}|\.tar\.[A-Za-z0-9]{1,4})$"#) {
            return (m[1], m[2])
        }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count < name.count - 1 else { return (name, "") }
        return ((name as NSString).deletingPathExtension, "." + ext)
    }

    func fileSize(_ url: URL) -> Int64 {
        (try? attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 节流：进度回调可能每毫秒触发一次，UI 只需要十几帧。
final class Throttle {
    private var last: TimeInterval = 0
    private let interval: TimeInterval
    init(interval: TimeInterval = 0.08) { self.interval = interval }

    func ready() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - last >= interval { last = now; return true }
        return false
    }
}
