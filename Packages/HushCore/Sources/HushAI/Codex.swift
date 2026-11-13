import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// OpenAI's Codex, signed in with your ChatGPT account, for Catch Up, Draft a Reply, Polish and
/// Translate. Hushh runs in the app sandbox and can't start Codex itself, so it goes through a
/// small script in its Application Scripts folder, which macOS runs for it outside the sandbox
/// (scripts/codex-bridge.sh). Nothing is sent unless you ask for one of those.
@MainActor @Observable
public final class Codex {
    public enum Setup: Equatable, Sendable {
        /// No bridge script: the Codex features stay hidden.
        case missing
        /// A bridge from an older Hushh; it still works, but should be replaced.
        case outdated
        case ready
    }

    /// How hard Codex thinks. Low is plenty for chat, and quickest; GPT-6 has nothing lower.
    public enum Effort: String, Sendable {
        case low
        case medium
    }

    /// Which model answers, whatever your Codex uses for coding. Chosen in Settings → AI.
    public enum Model: String, CaseIterable, Identifiable, Sendable {
        case luna = "gpt-6-luna"
        case sol = "gpt-6.1-sol"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .luna: "GPT-6 Luna"
            case .sol: "GPT-6.1 Sol"
            }
        }

        public var detail: String {
            switch self {
            case .luna: "Fast, and light on your Codex limits."
            case .sol: "Better at sounding like you; a little slower."
            }
        }
    }

    private static let modelKey = "HushhCodexModel"

    public var model: Model {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: Self.modelKey) }
    }
    /// Photos are shrunk to this many pixels on the long side: enough to see what's in them, at
    /// about a thousand tokens each.
    nonisolated static let photoPixels = 768

    public enum Failure: LocalizedError, Equatable {
        case notSetUp
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notSetUp: "Codex isn't set up. Open Settings → AI to set it up."
            case .failed(let reason): reason
            }
        }
    }

    public nonisolated static let scriptName = "codex-bridge.sh"

    public private(set) var setup = Setup.missing

    public init() {
        model = UserDefaults.standard.string(forKey: Self.modelKey).flatMap(Model.init) ?? .sol
        refresh()
    }

    public var isAvailable: Bool { setup != .missing }

    /// Where macOS lets Hushh run scripts from: ~/Library/Application Scripts/com.macneil.Hush.
    public nonisolated static var scriptsFolder: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    nonisolated static var installedScript: URL? {
        scriptsFolder?.appending(path: scriptName)
    }

    /// The script as this version of Hushh ships it.
    public nonisolated static var bundledScript: URL? {
        Bundle.main.url(forResource: "codex-bridge", withExtension: "sh")
    }

    /// Checks for the bridge (after Settings sets it up, say).
    public func refresh() {
        guard let installed = Self.installedScript, let current = try? Data(contentsOf: installed) else {
            setup = .missing
            return
        }
        let shipped = Self.bundledScript.flatMap { try? Data(contentsOf: $0) }
        setup = shipped == nil || shipped == current ? .ready : .outdated
    }

    /// Writes the bridge where you chose in the save panel, which macOS lets the sandboxed app do.
    public func install(to url: URL) throws {
        guard let shipped = Self.bundledScript else { throw Failure.failed("This copy of Hushh doesn't include the Codex script.") }
        try Data(contentsOf: shipped).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        refresh()
    }

    /// Asks Codex and returns its answer, showing it the photos too. Takes a few seconds: Codex
    /// starts up for each request.
    public func ask(_ prompt: String, effort: Effort, photos: [URL] = []) async throws -> String {
        guard let script = Self.installedScript, FileManager.default.fileExists(atPath: script.path) else {
            refresh()
            throw Failure.notSetUp
        }
        // The script runs outside the sandbox, so it can read and write in Hushh's own folder.
        let folder = FileManager.default.temporaryDirectory.appending(path: "codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "prompt.txt")
        let output = folder.appending(path: "answer.txt")
        let errors = folder.appending(path: "errors.txt")
        try prompt.write(to: input, atomically: true, encoding: .utf8)

        let shrunk = await Task.detached { Self.shrink(photos, into: folder) }.value
        let arguments = [input.path, output.path, errors.path, effort.rawValue, model.rawValue] + shrunk.map(\.path)
        let launchError = try await Self.run(script, arguments: arguments)
        let answer = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty else {
            let log = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            throw Failure.failed(log.isEmpty && launchError != nil ? launchError!.localizedDescription : Self.reason(fromLog: log))
        }
        return answer
    }

    /// Small JPEG copies of the photos, in the request's folder, in order. Unreadable ones are
    /// left out.
    nonisolated static func shrink(_ photos: [URL], into folder: URL) -> [URL] {
        photos.enumerated().compactMap { index, url in
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: photoPixels,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            let copy = folder.appending(path: "photo-\(index + 1).jpg")
            guard let destination = CGImageDestinationCreateWithURL(copy as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? copy : nil
        }
    }

    /// Runs the script to the end. A failing Codex exits non-zero, which macOS reports as an
    /// error; its log says why, so the answer file decides whether it worked.
    private nonisolated static func run(_ script: URL, arguments: [String]) async throws -> (any Error)? {
        let task = try NSUserUnixTask(url: script)
        return await withCheckedContinuation { (continuation: CheckedContinuation<(any Error)?, Never>) in
            task.execute(withArguments: arguments) { error in
                continuation.resume(returning: error)
            }
        }
    }

    /// Codex's log ends with what went wrong, sometimes as JSON from the API.
    nonisolated static func reason(fromLog log: String) -> String {
        let lines = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let line = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            let json = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
            if let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return "Codex: \(message)"
            }
            return "Codex: \(json)"
        }
        if let last = lines.last {
            return last.lowercased().contains("log in") || last.lowercased().contains("login")
                ? "Codex isn't signed in. Run “codex login” in Terminal."
                : last
        }
        return "Codex didn't answer."
    }
}
