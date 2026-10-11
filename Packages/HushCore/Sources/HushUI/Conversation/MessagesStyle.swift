import AppKit
import HushCore
import SwiftUI

/// The look of the Mac's Messages app: blue bubbles for you, grey for them, tails on the last
/// bubble of a run, plain background, timestamps between bursts.
enum MessagesStyle {
    /// A muted blue: calmer than the system blue, still readable with white text.
    static let outgoing = Color(nsColor: NSColor(name: "HushhOutgoingBubble") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.243, green: 0.369, blue: 0.541, alpha: 1)  // #3E5E8A
            : NSColor(srgbRed: 0.310, green: 0.463, blue: 0.659, alpha: 1)  // #4F76A8
    })
    static let incoming = Color(nsColor: NSColor(name: "HushhIncomingBubble") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.231, green: 0.231, blue: 0.239, alpha: 1)
            : NSColor(srgbRed: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    })
    /// Behind the conversation: white in light mode, near-black in dark mode, as in Messages.
    static let background = Color(nsColor: .textBackgroundColor)

    static let cornerRadius: CGFloat = 18
    /// Room beside every bubble for the tail, so tailed and untailed bubbles line up.
    static let tailWidth: CGFloat = 6
    /// The widest a bubble gets.
    static let maxBubbleWidth: CGFloat = 520

    static func bubbleColor(isOutgoing: Bool) -> Color {
        isOutgoing ? outgoing : incoming
    }
}

/// A message bubble. With a tail, the corner on the sender's side sweeps out into a point, as on
/// the last bubble of a run in Messages. Either way, the tail's width is kept free on that side.
struct BubbleShape: Shape {
    let isOutgoing: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        // Drawn for an outgoing bubble (tail at the bottom right), then mirrored for incoming.
        let tail = MessagesStyle.tailWidth
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - tail, height: rect.height)
        let radius = min(MessagesStyle.cornerRadius, body.height / 2, body.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(center: CGPoint(x: body.maxX - radius, y: body.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        if hasTail {
            let lift = min(radius, 14)
            path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - lift))
            // Down the bubble's side, then sweeping out to the tip...
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: body.maxY),
                control1: CGPoint(x: body.maxX, y: body.maxY - lift * 0.3),
                control2: CGPoint(x: rect.maxX - 1.5, y: body.maxY - 0.5)
            )
            // ...and back along the bottom.
            path.addCurve(
                to: CGPoint(x: body.maxX - lift, y: body.maxY),
                control1: CGPoint(x: rect.maxX - tail, y: body.maxY + 0.6),
                control2: CGPoint(x: body.maxX - lift * 0.5, y: body.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
            path.addArc(center: CGPoint(x: body.maxX - radius, y: body.maxY - radius), radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        guard !isOutgoing else { return path }
        return path.applying(CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1))
    }
}

extension View {
    /// Pads content to sit inside a `BubbleShape`, leaving the tail's side free.
    func bubblePadding(isOutgoing: Bool, horizontal: CGFloat = 12, vertical: CGFloat = 7) -> some View {
        padding(.vertical, vertical)
            .padding(.leading, horizontal + (isOutgoing ? 0 : MessagesStyle.tailWidth))
            .padding(.trailing, horizontal + (isOutgoing ? MessagesStyle.tailWidth : 0))
    }
}

/// Between bursts of messages, centered: "**Today** 14:20".
struct TimestampHeading: View {
    let date: Date

    var body: some View {
        Text("\(Text(DayHeading.label(for: date)).fontWeight(.semibold)) \(date.formatted(date: .omitted, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// Reactions on a message, as a Tapback badge on the bubble's top corner. Blue when one of
/// them is yours.
struct TapbackBadge: View {
    let reactions: [Reaction]
    let onTap: () -> Void

    private var total: Int { reactions.reduce(0) { $0 + $1.count } }
    private var includesMine: Bool { reactions.contains(where: \.isChosen) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 2) {
                ForEach(reactions.prefix(3)) { reaction in
                    switch reaction.kind {
                    case .emoji(let emoji): Text(Emoji.colorful(emoji))
                    case .customEmoji: Image(systemName: "face.smiling")
                    case .paid: Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
                if total > 1 {
                    Text("\(total)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(includesMine ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .frame(minWidth: 28, minHeight: 26)
            .background(includesMine ? MessagesStyle.outgoing : MessagesStyle.incoming, in: Capsule())
            .overlay(Capsule().strokeBorder(MessagesStyle.background, lineWidth: 2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(reactions.map { reaction in
            switch reaction.kind {
            case .emoji(let emoji): "\(emoji) \(reaction.count)"
            case .customEmoji: "Custom emoji \(reaction.count)"
            case .paid: "⭐️ \(reaction.count)"
            }
        }.joined(separator: "  "))
    }
}

/// Under your latest message: "Delivered", "Read", or why it wasn't sent.
struct DeliveryStatus: View {
    enum State: Equatable {
        case sending
        case delivered
        case read
        case failed(String)
    }

    let state: State

    var body: some View {
        switch state {
        case .sending:
            Text("Sending…").foregroundStyle(.secondary)
        case .delivered:
            Text("Delivered").foregroundStyle(.secondary)
        case .read:
            Text("Read").foregroundStyle(.secondary)
        case .failed(let reason):
            Text("Not Delivered").foregroundStyle(.red).help(reason)
        }
    }
}

/// Someone's typing: a grey bubble with three pulsing dots.
struct TypingBubble: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 2.4
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.45 * max(0, sin(phase - Double(index) * 0.7)))
                }
            }
            .foregroundStyle(.secondary)
            .bubblePadding(isOutgoing: false, horizontal: 13, vertical: 11)
            .background(MessagesStyle.incoming, in: BubbleShape(isOutgoing: false, hasTail: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .accessibilityLabel("Typing")
    }
}

enum Emoji {
    /// Telegram sends some reactions as bare symbols, like "❤" (U+2764), which macOS draws as a
    /// plain text glyph in the text's color: a white heart on a blue badge. The emoji variation
    /// selector after such a symbol makes it the colorful emoji. For display only: Telegram
    /// expects reactions back exactly as it sent them.
    static func colorful(_ emoji: String) -> String {
        let scalars = Array(emoji.unicodeScalars)
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            result.append(scalar)
            let next = scalars.indices.contains(index + 1) ? scalars[index + 1] : nil
            let needsSelector = scalar.properties.isEmoji
                && !scalar.properties.isEmojiPresentation
                && !scalar.isASCII
                && next != "\u{FE0F}"
                && next?.properties.isEmojiModifier != true
            if needsSelector { result.append("\u{FE0F}") }
        }
        return String(result)
    }
}
