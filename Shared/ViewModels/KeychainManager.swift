import Security
import Foundation

/// Manages Keychain storage for MeshCore device login credentials.
/// Passwords are stored per-device (keyed by public key) and protected with
/// kSecAttrAccessibleWhenUnlockedThisDeviceOnly (no iCloud sync).
///
/// Uses the data protection keychain (kSecUseDataProtectionKeychain) so macOS
/// does not prompt for login keychain access on every rebuild.
/// All items for the service are bulk-loaded into an in-memory cache on first
/// access — at most one keychain read per app session.
struct KeychainManager {

    private static let service = "com.mbedworth.meshcore.logins"

    /// In-memory cache: account key → password.
    /// Once `cacheLoaded` is true, any key NOT in `cache` has no saved password.
    private static var cache: [String: String] = [:]
    private static var cacheLoaded = false
    private static let cacheLock = NSLock()

    private static func accountKey(publicKey: Data, type: String) -> String {
        publicKey.map { String(format: "%02x", $0) }.joined() + "." + type
    }

    /// Base query attributes shared by all operations.
    private static var baseAttributes: [String: Any] {
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        // Use data protection keychain on macOS to avoid login keychain ACL prompts.
        #if os(macOS)
        attrs[kSecUseDataProtectionKeychain as String] = true
        #endif
        return attrs
    }

    /// Load ALL items for our service from the keychain in one query.
    private static func ensureCacheLoaded() {
        if cacheLoaded { return }

        var query = baseAttributes
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   let data = item[kSecValueData as String] as? Data,
                   let password = String(data: data, encoding: .utf8) {
                    cache[account] = password
                }
            }
        }
        cacheLoaded = true
    }

    /// Save a password for a device identified by its public key.
    @discardableResult
    static func savePassword(_ password: String, forDevice publicKey: Data, type: String = "admin") -> Bool {
        let account = accountKey(publicKey: publicKey, type: type)

        // Delete any existing entry first
        var deleteQuery = baseAttributes
        deleteQuery[kSecAttrAccount as String] = account
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new entry
        guard let passwordData = password.data(using: .utf8) else { return false }
        var addQuery = baseAttributes
        addQuery[kSecAttrAccount as String] = account
        addQuery[kSecValueData as String] = passwordData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            cacheLock.lock()
            cache[account] = password
            cacheLock.unlock()
        }
        return status == errSecSuccess
    }

    /// Retrieve a saved password for a device.
    static func getPassword(forDevice publicKey: Data, type: String = "admin") -> String? {
        let account = accountKey(publicKey: publicKey, type: type)

        cacheLock.lock()
        ensureCacheLoaded()
        let password = cache[account]
        cacheLock.unlock()

        return password
    }

    /// Delete a saved password.
    @discardableResult
    static func deletePassword(forDevice publicKey: Data, type: String = "admin") -> Bool {
        let account = accountKey(publicKey: publicKey, type: type)

        var query = baseAttributes
        query[kSecAttrAccount as String] = account

        let status = SecItemDelete(query as CFDictionary)

        cacheLock.lock()
        cache.removeValue(forKey: account)
        cacheLock.unlock()

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
