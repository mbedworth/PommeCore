import Security
import Foundation

/// Manages Keychain storage for MeshCore device login credentials.
/// Passwords are stored per-device (keyed by public key) and protected with
/// kSecAttrAccessibleWhenUnlockedThisDeviceOnly (no iCloud sync).
struct KeychainManager {

    private static let service = "com.mbedworth.meshcore.logins"

    /// Save a password for a device identified by its public key.
    @discardableResult
    static func savePassword(_ password: String, forDevice publicKey: Data, type: String = "admin") -> Bool {
        let account = publicKey.map { String(format: "%02x", $0) }.joined() + "." + type

        // Delete any existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new entry
        guard let passwordData = password.data(using: .utf8) else { return false }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a saved password for a device.
    static func getPassword(forDevice publicKey: Data, type: String = "admin") -> String? {
        let account = publicKey.map { String(format: "%02x", $0) }.joined() + "." + type

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a saved password.
    @discardableResult
    static func deletePassword(forDevice publicKey: Data, type: String = "admin") -> Bool {
        let account = publicKey.map { String(format: "%02x", $0) }.joined() + "." + type

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a password exists without retrieving it.
    static func hasPassword(forDevice publicKey: Data, type: String = "admin") -> Bool {
        getPassword(forDevice: publicKey, type: type) != nil
    }

    /// Get any saved password (tries admin first, then guest).
    static func getSavedPassword(forDevice publicKey: Data) -> String? {
        getPassword(forDevice: publicKey, type: "admin")
            ?? getPassword(forDevice: publicKey, type: "guest")
    }

    /// Delete all saved passwords for a device.
    static func deleteAllPasswords(forDevice publicKey: Data) {
        deletePassword(forDevice: publicKey, type: "admin")
        deletePassword(forDevice: publicKey, type: "guest")
    }
}
