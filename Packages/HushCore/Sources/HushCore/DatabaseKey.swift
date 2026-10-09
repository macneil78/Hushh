import Foundation
import Security

/// The key TDLib encrypts its local database with. It lives in the login keychain, so the
/// database files are useless without this Mac's keychain.
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

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw KeychainError(status: randomStatus) }

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
}
