import Foundation

enum DestinationMode: String, CaseIterable, Identifiable {
    case sameFolder, ask, fixed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sameFolder: return "与原文件相同的位置"
        case .ask: return "每次询问"
        case .fixed: return "指定文件夹"
        }
    }
}

/// UserDefaults 键。界面用 @AppStorage 绑定同名键。
enum Prefs {
    static let extractDestination = "extractDestination"
    static let extractFixedPath = "extractFixedPath"
    static let folderMode = "folderMode"
    static let revealAfterExtract = "revealAfterExtract"
    static let trashAfterExtract = "trashAfterExtract"
    static let skipMacJunk = "skipMacJunk"
    static let nameEncoding = "nameEncoding"
    static let rememberPasswords = "rememberPasswords"

    static let compressFormat = "compressFormat"
    static let compressLevel = "compressLevel"
    static let compressDestination = "compressDestination"
    static let compressFixedPath = "compressFixedPath"
    static let excludeJunk = "excludeJunk"
    static let separateArchives = "separateArchives"
    static let volumeSizeMB = "volumeSizeMB"
    static let revealAfterCompress = "revealAfterCompress"

    static let quitAfterFinderOpen = "quitAfterFinderOpen"
    static let browseOnOpen = "browseOnOpen"

    static func register() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        UserDefaults.standard.register(defaults: [
            extractDestination: DestinationMode.sameFolder.rawValue,
            extractFixedPath: downloads,
            folderMode: FolderMode.smart.rawValue,
            revealAfterExtract: true,
            trashAfterExtract: false,
            skipMacJunk: true,
            nameEncoding: NameEncoding.auto.rawValue,
            rememberPasswords: true,
            compressFormat: ArchiveFormat.zip.rawValue,
            compressLevel: CompressionLevel.normal.rawValue,
            compressDestination: DestinationMode.sameFolder.rawValue,
            compressFixedPath: downloads,
            excludeJunk: true,
            separateArchives: false,
            volumeSizeMB: 0,
            revealAfterCompress: true,
            quitAfterFinderOpen: false,
            browseOnOpen: false,
            // 重启时不要把上次的浏览窗口都恢复出来。
            "NSQuitAlwaysKeepsWindows": false
        ])
    }

    private static var d: UserDefaults { .standard }

    static func bool(_ key: String) -> Bool { d.bool(forKey: key) }
    static func string(_ key: String) -> String { d.string(forKey: key) ?? "" }
    static func int(_ key: String) -> Int { d.integer(forKey: key) }

    static var extractMode: DestinationMode { DestinationMode(rawValue: string(extractDestination)) ?? .sameFolder }
    static var compressMode: DestinationMode { DestinationMode(rawValue: string(compressDestination)) ?? .sameFolder }
    static var folder: FolderMode { FolderMode(rawValue: string(folderMode)) ?? .smart }
    static var encoding: NameEncoding { NameEncoding(rawValue: string(nameEncoding)) ?? .auto }
    static var format: ArchiveFormat { ArchiveFormat(rawValue: string(compressFormat)) ?? .zip }
    static var level: CompressionLevel { CompressionLevel(rawValue: int(compressLevel)) ?? .normal }
}
