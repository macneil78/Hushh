import Accelerate
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
    /// The mean of `MeaningMatch.referenceQueries`' vectors, once worked out.
    private var generic: [Float]?
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

    /// What a query in general looks like to the model: the mean of the reference queries'
    /// vectors (see `MeaningMatch`). Worked out once.
    public func genericQuery() async throws -> [Float] {
        if let generic { return generic }
        let vectors = try await embed(MeaningMatch.referenceQueries.map { "query: \($0)" })
        var mean = [Float](repeating: 0, count: Self.dimensions)
        for vector in vectors { mean = vDSP.add(mean, vector) }
        let generic = vDSP.divide(mean, Float(vectors.count))
        self.generic = generic
        return generic
    }

    /// The model's files load, but give vectors that can't be right: zeroed or otherwise
    /// damaged weights.
    public struct Damaged: Error {}

    /// e5 was trained with "query: " and "passage: " in front of the text, and needs them.
    private func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await Self.oneAtATime.run { [self] in
            try await embed(texts, with: try await loaded())
        }
    }

    private func embed(_ texts: [String], with bundle: Bert.ModelBundle) async throws -> [[Float]] {
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
        _ = try await Self.oneAtATime.run { [self] in try await loaded() }
        lastUse = .now
        scheduleUnload()
    }

    public func unload() {
        unloadTask?.cancel()
        bundle = nil
        generic = nil
    }

    /// Loads the model and checks it: damaged files can load without an error and give vectors
    /// of nothing (all the same, or not numbers), which would make search quietly useless.
    private func loaded() async throws -> Bert.ModelBundle {
        if let bundle { return bundle }
        let bundle = try await Bert.loadModelBundle(from: AIModel.search.folder(in: base))
        let check = try await embed(["passage: встречаемся в кафе на Тверской", "passage: the flight got cancelled"], with: bundle)
        let similarity = vDSP.dot(check[0], check[1])
        guard check.allSatisfy({ $0.allSatisfy(\.isFinite) }), similarity.isFinite, similarity < 0.99 else {
            throw Damaged()
        }
        self.bundle = bundle
        return bundle
    }

    /// The model's work, one piece at a time in the whole process, not only per embedder: with
    /// two embedders working at once (tests make several), Metal's graph compiler crashed the
    /// process (MPSGraphExecutable, two graphs compiling at once). The GPU runs one at a time
    /// anyway.
    private static let oneAtATime = SerialQueue()

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

/// Runs async work one piece after another, in the order it comes.
private actor SerialQueue {
    private var last: Task<Void, Never>?

    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = last
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        last = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
