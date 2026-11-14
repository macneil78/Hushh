import Foundation

/// Codex kept ready in the background: the bridge started with `--session`, which runs Codex's
/// app server with a fresh chat already connected to OpenAI, so a request skips Codex's start-up
/// and connection. It holds nothing from your chats: each request goes in a chat of its own,
/// and the bridge starts a new one after it. It ends after twenty idle minutes, or when closed.
@MainActor
final class CodexSession {
    let model: Codex.Model
    private(set) var isRunning = true
    /// Why the session ended, when it failed.
    private(set) var failure: String?

    private let input = Pipe()
    private let output = Pipe()
    /// The request under way, if any: gets the bridge's lines.
    private var listener: ((Line) -> Void)?

    enum Line: Equatable {
        case piece(item: String, delta: String)
        /// The request is over; its files say how it went.
        case done
        /// The session can't go on, and why.
        case failed(String)
    }

    init(script: URL, model: Codex.Model) throws {
        self.model = model
        // A request written after the bridge stopped must fail, not end Hushh with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let task = try NSUserUnixTask(url: script)
        task.standardInput = input.fileHandleForReading
        task.standardOutput = output.fileHandleForWriting
        let writer = output.fileHandleForWriting
        task.execute(withArguments: ["--session", model.rawValue]) { _ in
            // The bridge is gone: closing the last writer lets the reader see the end.
            try? writer.close()
        }
        Task { await read() }
    }

    var isIdle: Bool { isRunning && listener == nil }

    /// Sends one request and waits until Codex is done with it. `onPiece` gets the answer as
    /// it's written. Returns why the session failed, or nil when the request ran (its answer
    /// and errors files say how it went).
    func run(_ request: Data, onPiece: @escaping (_ item: String, _ delta: String) -> Void) async -> String? {
        guard isRunning else { return failure ?? "Codex stopped. Try again." }
        guard listener == nil else { return "Codex is busy." }
        return await withCheckedContinuation { continuation in
            listener = { [weak self] line in
                switch line {
                case .piece(let item, let delta):
                    onPiece(item, delta)
                case .done:
                    self?.listener = nil
                    continuation.resume(returning: nil)
                case .failed(let reason):
                    self?.listener = nil
                    continuation.resume(returning: reason)
                }
            }
            do {
                try input.fileHandleForWriting.write(contentsOf: request + Data("\n".utf8))
            } catch {
                listener?(.failed("Codex stopped. Try again."))
            }
        }
    }

    /// Ends the session: the bridge stops when its input closes.
    func close() {
        try? input.fileHandleForWriting.close()
    }

    private func read() async {
        do {
            for try await text in output.fileHandleForReading.bytes.lines {
                guard let line = Self.line(text) else { continue }
                if case .failed(let reason) = line {
                    isRunning = false
                    failure = reason
                }
                listener?(line)
            }
        } catch {}
        isRunning = false
        listener?(.failed("Codex stopped. Try again."))
        try? input.fileHandleForWriting.close()
    }

    /// What one line from the bridge means, if anything: a piece of the answer, or its status.
    nonisolated static func line(_ text: String) -> Line? {
        if let piece = Codex.piece(in: text) {
            return .piece(item: piece.item, delta: piece.delta)
        }
        struct Status: Decodable {
            let hushh: String
            let status: String?
            let message: String?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: Data(text.utf8)) else { return nil }
        switch status.hushh {
        case "done": return .done
        case "failed": return .failed(Codex.reason(fromLog: status.message ?? ""))
        default: return nil  // "ready"
        }
    }
}
