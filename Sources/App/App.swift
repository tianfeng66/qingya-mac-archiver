import SwiftUI
import AppKit

@main
struct QingYaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    init() {
        Prefs.register()
    }

    var body: some Scene {
        Window("轻压", id: "main") {
            MainView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("解压…") { model.extract(model.chooseFiles(archivesOnly: true)) }
                    .keyboardShortcut("o")
                Button("压缩…") { model.compress(model.chooseFiles(archivesOnly: false)) }
                    .keyboardShortcut("n")
            }
        }

        WindowGroup("浏览压缩包", for: URL.self) { $url in
            if let url {
                BrowserView(url: url)
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()
    private var launchDate = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        launchDate = Date()
    }

    /// 双击压缩包、「打开方式」、拖到程序坞图标都会走这里。
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let model = AppModel.shared
            if Date().timeIntervalSince(launchDate) < 2 && model.tasks.isEmpty && !Prefs.bool(Prefs.browseOnOpen) {
                model.launchedForFiles = true
            }
            model.open(urls, fromFinder: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppModel.shared.hasActiveTasks }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = MainActor.assumeIsolated { AppModel.shared.hasActiveTasks }
        guard busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有任务没完成"
        alert.informativeText = "现在退出会取消正在进行的压缩 / 解压，已生成的半成品会被清理。"
        alert.addButton(withTitle: "继续等待")
        alert.addButton(withTitle: "退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        MainActor.assumeIsolated {
            for t in AppModel.shared.tasks where !t.state.isFinished { t.cancelToken.cancel() }
        }
        // 给后台线程一点时间删临时目录。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// 访达右键「服务」菜单。
final class ServiceProvider: NSObject {
    @objc func compressFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(pboard)
        Task { @MainActor in AppModel.shared.compress(urls) }
    }

    @objc func extractFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = fileURLs(pboard)
        Task { @MainActor in AppModel.shared.extract(urls) }
    }

    private func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        NSApp.activate(ignoringOtherApps: true)
        return (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
