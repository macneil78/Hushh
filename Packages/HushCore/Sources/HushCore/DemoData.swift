import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Made-up chats for screenshots. Launched with `-HushhDemo YES`, Hushh shows these instead of
/// logging in to Telegram, so nothing private ends up in a picture.
public enum DemoData {
    public struct Chat: Identifiable, Sendable {
        public let id: Int64
        public let title: String
        public let preview: String
        public let date: Foundation.Date
        public let accentColorId: Int
        public var isUnread = false
        public var isMuted = false
        public var isPinned = false
        public var isMention = false
        public var isOnline = false
        public var isDraft = false
    }

    /// The chat that's open.
    public static let openChatId: Int64 = 1
    public static let openChatSubtitle = "online"

    /// Pinned first, then most recent, as Telegram orders them. Dates are real, so they show in
    /// the Mac's own format (14:20 or 2:20 PM, weekdays) like the rest of the app.
    public static var chats: [Chat] {
        [
            Chat(id: 2, title: "Mum", preview: "Call me when you land ❤️", date: today(13, 5), accentColorId: 5, isPinned: true),
            Chat(id: 1, title: "Emma Wilson", preview: "You: Perfect, see you at 8", date: today(14, 20), accentColorId: 1, isOnline: true),
            Chat(id: 3, title: "Lucas Martin", preview: "Sent you the photos from Lisbon. The one at the tram stop is my favourite", date: today(12, 41), accentColorId: 2, isUnread: true),
            Chat(id: 6, title: "Dad", preview: "call you tonight", date: today(18, 15, daysAgo: 1), accentColorId: 0, isDraft: true),
            Chat(id: 5, title: "Sofia Rossi", preview: "You: Sure, I'll bring snacks", date: today(19, 50, daysAgo: 2), accentColorId: 5),
            Chat(id: 7, title: "Noah Kim", preview: "haha true, see you Monday", date: today(16, 30, daysAgo: 3), accentColorId: 4, isOnline: true),
            Chat(id: 8, title: "Ana García", preview: "Thanks for the book recommendation! Started it last night", date: today(10, 5, daysAgo: 4), accentColorId: 3),
        ]
    }

    private static func today(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Foundation.Date {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: .now))!
        return day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    public static let photoFileId = 900_001
    public static let voiceFileId = 900_002

    private static let me = MessageModel.Sender(id: 100, name: "Me", accentColorId: 0, photoFileId: nil)
    private static let emma = MessageModel.Sender(id: 1, name: "Emma Wilson", accentColorId: 1, photoFileId: nil)

    /// The open conversation, with a photo of `photoSize` (drawn by `drawPhoto`).
    public static func messages(photoSize: CGSize) -> [MessageModel] {
        func at(_ hour: Int, _ minute: Int) -> Foundation.Date {
            today(hour, minute)
        }
        func text(_ id: Int64, _ sender: MessageModel.Sender, _ date: Foundation.Date, _ text: String, reply: ReplyPreview? = nil, reactions: [Reaction] = []) -> MessageModel {
            var message = MessageModel(
                id: id, date: date, isOutgoing: sender.id == me.id, sender: sender,
                body: .text(RichText(text: text)), replyToMessageId: nil, reply: reply,
                forwardedFrom: nil, isEdited: false, status: .sent
            )
            message.reactions = reactions
            return message
        }
        let image = ImageSource(fileId: photoFileId, width: Int(photoSize.width), height: Int(photoSize.height))
        let photo = MessageModel(
            id: 6, date: at(14, 7), isOutgoing: false, sender: emma,
            body: .photo(PhotoMedia(image: image, largest: image, thumbnail: image, minithumbnail: nil), caption: RichText(text: "The view from the terrace last time")),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        let voice = MessageModel(
            id: 7, date: at(14, 12), isOutgoing: false, sender: emma,
            body: .voiceNote(VoiceNoteMedia(
                fileId: voiceFileId, duration: 9, waveform: waveform, isListened: true,
                transcription: .done("Oh, and bring the book you mentioned, I'd love to borrow it after you.")
            ), caption: RichText(text: "")),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        return [
            text(1, emma, at(13, 58), "Are we still on for dinner tonight?"),
            text(2, emma, at(13, 59), "I booked a table at that little Italian place 🍝"),
            text(3, me, at(14, 3), "Yes! Can't wait", reactions: [Reaction(kind: .emoji("❤️"), count: 1, isChosen: false)]),
            text(4, me, at(14, 3), "Can you send me the address? Last time I walked around the block twice before I found the door 😅"),
            text(5, emma, at(14, 6), "Rua da Rosa 21, right next to the bakery",
                 reply: ReplyPreview(senderName: "You", text: "Can you send me the address?"),
                 reactions: [Reaction(kind: .emoji("👍"), count: 1, isChosen: true)]),
            photo,
            voice,
            text(8, me, at(14, 20), "Perfect, see you at 8"),
        ]
    }

    /// A voice message's bars: a few spoken phrases.
    private static let waveform: [UInt8] = (0..<63).map { index in
        let phrase = sin(Double(index) / 63 * .pi * 3).magnitude
        let syllable = 0.55 + 0.45 * sin(Double(index) * 1.7).magnitude
        return UInt8(max(3, min(31, 31 * phrase * syllable)))
    }

    /// The photo in the conversation: a sunset over the sea, drawn here so the screenshots hold
    /// nothing anyone else made.
    public static func drawPhoto(to url: URL, size: CGSize = CGSize(width: 1200, height: 900)) throws {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
        let horizon = size.height * 0.42

        // Sky, from evening blue at the top down to orange at the horizon.
        let sky = CGGradient(colorsSpace: space, colors: [color(0.25, 0.30, 0.55), color(0.85, 0.45, 0.45), color(0.98, 0.70, 0.38)] as CFArray, locations: [0, 0.6, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: horizon), options: [])
        // The sun, half set.
        let sun = CGPoint(x: size.width * 0.62, y: horizon)
        let glow = CGGradient(colorsSpace: space, colors: [color(1, 0.92, 0.70), color(1, 0.75, 0.45, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: size.width * 0.35, options: [])
        context.setFillColor(color(1, 0.93, 0.75))
        context.fillEllipse(in: CGRect(x: sun.x - 70, y: sun.y - 70, width: 140, height: 140))
        // Sea.
        let sea = CGGradient(colorsSpace: space, colors: [color(0.80, 0.50, 0.45), color(0.20, 0.25, 0.42)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sea, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 0), options: [])
        // The sun's reflection, in streaks.
        context.setFillColor(color(1, 0.88, 0.65, 0.55))
        for row in 0..<9 {
            let y = horizon - 18 - CGFloat(row) * 30
            let width = 160 - CGFloat(row) * 12
            context.fill(CGRect(x: sun.x - width / 2 + CGFloat(row % 3 - 1) * 10, y: y, width: width, height: 6))
        }
        // A headland on the left.
        context.setFillColor(color(0.18, 0.16, 0.26))
        context.move(to: CGPoint(x: 0, y: horizon))
        context.addCurve(to: CGPoint(x: size.width * 0.33, y: horizon), control1: CGPoint(x: size.width * 0.08, y: horizon + 120), control2: CGPoint(x: size.width * 0.22, y: horizon + 30))
        context.addLine(to: CGPoint(x: 0, y: horizon))
        context.fillPath()
        // The terrace railing in front.
        context.setFillColor(color(0.12, 0.10, 0.16))
        context.fill(CGRect(x: 0, y: 60, width: size.width, height: 12))
        for post in stride(from: CGFloat(30), to: size.width, by: 90) {
            context.fill(CGRect(x: post, y: 0, width: 10, height: 66))
        }

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
