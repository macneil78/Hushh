import AppKit
import Foundation
import SwiftUI
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

/// The conversation as drawn, not only as a model: every row of the timeline has to reach the
/// screen.
@MainActor
@Suite(.serialized)
struct MessageTimelineViewTests {
    /// Messages on different days get a time heading each, with its own day and time, and every
    /// message near the bottom is drawn: more history than fits, as when a chat opens.
    @Test func everyDayGetsItsOwnHeading() async throws {
        let (model, _, _) = Fixtures.conversation()
        let day = 86_400
        let dates = (0..<24).map { Fixtures.date + $0 * 2 * day + ($0 % 5) * 3_600 }
        for (index, date) in dates.enumerated() {
            model.handle(Fixtures.newMessage(Fixtures.message(Int64(index + 1) << 20, Fixtures.text("Message on day \(index + 1)"), date: date)))
        }
        #expect(model.timeline.filter { if case .timestamp = $0 { true } else { false } }.count == dates.count)

        TestWindow.enableAccessibility()
        let window = TestWindow.host(MessageTimeline(conversation: model, files: FileStore()), width: 640, height: 420)
        defer { TestWindow.close(window) }
        let content = try #require(window.contentView)
        var tree = ""
        for _ in 0 ..< 20 {
            await TestWindow.settle(0.25)
            tree = TestWindow.accessibilityTree(of: content)
            if tree.contains("Message on day \(dates.count)") { break }
        }
        // The bottom of the chat is on screen; the last few days must each show their heading.
        for (index, date) in dates.enumerated().suffix(4) {
            let time = Date(timeIntervalSince1970: TimeInterval(date)).formatted(date: .omitted, time: .shortened)
            #expect(tree.contains(time), "no heading for day \(index + 1) (\(time)):\n\(tree)")
            #expect(tree.contains("Message on day \(index + 1)"), "message \(index + 1) is not drawn:\n\(tree)")
        }
        model.close()
    }
}
