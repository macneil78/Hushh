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
    /// Where Hushh's own code puts temporary copies (sent photos, voice messages, pasted images).
    /// Logging out deletes Hushh's files here.
    var temporaryDirectory = FileManager.default.temporaryDirectory
    var databaseKey = DatabaseKeyStore.keychain

    public init(apiId: Int, apiHash: String, directory: URL, applicationVersion: String) {
        self.apiId = apiId
        self.apiHash = apiHash
        self.directory = directory
        self.applicationVersion = applicationVersion
    }

    var databaseDirectory: URL { directory.appending(path: "db", directoryHint: .isDirectory) }
    var filesDirectory: URL { directory.appending(path: "files", directoryHint: .isDirectory) }
    var logFile: URL { directory.appending(path: "tdlib.log", directoryHint: .notDirectory) }

    /// Hush's own per-account data, next to (not inside) TDLib's folder: one folder per user id.
    var accountsDirectory: URL {
        directory.deletingLastPathComponent().appending(path: "accounts", directoryHint: .isDirectory)
    }

    func accountDirectory(for userId: Int64) -> URL {
        accountsDirectory.appending(path: "\(userId)", directoryHint: .isDirectory)
    }
}

extension TDConfiguration {
    /// Which build setting is missing or wrong. The values themselves are never shown.
    public enum LoadError: Error, Equatable, Sendable, CustomStringConvertible {
        /// `HUSH_API_ID` is empty: usually there is no `Config/Secrets.xcconfig`.
        case missingId
        /// `HUSH_API_ID` isn't a positive whole number.
        case invalidId
        case missingHash
        /// `HUSH_API_HASH` isn't 32 hexadecimal characters. `length` is what was found.
        case invalidHash(length: Int)

        public var description: String {
            switch self {
            case .missingId:
                "HUSH_API_ID is empty."
            case .invalidId:
                "HUSH_API_ID isn't a number. It must be the digits of your API ID only, with no quotes or spaces."
            case .missingHash:
                "HUSH_API_HASH is empty."
            case .invalidHash(let length):
                "HUSH_API_HASH has \(length) character\(length == 1 ? "" : "s"), not the 32 letters and digits (0–9, a–f) of your API hash. Check for quotes or spaces."
            }
        }
    }

    /// Reads the API credentials the build copies from `Config/Secrets.xcconfig` into Info.plist.
    public static func load(from bundle: Bundle = .main) throws(LoadError) -> TDConfiguration {
        let idString = (bundle.object(forInfoDictionaryKey: "HushTelegramAPIId") as? String) ?? ""
        let apiHash = (bundle.object(forInfoDictionaryKey: "HushTelegramAPIHash") as? String) ?? ""
        let apiId = try parse(id: idString, hash: apiHash)
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return TDConfiguration(
            apiId: apiId,
            apiHash: apiHash,
            directory: URL.applicationSupportDirectory.appending(path: "Hush/tdlib", directoryHint: .isDirectory),
            applicationVersion: version
        )
    }

    /// Checks the two settings and returns the API ID.
    static func parse(id: String, hash: String) throws(LoadError) -> Int {
        guard !id.isEmpty else { throw .missingId }
        guard id.allSatisfy(\.isASCII), let apiId = Int(id), apiId > 0 else { throw .invalidId }
        guard !hash.isEmpty else { throw .missingHash }
        guard hash.count == 32, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw .invalidHash(length: hash.count)
        }
        return apiId
    }
}
