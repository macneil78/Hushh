import Foundation
import Testing
@testable import HushAI

/// The rule for results by meaning against a plain score threshold, with the real model
/// (multilingual-e5-small), on the calibration chat and the held-out chat. Gated like ModelTests:
///
///     HUSH_MODEL_TESTS=1 swift test --filter MeaningCalibrationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HUSH_MODEL_TESTS"] != nil), .serialized)
struct MeaningCalibrationTests {
    struct Score: CustomStringConvertible {
        var shown = 0, right = 0, rightTotal = 0
        var answerable = 0, answered = 0
        var unanswerable = 0, unanswerableShowing = 0
        var precision: Double { Double(right) / Double(max(shown, 1)) }

        mutating func count(shown ids: [Int64], right: Set<Int>, indexed: [Int]) {
            let indexedRight = right.filter(indexed.contains)
            let rightShown = Set(ids.map(Int.init)).intersection(indexedRight)
            shown += ids.count
            if right.isEmpty {
                unanswerable += 1
                if !ids.isEmpty { unanswerableShowing += 1 }
            } else {
                answerable += 1
                rightTotal += indexedRight.count
                self.right += rightShown.count
                if !rightShown.isEmpty { answered += 1 }
            }
        }
        var recall: Double { Double(right) / Double(max(rightTotal, 1)) }
        var description: String {
            "\(Int((precision * 100).rounded()))% of \(shown) shown are right, \(Int((recall * 100).rounded()))% of right answers shown; "
                + "a right answer for \(answered) of \(answerable) queries; something shown for \(unanswerableShowing) of \(unanswerable) queries with no right answer"
        }
    }

    /// A plain threshold: of the 30 best, those above 0.80 and within 0.05 of the best.
    static func thresholdRule(_ index: SemanticIndex, _ query: [Float]) -> [Int64] {
        let hits = index.search(query, limit: 30)
        let best = hits.first?.score ?? 0
        return hits.filter { $0.score >= max(0.80, best - 0.05) }.map(\.id)
    }

    /// Indexes the messages as the app does (only meaningful ones, through the saved half-float
    /// form), runs every query by both rules, and counts.
    static func evaluate(messages: [String], queries: [(String, Set<Int>)]) async throws -> (threshold: Score, rule: Score) {
        let embedder = TextEmbedder(modelsIn: ModelTests.base)
        let kept = messages.indices.filter { SearchText.isMeaningful(messages[$0]) }
        var index = SemanticIndex()
        for (id, vector) in zip(kept, try await embedder.embed(passages: kept.map { messages[$0] })) {
            index.add(Int64(id), vector: vector)
        }
        index = try #require(SemanticIndex(serialized: index.serialized()))
        let generic = try await embedder.genericQuery()
        var threshold = Score(), rule = Score()
        for (query, right) in queries {
            let vector = try await embedder.embed(query: query)
            threshold.count(shown: thresholdRule(index, vector), right: right, indexed: kept)
            rule.count(shown: MeaningMatch.isWorthSearching(query) ? index.meaningMatches(vector, generic: generic) : [], right: right, indexed: kept)
        }
        return (threshold, rule)
    }

    /// Most results by meaning are right, and a query with no right answer (such as "the") shows
    /// next to nothing. The rule was chosen on the calibration set; the held-out set was not used
    /// to choose it.
    @Test func meaningResultsAreMostlyRight() async throws {
        let corpus = CalibrationCorpus.messages
        let calibration = try await Self.evaluate(
            messages: corpus.map(\.text),
            queries: CalibrationCorpus.queries.map { query in
                (query.0, Set(corpus.indices.filter { !corpus[$0].topics.isDisjoint(with: query.1) }))
            }
        )
        let heldOut = try await Self.evaluate(messages: HeldOutCorpus.messages, queries: HeldOutCorpus.queries)
        print("Calibration set, threshold: \(calibration.threshold)")
        print("Calibration set, rule: \(calibration.rule)")
        print("Held-out set, threshold: \(heldOut.threshold)")
        print("Held-out set, rule: \(heldOut.rule)")
        #expect(calibration.rule.precision >= 0.8)
        #expect(heldOut.rule.precision >= 0.9)
        #expect(calibration.rule.unanswerableShowing <= 2)
        #expect(heldOut.rule.unanswerableShowing == 0)
        #expect(Double(calibration.rule.answered) / Double(calibration.rule.answerable) >= 0.65)
        #expect(Double(heldOut.rule.answered) / Double(heldOut.rule.answerable) >= 0.6)
    }
}
