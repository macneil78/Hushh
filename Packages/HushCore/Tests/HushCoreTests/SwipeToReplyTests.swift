import AppKit
import CoreGraphics
import Testing
@testable import HushUI

/// Trackpad swipes, as scroll events with gesture phases.
@MainActor
struct SwipeToReplyTests {
    private func swipe() -> (SwipeToReply, replies: () -> [Int64]) {
        let swipe = SwipeToReply()
        var replies: [Int64] = []
        swipe.onReply = { replies.append($0) }
        swipe.isInConversationWindow = { _ in true }
        return (swipe, { replies })
    }

    /// A scroll event; `dx` and `dy` are in the event's own terms (not inverted by the user).
    private func event(dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return NSEvent(cgEvent: event)!
    }

    /// Fingers moving left, in the event's terms for the current scrolling direction setting.
    private func left(_ points: Int32, phase: CGScrollPhase) -> NSEvent {
        let probe = event(dx: 1, phase: .began)
        // With natural scrolling the deltas follow the fingers; otherwise they're reversed.
        return event(dx: probe.isDirectionInvertedFromDevice ? -points : points, phase: phase)
    }

    @Test func swipingLeftFarEnoughReplies() {
        let (swipe, replies) = swipe()
        swipe.hover(5, true)
        #expect(!swipe.handle(left(2, phase: .began)))
        var took = false
        for _ in 0..<10 { took = swipe.handle(left(10, phase: .changed)) || took }
        #expect(took)
        #expect(swipe.offset(for: 5) <= -SwipeToReply.threshold)
        #expect(swipe.handle(event(phase: .ended)))
        #expect(replies() == [5])
        // The trackpad's momentum afterwards is the swipe's too.
        #expect(swipe.handle(event(dx: -3, momentum: .continuous)))
        #expect(swipe.handle(event(momentum: .end)))
        #expect(!swipe.handle(event(dy: 4, momentum: .continuous)))
    }

    @Test func aShortSwipeSpringsBackWithoutReplying() {
        let (swipe, replies) = swipe()
        swipe.hover(5, true)
        _ = swipe.handle(left(2, phase: .began))
        _ = swipe.handle(left(20, phase: .changed))
        #expect(swipe.handle(event(phase: .ended)))
        #expect(replies().isEmpty)
    }

    @Test func scrollingUpAndDownIsLeftAlone() {
        let (swipe, replies) = swipe()
        swipe.hover(5, true)
        #expect(!swipe.handle(event(dy: 3, phase: .began)))
        for _ in 0..<10 { #expect(!swipe.handle(event(dx: 1, dy: 12, phase: .changed))) }
        #expect(!swipe.handle(event(phase: .ended)))
        #expect(replies().isEmpty)
    }

    @Test func swipingRightOrAwayFromMessagesDoesNothing() {
        let (swipe, replies) = swipe()
        swipe.hover(5, true)
        _ = swipe.handle(left(-2, phase: .began))
        for _ in 0..<10 { #expect(!swipe.handle(left(-10, phase: .changed))) }
        _ = swipe.handle(event(phase: .ended))

        swipe.hover(5, false)
        _ = swipe.handle(left(2, phase: .began))
        for _ in 0..<10 { #expect(!swipe.handle(left(10, phase: .changed))) }
        _ = swipe.handle(event(phase: .ended))
        #expect(replies().isEmpty)
    }
}
