import Foundation
import Testing
@testable import HushAI

/// Not a test: writes both calibration chats' vectors to $HUSH_CALIBRATION_OUT, to tune `MeaningMatch` offline.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HUSH_CALIBRATION_OUT"] != nil), .serialized)
struct MeaningCalibrationExport {
    struct Chat: Encodable {
        var messages: [String]
        /// Whether the app indexes each message (`SearchText.isMeaningful`).
        var indexed: [Bool]
        var queries: [String]
        /// Each query's right answers, as message numbers.
        var right: [[Int]]
        /// The messages' vectors through the saved (half-float) index, and the queries'. A query's
        /// score against a message is the dot product of their vectors.
        var messageVectors: [[Float]]
        var queryVectors: [[Float]]
    }

    func vectors(messages: [String], queries: [String], right: [[Int]], embedder: TextEmbedder) async throws -> Chat {
        var index = SemanticIndex()
        for (i, vector) in try await embedder.embed(passages: messages).enumerated() { index.add(Int64(i), vector: vector) }
        index = try #require(SemanticIndex(serialized: index.serialized()))
        var queryVectors: [[Float]] = []
        for query in queries { queryVectors.append(try await embedder.embed(query: query)) }
        let dimensions = SemanticIndex.dimensions
        return Chat(
            messages: messages, indexed: messages.map(SearchText.isMeaningful), queries: queries, right: right,
            messageVectors: index.ids.indices.map { Array(index.vectors[$0 * dimensions..<($0 + 1) * dimensions]) },
            queryVectors: queryVectors
        )
    }

    /// HUSH_MODEL_TESTS=1 HUSH_CALIBRATION_OUT=/path/vectors.json swift test --filter MeaningCalibrationExport
    @Test func export() async throws {
        let embedder = TextEmbedder(modelsIn: ModelTests.base)
        let corpus = CalibrationCorpus.messages
        let calibration = try await vectors(
            messages: corpus.map(\.text),
            queries: CalibrationCorpus.queries.map(\.0),
            right: CalibrationCorpus.queries.map { query in corpus.indices.filter { !corpus[$0].topics.isDisjoint(with: query.1) } },
            embedder: embedder
        )
        let heldOut = try await vectors(
            messages: HeldOutCorpus.messages,
            queries: HeldOutCorpus.queries.map(\.0),
            right: HeldOutCorpus.queries.map { $0.1.sorted() },
            embedder: embedder
        )
        struct Output: Encodable {
            var calibration: Chat, heldOut: Chat
            /// The mean of `MeaningMatch.referenceQueries`' vectors.
            var generic: [Float]
        }
        let output = Output(calibration: calibration, heldOut: heldOut, generic: try await embedder.genericQuery())
        try JSONEncoder().encode(output).write(to: URL(filePath: ProcessInfo.processInfo.environment["HUSH_CALIBRATION_OUT"]!))
    }
}
