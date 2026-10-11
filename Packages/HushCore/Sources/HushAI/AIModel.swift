import Foundation
import Hub

/// The models Hushh's AI features use. All run on this Mac; only the model files are downloaded,
/// once, from Hugging Face. (Transcription is Telegram's own, on its servers.)
public enum AIModel: String, CaseIterable, Identifiable, Sendable {
    /// multilingual-e5-small: messages to vectors, for search by meaning in Russian, English and
    /// about a hundred other languages.
    case search

    public var id: Self { self }

    public var title: String {
        switch self {
        case .search: "Search by meaning"
        }
    }

    public var detail: String {
        switch self {
        case .search: "multilingual-e5-small. Finds messages by what they mean, not just their words."
        }
    }

    /// Roughly what the download weighs, for Settings.
    public var downloadSize: Int64 {
        switch self {
        case .search: 490_000_000
        }
    }

    static let embeddingRepo = "intfloat/multilingual-e5-small"
    /// The weights, tokenizer and pooling settings; not the repo's ONNX and PyTorch copies.
    static let embeddingFiles = ["*.json", "*.safetensors"]

    /// Where this model's files are once downloaded under `base`.
    func folder(in base: URL) -> URL {
        switch self {
        case .search: base.appending(path: "models/\(Self.embeddingRepo)", directoryHint: .isDirectory)
        }
    }

    /// Whether the files are all there.
    func isDownloaded(in base: URL) -> Bool {
        let folder = folder(in: base)
        let required = switch self {
        case .search: ["model.safetensors", "tokenizer.json", "config.json"]
        }
        return required.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    /// Removes the model's files, including the download bookkeeping that would otherwise make a
    /// new download think it already has them.
    func delete(in base: URL) {
        try? FileManager.default.removeItem(at: folder(in: base))
    }

    /// Downloads the model into `base`, reporting progress from 0 to 1. Returns its folder.
    @discardableResult
    func download(into base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        switch self {
        case .search:
            let hub = HubApi(downloadBase: base, cache: nil)
            return try await hub.snapshot(from: Hub.Repo(id: Self.embeddingRepo), matching: Self.embeddingFiles) {
                progress($0.fractionCompleted)
            }
        }
    }
}
