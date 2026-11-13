import Foundation
import Testing
@testable import HushAI

/// Whether the downloaded model's files are whole.
@MainActor
struct ModelFileTests {
    /// A model folder with the three files the store looks for, and weights whose header says
    /// they hold `declared` bytes of data while `written` are there.
    func folder(declared: Int, written: Int) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "hush-test-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = AIModel.search.folder(in: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appending(path: "config.json"))
        try Data("{}".utf8).write(to: folder.appending(path: "tokenizer.json"))
        let header = Data(#"{"a":{"dtype":"F32","shape":[2],"data_offsets":[0,8]},"b":{"dtype":"F32","shape":[\#(declared / 4 - 2)],"data_offsets":[8,\#(declared)]}}"#.utf8)
        var weights = withUnsafeBytes(of: UInt64(header.count).littleEndian) { Data($0) }
        weights.append(header)
        weights.append(Data(count: written))
        try weights.write(to: folder.appending(path: "model.safetensors"))
        return base
    }

    /// A weights file cut short is damaged, never ready.
    @Test func cutShortWeightsAreNotReady() throws {
        let cut = try folder(declared: 4_000, written: 1_000)
        defer { try? FileManager.default.removeItem(at: cut) }
        #expect(ModelStore(base: cut).state(of: .search) == .failed(ModelStore.damaged))

        let whole = try folder(declared: 4_000, written: 4_000)
        defer { try? FileManager.default.removeItem(at: whole) }
        #expect(ModelStore(base: whole).state(of: .search) == .ready)
    }
}

/// Downloading the search model for real, about 490 MB, so it runs only when asked:
///
///     HUSH_DOWNLOAD_TESTS=1 swift test --filter ModelDownloadTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HUSH_DOWNLOAD_TESTS"] != nil), .serialized)
struct ModelDownloadTests {
    /// Cancel is not an error: the model is missing again, and what was downloaded is deleted.
    @Test func cancelIsNotAnError() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "hush-test-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ModelStore(base: base)
        store.download(.search)
        try await Task.sleep(for: .seconds(4))
        store.cancelDownload(.search)
        for _ in 0..<100 {
            if case .downloading = store.state(of: .search) { try await Task.sleep(for: .milliseconds(100)) } else { break }
        }
        #expect(store.state(of: .search) == .missing)
        #expect(!FileManager.default.fileExists(atPath: AIModel.search.folder(in: base).path))
    }

    /// The bar goes by bytes, so it keeps moving while the large weights file comes. The ONNX
    /// copies of the model are not downloaded.
    @Test func progressGoesByBytes() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "hush-test-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ModelStore(base: base)
        store.download(.search)
        var trace: [Double] = []
        let clock = ContinuousClock.now
        while ContinuousClock.now - clock < .seconds(300) {
            try await Task.sleep(for: .milliseconds(100))
            guard case .downloading(let fraction) = store.state(of: .search) else { break }
            trace.append(fraction)
        }
        for _ in 0..<100 where store.state(of: .search) == .preparing { try await Task.sleep(for: .milliseconds(100)) }
        #expect(store.state(of: .search) == .ready)
        // No ten-point stretch of the bar holds 40% of the time.
        let longest = (0..<10).map { band in trace.filter { Int($0 * 10) == band }.count }.max() ?? 0
        #expect(
            trace.count > 10 && Double(longest) / Double(trace.count) < 0.4,
            "progress every 0.1 s: \(trace.map { "\(Int($0 * 100))" }.joined(separator: " "))"
        )
        #expect(!FileManager.default.fileExists(atPath: AIModel.search.folder(in: base).appending(path: "onnx").path))
        #expect(AIModel.search.weightsAreWhole(in: base))
    }
}

/// Model work that overlaps, on one embedder (as in the app) and on several (as in tests).
/// Metal's graph compiler crashes the process when two graphs compile at once, and many batch
/// shapes make it compile many graphs:
///
///     HUSH_MODEL_TESTS=1 swift test --filter EmbedderOverlapTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HUSH_MODEL_TESTS"] != nil))
struct EmbedderOverlapTests {
    @Test func overlappingWorkDoesNotCrash() async throws {
        let shared = TextEmbedder(modelsIn: ModelTests.base)
        let others = (0..<3).map { _ in TextEmbedder(modelsIn: ModelTests.base) }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for round in 0..<24 {
                let embedder = round % 2 == 0 ? shared : others[round % 3]
                // Different lengths and batch sizes: each new shape compiles a new graph.
                let texts = (0...(round % 7)).map { String(repeating: "встреча в кафе \(round) ", count: 1 + round % 5) + "\($0)" }
                group.addTask { try await embedder.embed(passages: texts).count }
                group.addTask { try await embedder.embed(query: "кафе \(round)").count }
            }
            for try await count in group { #expect(count > 0) }
        }
    }
}
