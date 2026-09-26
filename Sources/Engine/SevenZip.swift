import Foundation

/// 可选增强：装了 7-Zip（brew install sevenzip）就用它处理 libarchive 搞不定的
/// RAR / 7z 加密包，以及带密码、加密文件名的 7z 压缩。
enum SevenZip {
    static let candidates = [
        "/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
        "/opt/homebrew/bin/7z", "/usr/local/bin/7z",
        "/opt/homebrew/bin/7za", "/usr/local/bin/7za",
        "/Applications/Keka.app/Contents/Resources/keka7z"
    ]

    static let executable: URL? = candidates
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }

    static var isAvailable: Bool { executable != nil }

    /// 依次试用户密码和记住的密码。返回用上的密码。
    static func extractTrying(_ src: ArchiveSource, into dir: URL, options: ExtractOptions,
                              cancel: CancelToken, progress: @escaping ProgressHandler) throws -> String? {
        var tries: [String?] = [options.password]
        if options.password == nil { tries += options.candidatePasswords.prefix(20).map { $0 } }
        var lastError: Error = ArchiveError.passwordRequired
        for pw in tries {
            do {
                try extract(src, into: dir, password: pw, cancel: cancel, progress: progress)
                return pw
            } catch let e as ArchiveError where e == .wrongPassword || e == .passwordRequired {
                lastError = e
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            }
        }
        if case ArchiveError.wrongPassword = lastError, options.password == nil {
            throw ArchiveError.passwordRequired
        }
        throw lastError
    }

    static func extract(_ src: ArchiveSource, into dir: URL, password: String?,
                        cancel: CancelToken, progress: @escaping ProgressHandler) throws {
        // 没密码时给一个不可能对的，防止 7-Zip 停下来等键盘输入。
        let pw = "-p" + (password ?? "qingya-no-password-\(UUID().uuidString)")
        try run(["x", src.volumes[0].path, "-o" + dir.path, "-y", "-bsp1", "-bso0", "-sccUTF-8", pw],
                cwd: nil, cancel: cancel, progress: progress)
    }

    static func compress(_ items: [URL], to output: URL, options: CompressOptions,
                         cancel: CancelToken, progress: @escaping ProgressHandler) throws -> [URL] {
        let level = [CompressionLevel.store: 0, .fast: 1, .normal: 5, .best: 9][options.level] ?? 5
        var args = ["a", "-t7z", "-mx=\(level)", "-y", "-bsp1", "-bso0", "-sccUTF-8", output.path]
        if let pw = options.password, !pw.isEmpty { args += ["-p" + pw, "-mhe=on"] }
        if let v = options.volumeSize, v > 0 { args.append("-v\(v)b") }
        if options.excludeJunk {
            args += Compressor.junkNames.filter { !$0.contains("\r") }.map { "-xr!" + $0 } + ["-xr!._*"]
        }
        let parents = Set(items.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let cwd = parents.count == 1 ? items[0].deletingLastPathComponent() : nil
        args += items.map { cwd == nil ? $0.path : $0.lastPathComponent }

        try run(args, cwd: cwd, cancel: cancel, progress: progress)

        let dir = output.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: output.path) { return [output] }
        let volumes = ArchiveKind.volumes(for: dir.appendingPathComponent(output.lastPathComponent + ".001"))
        guard FileManager.default.fileExists(atPath: volumes[0].path) else {
            throw ArchiveError.failed("7-Zip 没有生成压缩包")
        }
        return volumes
    }

    private static func run(_ args: [String], cwd: URL?, cancel: CancelToken,
                            progress: @escaping ProgressHandler) throws {
        guard let exe = executable else { throw ArchiveError.unsupportedEncryption }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let lock = NSLock()
        var errText = ""
        let throttle = Throttle()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            if let pct = s.firstMatch(#"(\d{1,3})%(?!.*\d%)"#)?[1], let v = Double(pct), throttle.ready() {
                progress(v / 100, "7-Zip 处理中…")
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            lock.lock(); errText += String(decoding: data, as: UTF8.self); lock.unlock()
        }

        try p.run()
        cancel.whenCancelled { if p.isRunning { p.terminate() } }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        errText += String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        try cancel.check()
        guard p.terminationStatus > 1 else { return }

        let lower = errText.lowercased()
        if lower.contains("wrong password") { throw ArchiveError.wrongPassword }
        if lower.contains("cannot open the file as archive") || lower.contains("can not open the file as archive") {
            throw ArchiveError.unsupportedFormat
        }
        let lines = errText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("7-Zip") }
        let tail = lines.suffix(2).joined(separator: " ")
        throw ArchiveError.failed("7-Zip 出错：" + (tail.isEmpty ? "退出码 \(p.terminationStatus)" : tail))
    }
}
