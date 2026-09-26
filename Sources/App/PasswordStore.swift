import Foundation
import Security

/// 解压密码本：本次运行输入过的密码 + 钥匙串里记住的密码。
/// 遇到加密包时自动逐个试，常见的「资源站统一解压密码」只需输一次。
@MainActor
final class PasswordStore: ObservableObject {
    static let shared = PasswordStore()

    @Published private(set) var saved: [String] = []
    private var session: [String] = []
    private var loaded = false

    private let service = "com.tian.qingya"
    private let account = "saved-passwords"

    /// 首次用到才读钥匙串，避免一启动就弹授权框。
    var candidates: [String] {
        loadIfNeeded()
        var seen = Set<String>()
        return (session + saved).filter { seen.insert($0).inserted }
    }

    func remember(_ password: String, persist: Bool) {
        guard !password.isEmpty else { return }
        session.removeAll { $0 == password }
        session.insert(password, at: 0)
        guard persist else { return }
        loadIfNeeded()
        saved.removeAll { $0 == password }
        saved.insert(password, at: 0)
        write()
    }

    func remove(_ password: String) {
        loadIfNeeded()
        saved.removeAll { $0 == password }
        session.removeAll { $0 == password }
        write()
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        saved = list
    }

    private func write() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = (try? JSONEncoder().encode(saved)) ?? Data()
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "轻压 · 解压密码"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
