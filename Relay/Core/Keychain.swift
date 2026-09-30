import Foundation
import Security

enum Keychain {
    private static let service = "com.example.codexrelay"

    // Native macOS uses the login Keychain's per-application access controls.
    // iOS/Catalyst use the data-protection Keychain and require a provisioned app.
    private static func query(account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = false
        #endif
        return query
    }
    private static func failure(_ status: OSStatus) -> RelayError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        if status == errSecMissingEntitlement {
            return .message("This build lacks the required Keychain entitlement. On Mac, use the native macOS build instead of the Catalyst preview. (\(status))")
        }
        return .message("Keychain could not store the credential: \(detail) (\(status)).")
    }
    static func save(_ value: String, account: String) throws {
        let query = query(account: account)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            #if !os(macOS)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #endif
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(account: String) { SecItemDelete(query(account: account) as CFDictionary) }
}
