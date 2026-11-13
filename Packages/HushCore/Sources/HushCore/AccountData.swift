import Foundation

/// What Hushh keeps on this Mac about an account, outside TDLib's own database, and how it goes
/// away.
///
/// After a logout (from this Mac, or when the session was ended from another device), `AppModel`
/// deletes:
/// - `accounts/`: search indexes, transcripts and `visibility.json` (the chats you hid);
/// - TDLib's `db` and `files` folders (TDLib deletes them itself; this makes sure);
/// - Hushh's temporary copies in the temporary folder: files whose names start with `hush-` or
///   `Pasted Image `, which includes everything in `privateTemporaryDirectory`;
/// - the database key in the keychain, so a copy of a file sealed with it can't be opened. The
///   next login makes a new key.
///
/// Then it runs the cleanups registered with `AppModel.onLogOut(_:)`. Code that writes private
/// files elsewhere, or keeps private data in memory, registers one there.
public enum AccountData {
    /// A folder for temporary files made from an account's messages (sent photos, decoded voice
    /// messages). Logging out deletes it. Created on first use.
    public static var privateTemporaryDirectory: URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hush-private", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Names of the temporary files Hushh's code makes from your messages.
    static let temporaryPrefixes = ["hush-", "Pasted Image "]

    /// Deletes everything listed above, except the registered cleanups.
    static func removeAfterLogOut(_ configuration: TDConfiguration) {
        for folder in [configuration.accountsDirectory, configuration.databaseDirectory, configuration.filesDirectory] {
            remove(folder)
        }
        removeTemporaryFiles(in: configuration.temporaryDirectory)
        do {
            try configuration.databaseKey.delete()
        } catch {
            Log.session.error("Couldn't delete the database key: \(String(describing: error), privacy: .public)")
        }
    }

    /// After the keychain key stopped opening the database: TDLib's folders and the search data
    /// sealed with the old key are useless. Your visibility choices are kept.
    static func removeAfterKeyMismatch(_ configuration: TDConfiguration) {
        remove(configuration.databaseDirectory)
        remove(configuration.filesDirectory)
        let accounts = (try? FileManager.default.contentsOfDirectory(at: configuration.accountsDirectory, includingPropertiesForKeys: nil)) ?? []
        for account in accounts {
            remove(account.appending(path: "ai", directoryHint: .isDirectory))
        }
    }

    static func removeTemporaryFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where temporaryPrefixes.contains(where: name.hasPrefix) {
            remove(directory.appending(path: name))
        }
    }

    private static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            // The error's text holds the path, which holds the user id: log the code only.
            Log.session.error("Couldn't delete local data (error \((error as NSError).code, privacy: .public))")
        }
    }
}
