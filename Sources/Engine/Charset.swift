import Foundation

/// 老式 zip（Windows 压缩软件、国产网盘）文件名不是 UTF-8，而是系统本地编码。
enum NameEncoding: String, CaseIterable, Identifiable, Codable {
    case auto, gb18030, big5, shiftJIS, eucKR, cp437, windows1252

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动识别"
        case .gb18030: return "简体中文（GBK / GB18030）"
        case .big5: return "繁体中文（Big5）"
        case .shiftJIS: return "日文（Shift_JIS）"
        case .eucKR: return "韩文（EUC-KR）"
        case .cp437: return "DOS 西文（CP437）"
        case .windows1252: return "西欧（Windows-1252）"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "自动"
        case .gb18030: return "GBK"
        case .big5: return "Big5"
        case .shiftJIS: return "Shift_JIS"
        case .eucKR: return "EUC-KR"
        case .cp437: return "CP437"
        case .windows1252: return "Windows-1252"
        }
    }

    var encoding: String.Encoding? {
        switch self {
        case .auto: return nil
        case .gb18030: return .cf(.GB_18030_2000)
        case .big5: return .cf(.big5_HKSCS_1999)
        case .shiftJIS: return .shiftJIS
        case .eucKR: return .cf(.EUC_KR)
        case .cp437: return .cf(.dosLatinUS)
        case .windows1252: return .windowsCP1252
        }
    }

    init?(encoding: String.Encoding) {
        guard let match = Self.allCases.first(where: { $0.encoding == encoding }) else { return nil }
        self = match
    }
}

extension String.Encoding {
    static func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }
}

/// 文件名在进入解码前的样子：要么已经是 Unicode，要么是一串原始字节。
enum RawName {
    case text(String)
    case bytes([UInt8])
}

enum Charset {
    /// 按用户语言排序的候选编码。
    static var candidates: [String.Encoding] {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "zh-hans"
        let gb = NameEncoding.gb18030.encoding!, big5 = NameEncoding.big5.encoding!
        let sjis = NameEncoding.shiftJIS.encoding!, kr = NameEncoding.eucKR.encoding!
        if lang.hasPrefix("zh-hant") || lang.hasPrefix("zh-tw") || lang.hasPrefix("zh-hk") {
            return [big5, gb, sjis, kr]
        }
        if lang.hasPrefix("ja") { return [sjis, gb, big5, kr] }
        if lang.hasPrefix("ko") { return [kr, gb, big5, sjis] }
        return [gb, big5, sjis, kr]
    }

    static func decodes(_ bytes: [UInt8], _ encoding: String.Encoding) -> Bool {
        String(data: Data(bytes), encoding: encoding) != nil
    }

    /// 整个压缩包统一判断一次：同一个包里的文件名几乎总是同一种编码，
    /// 合在一起样本多，比逐个猜准得多。
    static func detect(_ samples: [[UInt8]]) -> String.Encoding {
        let candidates = self.candidates
        guard !samples.isEmpty else { return candidates[0] }

        var joined: [UInt8] = []
        for s in samples.prefix(400) { joined += s; joined.append(0x0A) }

        var converted: NSString?
        var lossy: ObjCBool = false
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "zh"
        let raw = NSString.stringEncoding(
            for: Data(joined),
            encodingOptions: [
                .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.rawValue) },
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
                .likelyLanguageKey: lang
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy)

        if raw != 0 {
            let guess = String.Encoding(rawValue: raw)
            if samples.allSatisfy({ decodes($0, guess) }) { return guess }
        }
        for c in candidates where samples.allSatisfy({ decodes($0, c) }) { return c }
        return NameEncoding.cp437.encoding!
    }

    static func decode(_ name: RawName, using encoding: String.Encoding?) -> String {
        switch name {
        case .text(let s):
            return s
        case .bytes(let bytes):
            let data = Data(bytes)
            if let enc = encoding, let s = String(data: data, encoding: enc) { return s.precomposed }
            let single = detect([bytes])
            if let s = String(data: data, encoding: single) { return s.precomposed }
            return String(data: data, encoding: .isoLatin1) ?? "未命名"
        }
    }
}
