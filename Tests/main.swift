// 引擎自检：xcrun swiftc ... Sources/Engine/*.swift Tests/main.swift，见 README
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
func check(_ ok: Bool, _ message: String) {
    print((ok ? "  ✓ " : "  ✗ ") + message)
    if !ok { failures += 1 }
}
func section(_ title: String) { print("\n▸ " + title) }

let fm = FileManager.default
let base = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : URL(fileURLWithPath: NSTemporaryDirectory())
let root = base.appendingPathComponent("qingya-selftest-\(getpid())")
try? fm.removeItem(at: root)
try fm.createDirectory(at: root, withIntermediateDirectories: true)

let noop: ProgressHandler = { _, _ in }
func dir(_ name: String) -> URL {
    let u = root.appendingPathComponent(name)
    try? fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// 素材
let src = dir("素材包")
try "你好，世界".write(to: src.appendingPathComponent("中文说明.txt"), atomically: true, encoding: .utf8)
try "é".write(to: src.appendingPathComponent("Café.txt"), atomically: true, encoding: .utf8)
try fm.createDirectory(at: src.appendingPathComponent("子目录/空目录"), withIntermediateDirectories: true)
var random = Data(count: 300_000)
random.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 300_000, $0.baseAddress!) }
try random.write(to: src.appendingPathComponent("子目录/数据.bin"))
try Data().write(to: src.appendingPathComponent(".DS_Store"))
try fm.createSymbolicLink(atPath: src.appendingPathComponent("链接").path, withDestinationPath: "中文说明.txt")

/// 相对路径 → 内容摘要（目录为 "<dir>"，链接为 "-> 目标"）。
func snapshot(_ dir: URL, skipJunk: Bool = true) -> [String: String] {
    var out: [String: String] = [:]
    let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil)!
    for case let url as URL in e {
        let rel = String(url.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1)).precomposed
        if skipJunk && Compressor.isJunk(url.lastPathComponent) { continue }
        if let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            out[rel] = "-> " + dest
        } else if fm.isDirectory(url) {
            out[rel] = "<dir>"
        } else {
            let d = (try? Data(contentsOf: url)) ?? Data()
            out[rel] = "\(d.count):\(d.hashValue)"
        }
    }
    return out
}
let expected = snapshot(src)

/// 用 libarchive 直接写一个 zip，可以塞任意文件名、指定编码。
func rawZip(_ url: URL, _ entries: [(String, String)], options: [String] = [], password: String? = nil) {
    _ = LA.setup
    let a = archive_write_new()!
    archive_write_set_format_zip(a)
    for o in options { archive_write_set_options(a, o) }
    if let password { archive_write_set_options(a, "zip:encryption=zipcrypt"); archive_write_set_passphrase(a, password) }
    let sink = VolumeSink(dir: url.deletingLastPathComponent(), name: url.lastPathComponent, volumeSize: nil)
    archive_write_open2(a, Unmanaged.passUnretained(sink).toOpaque(), nil, { _, c, b, n in
        try? Unmanaged<VolumeSink>.fromOpaque(c!).takeUnretainedValue().write(b!, n); return n
    }, { _, c in Unmanaged<VolumeSink>.fromOpaque(c!).takeUnretainedValue().close(); return 0 }, nil)
    for (name, body) in entries {
        let e = archive_entry_new()!
        archive_entry_set_pathname_utf8(e, name)
        archive_entry_set_filetype(e, UInt32(QY_AE_IFREG))
        archive_entry_set_perm(e, 0o644)
        let bytes = Array(body.utf8)
        archive_entry_set_size(e, Int64(bytes.count))
        archive_write_header(a, e)
        archive_write_data(a, bytes, bytes.count)
        archive_entry_free(e)
    }
    archive_write_close(a)
    archive_write_free(a)
    withExtendedLifetime(sink) {}
}

func extract(_ archive: URL, to dest: URL, _ tweak: (inout ExtractOptions) -> Void = { _ in }) throws -> ExtractResult {
    var o = ExtractOptions(destination: dest)
    tweak(&o)
    return try Extractor.extract(ArchiveSource(archive), options: o, cancel: CancelToken(), progress: noop)
}

func expectError(_ expected: ArchiveError, _ message: String, _ body: () throws -> Void) {
    do {
        try body()
        check(false, message + "（没有报错）")
    } catch let e as ArchiveError {
        check(e == expected, message + (e == expected ? "" : "（实际：\(e.localizedDescription)）"))
    } catch {
        check(false, message + "（\(error)）")
    }
}

print("libarchive \(archive_version_number())，7-Zip：\(SevenZip.executable?.path ?? "未安装")")

section("各格式压缩 → 解压往返")
for format in ArchiveFormat.allCases {
    let levels: [CompressionLevel] = format.supportsStore ? [.normal, .store] : [.normal]
    for level in levels {
        let tag = "\(format.title)/\(level.title)"
        do {
            let out = dir("out-\(format.rawValue)-\(level.rawValue)").appendingPathComponent("素材包.\(format.fileExtension)")
            let made = try Compressor.compress([src], to: out, options: CompressOptions(format: format, level: level),
                                               cancel: CancelToken(), progress: noop)
            let dest = dir("x-\(format.rawValue)-\(level.rawValue)")
            let r = try extract(made[0], to: dest)
            let got = r.outputs.first.map { snapshot($0) } ?? [:]
            check(r.outputs.map(\.lastPathComponent) == ["素材包"] && got == expected,
                  "\(tag)：\(ByteFormat.string(fm.fileSize(made[0])))，内容一致、无多余嵌套")
            for key in Set(expected.keys).union(got.keys).sorted() where expected[key] != got[key] {
                print("    \(key)：期望 \(expected[key] ?? "无")，实际 \(got[key] ?? "无")")
            }
        } catch {
            check(false, "\(tag)：\(error.localizedDescription)")
        }
    }
}

section("加密 zip")
do {
    let out = dir("enc").appendingPathComponent("机密.zip")
    let made = try Compressor.compress([src], to: out, options: CompressOptions(format: .zip, password: "芝麻开门"),
                                       cancel: CancelToken(), progress: noop)
    let listing = try Extractor.list(ArchiveSource(made[0]))
    check(listing.hasEncrypted, "列目录时识别出加密（无需密码即可浏览）")
    expectError(.passwordRequired, "不给密码 → 需要密码") { _ = try extract(made[0], to: dir("enc-x1")) }
    expectError(.wrongPassword, "错误密码 → 密码不正确") { _ = try extract(made[0], to: dir("enc-x2")) { $0.password = "123" } }
    let r = try extract(made[0], to: dir("enc-x3")) { $0.candidatePasswords = ["a", "b", "芝麻开门"] }
    check(r.usedPassword == "芝麻开门" && snapshot(r.outputs[0]) == expected, "从记住的密码里自动找到正确的那个")
    check((try? fm.contentsOfDirectory(atPath: dir("enc-x1").path))?.isEmpty == true, "失败时不留临时文件")

    let legacy = dir("enc").appendingPathComponent("传统加密.zip")
    rawZip(legacy, [("a.txt", String(repeating: "hello ", count: 50))], password: "pw")
    let r2 = try extract(legacy, to: dir("enc-x4")) { $0.password = "pw" }
    check(r2.fileCount == 1, "传统 ZipCrypto 加密可解")
    let t = try Extractor.test(ArchiveSource(made[0]), password: "芝麻开门", candidates: [], cancel: CancelToken(), progress: noop)
    check(t.fileCount >= 3, "测试完整性：\(t.fileCount) 个文件通过")
} catch {
    check(false, "加密流程：\(error.localizedDescription)")
}

section("文件名编码")
do {
    let names = ["资料/说明文档.txt", "资料/图片素材/封面图.jpg", "资料/第二章 数据分析报告.docx"]
    let gbk = dir("enc-gbk").appendingPathComponent("gbk.zip")
    rawZip(gbk, names.map { ($0, "x") }, options: ["zip:hdrcharset=CP936"])
    let listing = try Extractor.list(ArchiveSource(gbk))
    check(listing.items.map(\.path).sorted() == names.sorted(), "GBK 文件名自动识别：\(listing.items.first?.path ?? "-")")
    check(listing.legacyEncoding == NameEncoding.gb18030.encoding, "判定为 GB18030")
    let r = try extract(gbk, to: dir("enc-gbk-x"))
    check(fm.fileExists(atPath: r.outputs[0].appendingPathComponent("图片素材/封面图.jpg").path), "解压出的中文文件名正确")

    let big5Names = ["資料夾/測試檔案.txt", "資料夾/繁體中文說明.txt"]
    let big5 = dir("enc-big5").appendingPathComponent("big5.zip")
    rawZip(big5, big5Names.map { ($0, "x") }, options: ["zip:hdrcharset=BIG5"])
    let l2 = try Extractor.list(ArchiveSource(big5), encoding: .big5)
    check(l2.items.map(\.path).sorted() == big5Names.sorted(), "手动指定 Big5 可正确显示")

    let sjisNames = ["フォルダ/テスト資料.txt", "フォルダ/ゲーム設定ファイル.ini"]
    let sjis = dir("enc-sjis").appendingPathComponent("sjis.zip")
    rawZip(sjis, sjisNames.map { ($0, "x") }, options: ["zip:hdrcharset=SJIS"])
    let l3 = try Extractor.list(ArchiveSource(sjis), encoding: .shiftJIS)
    check(l3.items.map(\.path).sorted() == sjisNames.sorted(), "手动指定 Shift_JIS 可正确显示")
    let auto3 = try Extractor.list(ArchiveSource(sjis))
    print("    （Shift_JIS 自动识别结果：\(auto3.items.first?.path ?? "-")）")

    let ditto = dir("enc-ditto").appendingPathComponent("ditto.zip")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, ditto.path]
    try p.run(); p.waitUntilExit()
    let r4 = try extract(ditto, to: dir("enc-ditto-x"))
    let snap = snapshot(r4.outputs[0], skipJunk: false)
    check(r4.outputs.map(\.lastPathComponent) == ["素材包"], "访达/ditto 压缩的包（UTF-8 无标记）中文名正确")
    check(!snap.keys.contains { $0.contains("__MACOSX") || $0.contains("/._") }, "自动跳过 __MACOSX 和 ._ 资源文件")
} catch {
    check(false, "编码：\(error.localizedDescription)")
}

section("安全")
do {
    let evil = dir("evil").appendingPathComponent("evil.zip")
    rawZip(evil, [("../../逃逸.txt", "x"), ("ok/../../../逃逸2.txt", "x"), ("/etc/绝对路径.txt", "x"), ("正常.txt", "x")])
    let dest = dir("evil-x")
    let r = try extract(evil, to: dest) { $0.folderMode = .always }
    let files = snapshot(r.outputs[0])
    check(!fm.fileExists(atPath: root.appendingPathComponent("逃逸.txt").path)
          && !fm.fileExists(atPath: base.appendingPathComponent("逃逸.txt").path)
          && !files.keys.contains { $0.contains("逃逸") }, "带 ../ 的条目被拒绝（Zip Slip）")
    check(files.keys.contains("etc/绝对路径.txt") && files.keys.contains("正常.txt"), "绝对路径被收进目标目录内")
    check(r.skipped == 2, "跳过计数 = \(r.skipped)")
}

section("智能解压与重名")
do {
    let multi = dir("multi")
    try "a".write(to: multi.appendingPathComponent("一.txt"), atomically: true, encoding: .utf8)
    try "b".write(to: multi.appendingPathComponent("二.txt"), atomically: true, encoding: .utf8)
    let out = dir("multi-out").appendingPathComponent("两个文件.zip")
    let made = try Compressor.compress([multi.appendingPathComponent("一.txt"), multi.appendingPathComponent("二.txt")],
                                       to: out, options: CompressOptions(), cancel: CancelToken(), progress: noop)
    let dest = dir("multi-x")
    let r1 = try extract(made[0], to: dest)
    check(r1.outputs.map(\.lastPathComponent) == ["两个文件"], "多个顶层项目 → 放进同名文件夹")
    let r2 = try extract(made[0], to: dest)
    check(r2.outputs.map(\.lastPathComponent) == ["两个文件 2"], "再解一次 → 「两个文件 2」，不覆盖")
    let r3 = try extract(made[0], to: dest) { $0.folderMode = .never }
    check(Set(r3.outputs.map(\.lastPathComponent)) == ["一.txt", "二.txt"], "直接解压模式")
    let r4 = try extract(made[0], to: dest) { $0.folderMode = .never }
    check(Set(r4.outputs.map(\.lastPathComponent)) == ["一 2.txt", "二 2.txt"], "直接解压重名 → 「一 2.txt」")
    let hidden = (try fm.contentsOfDirectory(atPath: dest.path)).filter { $0.hasPrefix(".qingya") }
    check(hidden.isEmpty, "没有残留临时目录")
}

section("分卷")
do {
    var big = Data(count: 2_500_000)
    big.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 2_500_000, $0.baseAddress!) }
    let bigDir = dir("big/大文件")
    try big.write(to: bigDir.appendingPathComponent("随机.bin"))
    for format in [ArchiveFormat.zip, .sevenZip, .tgz] {
        let out = dir("split-\(format.rawValue)").appendingPathComponent("大文件.\(format.fileExtension)")
        let made = try Compressor.compress([bigDir], to: out,
                                           options: CompressOptions(format: format, level: .store, volumeSize: 1_000_000),
                                           cancel: CancelToken(), progress: noop)
        let src = ArchiveSource(made[1])
        let r = try extract(made[1], to: dir("split-\(format.rawValue)-x"))
        let ok = (try? Data(contentsOf: r.outputs[0].appendingPathComponent("随机.bin"))) == big
        check(made.count == 3 && src.volumes.count == 3 && ok,
              "\(format.title)：\(made.map(\.lastPathComponent).joined(separator: " "))，从第 2 卷打开也能找齐并解压")
    }
} catch {
    check(false, "分卷：\(error.localizedDescription)")
}

section("单文件压缩流 / 损坏 / 选择性解压")
do {
    let txt = dir("gz").appendingPathComponent("报告.txt")
    try "报告内容".write(to: txt, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    p.arguments = ["-k", txt.path]
    try p.run(); p.waitUntilExit()
    let r = try extract(txt.appendingPathExtension("gz"), to: dir("gz-x"))
    check(r.outputs.map(\.lastPathComponent) == ["报告.txt"]
          && (try? String(contentsOf: r.outputs[0], encoding: .utf8)) == "报告内容", "单个 .gz 文件 → 报告.txt")

    let good = dir("corrupt").appendingPathComponent("好.zip")
    let made = try Compressor.compress([src], to: good, options: CompressOptions(level: .fast), cancel: CancelToken(), progress: noop)
    var bytes = try Data(contentsOf: made[0])
    for i in stride(from: 2000, to: bytes.count - 2000, by: 997) { bytes[bytes.startIndex + i] ^= 0xFF }
    let bad = dir("corrupt").appendingPathComponent("坏.zip")
    try bytes.write(to: bad)
    do {
        _ = try Extractor.test(ArchiveSource(bad), password: nil, candidates: [], cancel: CancelToken(), progress: noop)
        check(false, "损坏的包应当测试失败")
    } catch {
        check(true, "损坏的包测试失败：\(error.localizedDescription)")
    }
    let junk = dir("corrupt").appendingPathComponent("不是压缩包.zip")
    try "hello".write(to: junk, atomically: true, encoding: .utf8)
    expectError(.unsupportedFormat, "普通文本改成 .zip → 无法识别") { _ = try extract(junk, to: dir("junk-x")) }

    let sel = try extract(made[0], to: dir("sel-x")) {
        $0.selection = ["素材包/子目录"]
        $0.stripPrefix = "素材包"
        $0.folderMode = .never
    }
    let s = snapshot(sel.outputs[0])
    check(sel.outputs.map(\.lastPathComponent) == ["子目录"] && s.keys.contains("数据.bin"), "只解压选中的子目录")

    let cancel = CancelToken()
    cancel.cancel()
    do {
        _ = try Extractor.extract(ArchiveSource(made[0]), options: ExtractOptions(destination: dir("cancel-x")),
                                  cancel: cancel, progress: noop)
        check(false, "取消")
    } catch {
        let left = (try? fm.contentsOfDirectory(atPath: dir("cancel-x").path)) ?? []
        check((error as? ArchiveError) == .cancelled && left.isEmpty, "取消后不留半成品")
    }
} catch {
    check(false, "\(error.localizedDescription)")
}

section("分卷识别")
do {
    let d = dir("names")
    for n in ["a.part1.rar", "a.part2.rar", "a.part3.rar", "b.7z.001", "b.7z.002", "c.rar", "c.r00", "c.r01"] {
        fm.createFile(atPath: d.appendingPathComponent(n).path, contents: Data())
    }
    check(ArchiveSource(d.appendingPathComponent("a.part2.rar")).volumes.map(\.lastPathComponent) == ["a.part1.rar", "a.part2.rar", "a.part3.rar"], "RAR partN")
    check(ArchiveSource(d.appendingPathComponent("b.7z.002")).volumes.count == 2, "7z .001/.002")
    check(ArchiveSource(d.appendingPathComponent("c.r01")).volumes.map(\.lastPathComponent) == ["c.rar", "c.r00", "c.r01"], "老式 .rar/.r00")
    check(ArchiveKind.baseName(of: URL(fileURLWithPath: "/x/项目备份.tar.gz")) == "项目备份", "tar.gz 去后缀")
    check(ArchiveKind.baseName(of: URL(fileURLWithPath: "/x/资源.part01.rar")) == "资源", "partN 去后缀")
    check(ArchiveKind.baseName(of: URL(fileURLWithPath: "/x/v1.2.zip")) == "v1.2", "保留版本号中的点")
}

print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
try? fm.removeItem(at: root)
exit(failures == 0 ? 0 : 1)
