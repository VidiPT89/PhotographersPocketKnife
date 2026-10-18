import Foundation
import Security

/// Passwords dos destinos de envio. Nunca ficam em ficheiros nem no catálogo.
enum Keychain {
    static let service = "dev.ividi.PhotographersPocketKnife.destinations"

    @discardableResult
    static func setPassword(_ password: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        guard !password.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Keep related credentials consistent if Keychain rejects one of the writes.
    static func setPasswords(_ values: [String: String]) -> Bool {
        var originals: [String: String] = [:]
        for account in values.keys { originals[account] = password(account: account) ?? "" }
        var saved: [String] = []
        for account in values.keys.sorted() {
            guard setPassword(values[account] ?? "", account: account) else {
                for changed in saved { setPassword(originals[changed] ?? "", account: changed) }
                return false
            }
            saved.append(account)
        }
        return true
    }

    static func password(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(account: String) {
        setPassword("", account: account)
    }
}
