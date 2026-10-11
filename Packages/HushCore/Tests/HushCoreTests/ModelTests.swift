import Foundation
import Testing
@testable import HushAI

/// The search model, for real on this Mac. It downloads about 490 MB the first time, so it runs
/// only when asked:
///
///     HUSH_MODEL_TESTS=1 swift test --filter ModelTests
///
/// Models are kept in ~/Library/Caches/HushModelTests (or HUSH_MODEL_DIR) between runs.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HUSH_MODEL_TESTS"] != nil), .serialized)
struct ModelTests {
    static let base = URL(
        filePath: ProcessInfo.processInfo.environment["HUSH_MODEL_DIR"] ?? NSHomeDirectory() + "/Library/Caches/HushModelTests",
        directoryHint: .isDirectory
    )

    @Test func findsMessagesByMeaning() async throws {
        try await AIModel.search.download(into: Self.base) { _ in }
        #expect(AIModel.search.isDownloaded(in: Self.base))
        let embedder = TextEmbedder(modelsIn: Self.base)
        let messages = [
            "встречаемся в кафе на Тверской, 5",
            "купи молоко по дороге домой",
            "я посмотрел новый фильм, очень понравился",
            "the meeting moved to Friday at 3pm",
            "напомни оплатить интернет до пятницы",
            "ахахахаха",
        ]
        let clock = ContinuousClock.now
        let vectors = try await embedder.embed(passages: messages)
        print("Embedded \(messages.count) messages, first run incl. loading: \(ContinuousClock.now - clock)")
        #expect(vectors.count == messages.count)
        #expect(vectors.allSatisfy { $0.count == TextEmbedder.dimensions })

        func best(_ query: String) async throws -> String {
            let q = try await embedder.embed(query: query)
            let scores = vectors.map { zip($0, q).reduce(0) { $0 + $1.0 * $1.1 } }
            let ranked = zip(messages, scores).sorted { $0.1 > $1.1 }
            print("“\(query)” → " + ranked.prefix(3).map { "\($0.0) (\(String(format: "%.3f", $0.1)))" }.joined(separator: ", "))
            return ranked[0].0
        }
        #expect(try await best("адрес ресторана") == messages[0])
        #expect(try await best("where are we meeting?") == messages[0])
        #expect([messages[0], messages[3]].contains(try await best("когда встреча")))
        #expect(try await best("счёт за интернет") == messages[4])
        #expect(try await best("продукты") == messages[1])
    }
}
