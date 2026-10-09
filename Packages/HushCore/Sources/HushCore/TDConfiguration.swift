import Foundation

/// Everything TDLib needs to start, resolved once at launch.
public struct TDConfiguration: Sendable {
    public var apiId: Int
    public var apiHash: String
    /// Root folder for TDLib's database, downloaded files and log. When running as the app this
    /// resolves inside the sandbox container.
    public var directory: URL
    public var applicationVersion: String
    public var useTestDc = false

    public init(apiId: Int, apiHash: String, directory: URL, applicationVersion: String) {
        self.apiId = apiId
        self.apiHash = apiHash
        self.directory = directory
        self.applicationVersion = applicationVersion
    }

    var databaseDirectory: URL { directory.appending(path: "db", directoryHint: .isDirectory) }
    var filesDirectory: URL { directory.appending(path: "files", directoryHint: .isDirectory) }
    var logFile: URL { directory.appending(path: "tdlib.log", directoryHint: .notDirectory) }

    /// Hush's own per-account settings, next to (not inside) TDLib's folder.
    func accountDirectory(for userId: Int64) -> URL {
        directory.deletingLastPathComponent().appending(path: "accounts/\(userId)", directoryHint: .isDirectory)
    }
}

extension TDConfiguration {
    public enum LoadError: Error, Equatable {
        case missingCredentials
    }

    /// Reads the API credentials the build copies from `Config/Secrets.xcconfig` into Info.plist.
    public static func load(from bundle: Bundle = .main) throws(LoadError) -> TDConfiguration {
        guard
            let idString = bundle.object(forInfoDictionaryKey: "HushTelegramAPIId") as? String,
            let apiId = Int(idString), apiId > 0,
            let apiHash = bundle.object(forInfoDictionaryKey: "HushTelegramAPIHash") as? String,
            apiHash.count == 32, apiHash.allSatisfy(\.isHexDigit)
        else {
            throw .missingCredentials
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return TDConfiguration(
            apiId: apiId,
            apiHash: apiHash,
            directory: URL.applicationSupportDirectory.appending(path: "Hush/tdlib", directoryHint: .isDirectory),
            applicationVersion: version
        )
    }
}
