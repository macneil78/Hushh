import CryptoKit
import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

/// Logging out deletes this Mac's copy of the account. Everything happens in a scratch folder
/// with an in-memory key: the app's folders and keychain item are never touched.
@MainActor
struct LogoutTests {
    /// A Hushh data folder as it looks after some use.
    struct DataFolder {
        let root: URL
        let temporary: URL
        let configuration: TDConfiguration

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "hush-test-session-\(UUID().uuidString)", directoryHint: .isDirectory)
            temporary = root.appending(path: "tmp", directoryHint: .isDirectory)
            var configuration = TDConfiguration(apiId: 1, apiHash: "", directory: root.appending(path: "Hush/tdlib"), applicationVersion: "0")
            configuration.temporaryDirectory = temporary
            configuration.databaseKey = .inMemory()
            self.configuration = configuration
            for file in [
                "Hush/tdlib/db/db.sqlite", "Hush/tdlib/files/voice/file_0.oga", "Hush/tdlib/tdlib.log",
                "Hush/accounts/42/visibility.json", "Hush/accounts/7/visibility.json",
                "tmp/hush-photo-1.jpg", "tmp/hush-voice-2.ogg", "tmp/hush-play-file_0.caf", "tmp/hush-recording-3.caf",
                "tmp/Pasted Image 2026-11-13.png", "tmp/hush-private/anything", "tmp/someone-else.txt", "tmp/hushh-demo/terrace.jpg",
            ] {
                try write(file)
            }
        }

        func write(_ path: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("private".utf8).write(to: url)
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appending(path: path).path)
        }

        func vault(account: Int64) throws -> LocalVault {
            LocalVault(
                directory: configuration.accountDirectory(for: account).appending(path: "ai", directoryHint: .isDirectory),
                databaseKey: try configuration.databaseKey.loadOrCreate()
            )
        }
    }

    private static func closed(after states: [AuthorizationState], model: AppModel) {
        for state in states + [.authorizationStateClosing, .authorizationStateClosed] {
            model.handle(.updateAuthorizationState(.init(authorizationState: state)))
        }
    }

    @Test func logoutDeletesTheAccountsDataAndItsKey() throws {
        let folder = try DataFolder()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        try folder.vault(account: 42).write(Data("index of chat 1".utf8), to: "index-1")
        let oldKey = try folder.configuration.databaseKey.loadOrCreate()
        let model = AppModel(configuration: folder.configuration)
        var cleanups = 0
        model.onLogOut { cleanups += 1 }

        Self.closed(after: [.authorizationStateReady, .authorizationStateLoggingOut], model: model)

        for gone in [
            "Hush/accounts", "Hush/tdlib/db", "Hush/tdlib/files",
            "tmp/hush-photo-1.jpg", "tmp/hush-voice-2.ogg", "tmp/hush-play-file_0.caf", "tmp/hush-recording-3.caf",
            "tmp/Pasted Image 2026-11-13.png", "tmp/hush-private",
        ] {
            #expect(!folder.exists(gone), "\(gone) is still there")
        }
        for kept in ["tmp/someone-else.txt", "tmp/hushh-demo/terrace.jpg", "Hush/tdlib/tdlib.log"] {
            #expect(folder.exists(kept), "\(kept) was deleted")
        }
        #expect(cleanups == 1)
        // The key changed: a copy of an old vault file can't be opened with the new one.
        let newKey = try folder.configuration.databaseKey.loadOrCreate()
        #expect(newKey != oldKey)
        let copy = LocalVault(directory: folder.root.appending(path: "copy"), databaseKey: oldKey)
        try copy.write(Data("index of chat 1".utf8), to: "index-1")
        #expect(LocalVault(directory: copy.directory, databaseKey: newKey).read("index-1") == nil)
    }

    @Test func aRestartWithoutLogoutKeepsEverything() throws {
        let folder = try DataFolder()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let key = try folder.configuration.databaseKey.loadOrCreate()
        let model = AppModel(configuration: folder.configuration)
        var cleanups = 0
        model.onLogOut { cleanups += 1 }

        Self.closed(after: [.authorizationStateReady], model: model)

        for kept in ["Hush/accounts/42/visibility.json", "Hush/tdlib/db/db.sqlite", "tmp/hush-photo-1.jpg"] {
            #expect(folder.exists(kept), "\(kept) was deleted")
        }
        #expect(cleanups == 0)
        #expect(try folder.configuration.databaseKey.loadOrCreate() == key)
    }

    @Test func aKeyMismatchDeletesWhatTheOldKeySealed() throws {
        let folder = try DataFolder()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        try folder.write("Hush/accounts/42/ai/index-1")
        AccountData.removeAfterKeyMismatch(folder.configuration)
        #expect(!folder.exists("Hush/accounts/42/ai"))
        #expect(!folder.exists("Hush/tdlib/db"))
        #expect(!folder.exists("Hush/tdlib/files"))
        // Your choice of chats doesn't depend on the key.
        #expect(folder.exists("Hush/accounts/42/visibility.json"))
    }

    @Test func aVaultFileCantBePassedOffAsAnotherChats() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hush-test-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let vault = LocalVault(directory: directory, key: key)
        try vault.write(Data("chat 1 index".utf8), to: "index-1")
        try FileManager.default.copyItem(at: directory.appending(path: "index-1"), to: directory.appending(path: "index-2"))
        #expect(vault.read("index-1") == Data("chat 1 index".utf8))
        #expect(vault.read("index-2") == nil)
        // A file written before names were sealed in still opens.
        let legacy = try AES.GCM.seal(Data("old".utf8), using: key).combined!
        try legacy.write(to: directory.appending(path: "index-3"))
        #expect(vault.read("index-3") == Data("old".utf8))
    }

    @Test func connectionStateIsShownUntilTheConnectionWorks() {
        let model = AppModel(configuration: nil)
        model.handle(.updateConnectionState(.init(state: .connectionStateWaitingForNetwork)))
        #expect(model.connectionStatus == "Waiting for network…")
        model.handle(.updateConnectionState(.init(state: .connectionStateConnecting)))
        #expect(model.connectionStatus == "Connecting…")
        model.handle(.updateConnectionState(.init(state: .connectionStateReady)))
        #expect(model.connectionStatus == nil)
    }
}
