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
    /// Named one by one: a pattern like "*.json" also matches the copies in "onnx/".
    static let embeddingFiles = [
        "config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
        "modules.json", "sentence_bert_config.json", "1_Pooling/config.json", "model.safetensors",
    ]

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

    /// Whether the weights file is as long as its own header says. A download or copy cut short
    /// fails this, without reading the 470 MB. (Other damage shows when the model loads.)
    func weightsAreWhole(in base: URL) -> Bool {
        let url = folder(in: base).appending(path: "model.safetensors")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // safetensors: an 8-byte header length, a JSON header giving each tensor's byte range in
        // the data after it, then the data.
        guard let lengthBytes = try? handle.read(upToCount: 8), lengthBytes.count == 8 else { return false }
        let headerLength = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard headerLength < 100_000_000,
              let header = try? handle.read(upToCount: Int(headerLength)), header.count == Int(headerLength),
              let tensors = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any],
              let fileSize = try? handle.seekToEnd() else { return false }
        let dataEnd = tensors.values.compactMap { ($0 as? [String: Any])?["data_offsets"] as? [UInt64] }.compactMap(\.last).max() ?? 0
        return fileSize == 8 + headerLength + dataEnd
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
            let repo = Hub.Repo(id: Self.embeddingRepo)
            // The weights are 95% of the download, so progress goes by bytes, not by files: the
            // small files first, then the weights, each part weighted by its size.
            let sizes = try await withThrowingTaskGroup(of: (String, Double).self) { group in
                for file in Self.embeddingFiles {
                    group.addTask { (file, Double(try await hub.getFileMetadata(from: repo, matching: [file]).first?.size ?? 1)) }
                }
                return try await group.reduce(into: [String: Double]()) { $0[$1.0] = $1.1 }
            }
            let total = sizes.values.reduce(0, +)
            let weights = "model.safetensors"
            let parts = [Self.embeddingFiles.filter { $0 != weights }, [weights]]
            var done = 0.0
            var folder = folder(in: base)
            for files in parts {
                let before = done, size = files.reduce(0) { $0 + (sizes[$1] ?? 1) }
                folder = try await hub.snapshot(from: repo, matching: files) {
                    progress((before + size * $0.fractionCompleted) / total)
                }
                try Task.checkCancellation()
                done += size
            }
            return folder
        }
    }
}
