import Foundation
import Security

/// The key TDLib encrypts its local database with, and that `LocalVault` derives its key from.
/// It lives in the login keychain. It protects TDLib's SQLite database and the vault files only:
/// downloaded photos, videos, voice messages and documents in `tdlib/files` are plain files.
enum DatabaseKey {
    private static let service = "Hush"
    private static let account = "tdlib-database-key"

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "\(message) (\(status))"
        }
    }

    /// Returns the stored key, creating one on first launch.
    static func loadOrCreate() throws(KeychainError) -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let key = item as? Data {
            return key
        }
        // Only create a new key when there truly is none: replacing a key we merely failed to
        // read would lock us out of the existing database.
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        let key = try newKey()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Hushh database key",
            kSecValueData as String: key,
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        return key
    }

    /// Deletes the key, so files sealed with it can't be opened again. The next `loadOrCreate`
    /// makes a new one. Only call it once TDLib's database is gone (after a logout).
    static func delete() throws(KeychainError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    static func newKey() throws(KeychainError) -> Data {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }
}

/// Where the database key is kept: the keychain in the app, memory in tests (which must never
/// touch the real keychain item).
struct DatabaseKeyStore: Sendable {
    let loadOrCreate: @Sendable () throws -> Data
    let delete: @Sendable () throws -> Void

    static let keychain = DatabaseKeyStore(
        loadOrCreate: { try DatabaseKey.loadOrCreate() },
        delete: { try DatabaseKey.delete() }
    )

    /// A store that keeps the key in memory, for tests.
    static func inMemory() -> DatabaseKeyStore {
        let box = KeyBox()
        return DatabaseKeyStore(
            loadOrCreate: { try box.withLock { key in
                if let key { return key }
                let new = try DatabaseKey.newKey()
                key = new
                return new
            } },
            delete: { box.withLock { $0 = nil } }
        )
    }

    private final class KeyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var key: Data?
        func withLock<T>(_ body: (inout Data?) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(&key)
        }
    }
}
