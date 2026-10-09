@preconcurrency import TDLibKit
import TDLibFramework
import Foundation

/// One TDLib client and its updates, delivered in the order TDLib sent them.
public final class TDSession: Sendable {
    /// TDLib allows a single receive loop per process, so every session shares one manager.
    private static let manager: TDLibClientManager = {
        // Errors only, set before the first client exists. TDLib's chattier levels can include
        // message contents.
        _ = td_execute(#"{"@type":"setLogVerbosityLevel","new_verbosity_level":1}"#)
        return TDLibClientManager()
    }()

    public let client: TDLibClient
    /// Finishes once TDLib reports `authorizationStateClosed`.
    public let updates: AsyncStream<Update>

    public init(logFile: URL? = nil) {
        let (updates, continuation) = AsyncStream.makeStream(of: Update.self)
        self.updates = updates
        client = Self.manager.createClient { data, client in
            let update: Update
            do {
                update = try ResilientDecoding.decode(Update.self, from: data, decoder: client.decoder)
            } catch {
                Log.session.error("Skipping an update TDLibKit can't decode: \(String(describing: error), privacy: .public)")
                return
            }
            continuation.yield(update)
            if case .updateAuthorizationState(let change) = update,
               case .authorizationStateClosed = change.authorizationState {
                continuation.finish()
            }
        }
        Self.configureLogging(client: client, file: logFile)
    }

    /// Sends a request without waiting for TDLib's answer. `onReply` is for tests.
    public func sendIgnoringReply<Query: Codable>(_ query: Query, onReply: (@Sendable () -> Void)? = nil) {
        // TDLibKit calls the completion on a background queue. Written in this nonisolated class,
        // it can't pick up main-actor isolation, which Swift 6 enforces with a crash. Passing a
        // completion at all keeps TDLib's reply out of the update stream.
        try? client.send(query: DTO(query, encoder: client.encoder), completion: { _ in onReply?() })
    }

    /// Closes every open client and waits until TDLib has flushed its databases to disk.
    /// Blocks the calling thread, so only call it while the app is quitting.
    public static func closeAll() {
        manager.closeClients()
    }

    /// Prints the TDLib version, then shuts the client down. Used by `hush-smoke` to check that the
    /// prebuilt TDLib binary loads on this Mac.
    public static func probeVersion() async -> String? {
        let session = TDSession()
        var version: String?
        for await update in session.updates {
            if case .updateOption(let option) = update, option.name == "version",
               case .optionValueString(let value) = option.value {
                version = value.value
                _ = try? await session.client.close()
            }
        }
        return version
    }

    private static func configureLogging(client: TDLibClient, file: URL?) {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stream = LogStream.logStreamFile(LogStreamFile(maxFileSize: 10 << 20, path: file.path, redirectStderr: false))
        // TDLibKit's DTO needs the client's snake_case encoder, or TDLib ignores the parameters.
        _ = try? client.execute(query: DTO(SetLogStream(logStream: stream), encoder: client.encoder))
    }
}
