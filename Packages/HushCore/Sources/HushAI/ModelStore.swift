import Foundation
import Observation
import OSLog

/// The AI models on this Mac: which are downloaded, downloading or ready, and the actors that run
/// them. Models are shared by every account; they hold no messages.
@MainActor @Observable
public final class ModelStore {
    public enum State: Equatable, Sendable {
        case missing
        /// From 0 to 1.
        case downloading(Double)
        /// Loading it once after the download, so the first search doesn't wait.
        case preparing
        case ready
        case failed(String)
    }

    public private(set) var states: [AIModel: State] = [:]
    public let embedder: TextEmbedder
    public let base: URL
    @ObservationIgnored private var tasks: [AIModel: Task<Void, Never>] = [:]

    private static let log = Logger(subsystem: "Hush", category: "ai")

    public init(base: URL = URL.applicationSupportDirectory.appending(path: "Hush/Models", directoryHint: .isDirectory)) {
        self.base = base
        embedder = TextEmbedder(modelsIn: base)
        for model in AIModel.allCases {
            states[model] = switch (model.isDownloaded(in: base), model.weightsAreWhole(in: base)) {
            case (false, _): .missing
            case (true, false): .failed(Self.damaged)
            case (true, true): .ready
            }
        }
    }

    static let damaged = "The model's files are damaged. Download it again."

    public func state(of model: AIModel) -> State {
        states[model] ?? .missing
    }

    public func isReady(_ model: AIModel) -> Bool {
        state(of: model) == .ready
    }

    /// Downloads the model, then loads it once. Calling it while that's under way does nothing.
    public func download(_ model: AIModel) {
        guard tasks[model] == nil else { return }
        states[model] = .downloading(0)
        let base = base
        tasks[model] = Task {
            defer { tasks[model] = nil }
            do {
                // Files already there are damaged (or this would be ready): the download would
                // keep them, as it sees them already downloaded.
                if model.isDownloaded(in: base) {
                    switch model {
                    case .search: await embedder.unload()
                    }
                    model.delete(in: base)
                }
                try await model.download(into: base) { fraction in
                    Task { @MainActor in
                        guard case .downloading = self.states[model] else { return }
                        self.states[model] = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                states[model] = .preparing
                switch model {
                case .search: try await embedder.prepare()
                }
                states[model] = .ready
            } catch where Task.isCancelled || Self.isCancellation(error) {
                // Cancelled: the network download stops with URLError.cancelled, not CancellationError.
                model.delete(in: base)
                states[model] = .missing
            } catch {
                Self.log.error("Getting the \(model.rawValue, privacy: .public) model failed: \(String(describing: error), privacy: .public)")
                states[model] = .failed(Self.describe(error))
            }
        }
    }

    /// When using a model fails (its files turned out damaged, say): says so, in Settings and
    /// in search, with a way to download it again.
    public func modelFailed(_ model: AIModel, _ error: Error) {
        guard state(of: model) == .ready, !Self.isCancellation(error) else { return }
        Self.log.error("The \(model.rawValue, privacy: .public) model failed: \(String(describing: error), privacy: .public)")
        states[model] = .failed(Self.damaged)
        Task {
            switch model {
            case .search: await embedder.unload()
            }
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    public func cancelDownload(_ model: AIModel) {
        tasks[model]?.cancel()
    }

    public func delete(_ model: AIModel) async {
        tasks[model]?.cancel()
        switch model {
        case .search: await embedder.unload()
        }
        model.delete(in: base)
        states[model] = .missing
    }

    private static func describe(_ error: Error) -> String {
        if error is TextEmbedder.Damaged { return damaged }
        if let error = error as? URLError {
            return error.code == .notConnectedToInternet ? "No internet connection." : error.localizedDescription
        }
        return error.localizedDescription
    }
}
