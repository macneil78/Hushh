import AppKit
import SwiftUI

/// Swipe left with two fingers on a message to reply, as in Telegram for Mac. Trackpad swipes
/// arrive as scroll events, so this watches them: one that's clearly horizontal, over a message,
/// slides that message left; past the threshold there's a tap of haptic feedback, and letting go
/// replies. Vertical scrolling passes through untouched.
@MainActor @Observable
final class SwipeToReply {
    /// The message being swiped, and how far it has moved (negative: to the left).
    private(set) var activeId: Int64?
    private(set) var offset: CGFloat = 0

    @ObservationIgnored var onReply: (Int64) -> Void = { _ in }
    /// Whether swiping may start now (not in channels you can't write in, nor under the viewer).
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    /// Only gestures in the main window count (not a Settings window, say).
    @ObservationIgnored var isInConversationWindow: (NSEvent) -> Bool = { $0.window?.isMainWindow == true }

    @ObservationIgnored private var hoveredId: Int64?
    @ObservationIgnored private var candidateId: Int64?
    @ObservationIgnored private var state = State.idle
    @ObservationIgnored private var travel = CGSize.zero
    @ObservationIgnored private var hasPassedThreshold = false
    /// After a swipe, the trackpad's momentum events belong to it, not to the scroll view.
    @ObservationIgnored private var ownsMomentum = false
    @ObservationIgnored private var monitor: Any?

    private enum State {
        case idle
        /// A gesture began over a message; not yet clear which way it goes.
        case deciding
        case swiping
        /// A scroll, or a gesture that didn't start over a message.
        case ignoring
    }

    static let threshold: CGFloat = 60
    static let maxOffset: CGFloat = 90

    /// Rows report the pointer, so a swipe applies to the message under it.
    func hover(_ id: Int64, _ isHovering: Bool) {
        if isHovering {
            hoveredId = id
        } else if hoveredId == id {
            hoveredId = nil
        }
    }

    func offset(for id: Int64) -> CGFloat {
        activeId == id ? offset : 0
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let isTaken = MainActor.assumeIsolated { self.handle(event) }
            return isTaken ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        state = .idle
        activeId = nil
        offset = 0
    }

    /// Whether this took the event for a swipe.
    func handle(_ event: NSEvent) -> Bool {
        // Momentum, or a mouse wheel: no gesture phase.
        if event.phase.isEmpty {
            guard ownsMomentum, !event.momentumPhase.isEmpty else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { ownsMomentum = false }
            return true
        }
        guard event.hasPreciseScrollingDeltas else { return false }

        if event.phase.contains(.began) {
            ownsMomentum = false
            hasPassedThreshold = false
            travel = .zero
            candidateId = hoveredId
            state = candidateId != nil && isEnabled() && isInConversationWindow(event) ? .deciding : .ignoring
        }
        // The fingers' direction, whatever the scrolling direction setting: negative is left.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        if state == .deciding {
            travel.width += dx
            travel.height += abs(dy)
            if abs(travel.width) > 6 || travel.height > 6 {
                // Clearly sideways and to the left: a swipe. Anything else: a scroll.
                state = travel.width < 0 && abs(travel.width) > travel.height * 1.5 ? .swiping : .ignoring
                if state == .swiping {
                    activeId = candidateId
                    offset = 0
                }
            }
        }
        if state == .swiping {
            move(by: dx)
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let wasSwiping = state == .swiping
            if wasSwiping {
                if event.phase.contains(.ended), offset <= -Self.threshold, let id = activeId {
                    onReply(id)
                }
                ownsMomentum = true
                settle()
            }
            state = .idle
            return wasSwiping
        }
        return state == .swiping
    }

    /// Follows the fingers, resisting past the threshold.
    private func move(by dx: CGFloat) {
        let resistance: CGFloat = offset <= -Self.threshold ? 0.35 : 1
        offset = min(0, max(-Self.maxOffset, offset + dx * resistance))
        let isPast = offset <= -Self.threshold
        if isPast != hasPassedThreshold {
            hasPassedThreshold = isPast
            if isPast { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
    }

    /// Springs the message back into place.
    private func settle() {
        let id = activeId
        withAnimation(.spring(duration: 0.3)) { offset = 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if activeId == id, state != .swiping { activeId = nil }
        }
    }
}

/// Moves a message with the swipe.
struct SwipeOffset: ViewModifier {
    let id: Int64
    let swipe: SwipeToReply?

    func body(content: Content) -> some View {
        if let swipe {
            content
                .offset(x: swipe.offset(for: id))
                .onHover { swipe.hover(id, $0) }
        } else {
            content
        }
    }
}

/// The reply arrow that appears beside a bubble as it's swiped, filling in once letting go would
/// reply.
struct SwipeReplyArrow: ViewModifier {
    let id: Int64
    let swipe: SwipeToReply?

    func body(content: Content) -> some View {
        let offset = swipe?.offset(for: id) ?? 0
        content.overlay(alignment: .trailing) {
            if offset < 0 {
                let progress = min(1, -offset / SwipeToReply.threshold)
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(progress >= 1 ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 30, height: 30)
                    .background(progress >= 1 ? AnyShapeStyle(MessagesStyle.outgoing) : AnyShapeStyle(.quaternary), in: Circle())
                    .scaleEffect(0.5 + 0.5 * progress)
                    .opacity(progress)
                    .offset(x: 30)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Hover details (the react button, the time) step aside while a message is swiped, so the reply
/// arrow has the space by the bubble to itself.
struct HiddenWhileSwiping: ViewModifier {
    let id: Int64
    let swipe: SwipeToReply?

    func body(content: Content) -> some View {
        content.opacity(swipe?.offset(for: id) ?? 0 == 0 ? 1 : 0)
    }
}
