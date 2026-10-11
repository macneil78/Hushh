import CoreML
import Embeddings
import Foundation

/// Text to vectors with multilingual-e5-small: texts that mean similar things get vectors pointing
/// the same way, whatever their words or language. The model loads on first use and is released
/// after a while unused.
public actor TextEmbedder {
    public static let dimensions = 384

    private let base: URL
    private var bundle: Bert.ModelBundle?
    private var lastUse = ContinuousClock.now
    private var unloadTask: Task<Void, Never>?

    static let idleTimeout = Duration.seconds(120)
    /// Messages longer than this many tokens are cut; plenty for chat messages.
    static let maxTokens = 256
    static let batchSize = 16

    /// `base` is where `AIModel.search` was downloaded.
    public init(modelsIn base: URL) {
        self.base = base
    }

    /// Vectors for messages to search through, unit length.
    public func embed(passages: [String]) async throws -> [[Float]] {
        try await embed(passages.map { "passage: \($0)" })
    }

    /// The vector for what you're searching for, unit length.
    public func embed(query: String) async throws -> [Float] {
        try await embed(["query: \(query)"])[0]
    }

    /// e5 was trained with "query: " and "passage: " in front of the text, and needs them.
    private func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let bundle = try await loaded()
        var options = bundle.defaultEncodeOptions
        options.maxLength = Self.maxTokens
        options.postProcess = .meanPool(normalize: true)
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        // Small batches: less padding (texts in a batch are padded to the longest) and short
        // bursts of GPU work, which leave room for drawing the screen.
        for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
            let batch = Array(texts[start..<min(start + Self.batchSize, texts.count)])
            let tensor = try bundle.batchEncode(batch, options: options)
            let scalars = await tensor.shapedArray(of: Float.self).scalars
            for row in 0..<batch.count {
                vectors.append(Array(scalars[row * Self.dimensions..<(row + 1) * Self.dimensions]))
            }
        }
        lastUse = .now
        scheduleUnload()
        return vectors
    }

    /// Loads the model now, so the first search doesn't wait for it.
    public func prepare() async throws {
        _ = try await loaded()
        lastUse = .now
        scheduleUnload()
    }

    public func unload() {
        unloadTask?.cancel()
        bundle = nil
    }

    private func loaded() async throws -> Bert.ModelBundle {
        if let bundle { return bundle }
        let bundle = try await Bert.loadModelBundle(from: AIModel.search.folder(in: base))
        self.bundle = bundle
        return bundle
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard ContinuousClock.now - lastUse >= Self.idleTimeout else { return }
        bundle = nil
    }
}
