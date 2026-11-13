import CryptoKit
import Foundation

/// Files an account's AI features derive from its messages: transcripts and search indexes.
/// Sealed with AES-GCM under a key derived from the database key in the keychain, so, like
/// TDLib's own database, they're unreadable without this Mac's keychain. Logging out deletes the
/// folder and that key.
public struct LocalVault: Sendable {
    public let directory: URL
    private let key: SymmetricKey

    init(directory: URL, databaseKey: Data) {
        self.directory = directory
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: databaseKey),
            info: Data("Hushh local AI data".utf8),
            outputByteCount: 32
        )
    }

    /// A vault with a given key, for tests.
    public init(directory: URL, key: SymmetricKey) {
        self.directory = directory
        self.key = key
    }

    /// The file's contents, or nil if it's missing, was sealed with another key, or was sealed
    /// under another name.
    public func read(_ name: String) -> Data? {
        guard let sealed = try? Data(contentsOf: directory.appending(path: name)),
              let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        if let data = try? AES.GCM.open(box, using: key, authenticating: Self.associatedData(name)) {
            return data
        }
        // Files written before the name was sealed in; the next write replaces them.
        return try? AES.GCM.open(box, using: key)
    }

    public func write(_ data: Data, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The name is sealed in, so one chat's file can't be passed off as another's.
        guard let sealed = try AES.GCM.seal(data, using: key, authenticating: Self.associatedData(name)).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        try sealed.write(to: directory.appending(path: name), options: .atomic)
    }

    private static func associatedData(_ name: String) -> Data {
        Data("hushh-vault:\(name)".utf8)
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
}
