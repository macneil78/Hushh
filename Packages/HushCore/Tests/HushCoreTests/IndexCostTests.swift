import Foundation
import Testing
@testable import HushAI

/// Building and saving a big index must stay cheap: done naively, it froze the app.
struct IndexCostTests {
    @Test func twentyThousandMessagesIndexAndSaveQuickly() {
        let vector = [Float](repeating: 0.05, count: SemanticIndex.dimensions)
        var index = SemanticIndex()
        var clock = ContinuousClock.now
        var saves = Duration.zero
        for id in 1...20_000 {
            index.add(Int64(id), vector: vector)
            if id % 1_000 == 0 {
                let start = ContinuousClock.now
                _ = index.serialized()
                saves += ContinuousClock.now - start
            }
        }
        // Generous bounds for a debug build; it takes about a tenth of these.
        #expect(ContinuousClock.now - clock < .seconds(2), "adding took \(ContinuousClock.now - clock), saving \(saves)")
        clock = .now
        _ = index.search(vector, limit: 30)
        #expect(ContinuousClock.now - clock < .milliseconds(100))
    }
}
