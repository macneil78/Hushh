import Foundation
import SwiftUI
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

/// How message formatting is read from TDLib and drawn.
struct RichTextParsingTests {
    private func rich(_ text: String, _ entities: [(offset: Int, length: Int, type: TextEntityType)]) -> HushCore.RichText {
        HushCore.RichText(FormattedText(
            entities: entities.map { TextEntity(length: $0.length, offset: $0.offset, type: $0.type) },
            text: text
        ))
    }

    /// Negative, overflowing or out-of-range entities are dropped, and the text still draws.
    @Test func malformedEntitiesAreDroppedInsteadOfCrashing() {
        let cases: [(Int, Int, TextEntityType)] = [
            (2, -1, .textEntityTypeBold),
            (Int.max, 1, .textEntityTypeBold),
            (1, Int.max, .textEntityTypeItalic),
            (-2, 3, .textEntityTypeUrl),
            (-2, 3, .textEntityTypeBold),
            (4, 5, .textEntityTypeSpoiler),
        ]
        for (offset, length, type) in cases {
            let text = rich("hello", [(offset, length, type)])
            #expect(text.spans.isEmpty, "offset \(offset), length \(length) kept")
            #expect(String(AttributedString(text, onAccent: false, revealsSpoilers: false).characters) == "hello")
        }
        // Spans made by hand can still be out of range: drawing skips them.
        let handMade = HushCore.RichText(text: "hello", spans: [.init(range: -3 ..< -1, style: .bold), .init(range: 3..<99, style: .bold)])
        #expect(String(AttributedString(handMade, onAccent: false, revealsSpoilers: true).characters) == "hello")
    }

    /// A spoiler that ends between 👍 and its skin tone still hides its words.
    @Test func spoilerEndingInsideAnEmojiStillHides() {
        let text = rich("Answer: forty two 👍🏽 done", [(8, 12, .textEntityTypeSpoiler)])
        let attributed = AttributedString(text, onAccent: false, revealsSpoilers: false)
        let hidden = attributed.runs.filter { $0.foregroundColor == .clear }.map { String(attributed[$0.range].characters) }.joined()
        #expect(hidden == "forty two 👍🏽")
    }

    /// Spans with an edge inside a character widen to the whole character.
    @Test func spansWidenToWholeCharacters() {
        for (text, range, expected) in [
            ("👨‍👩‍👧", 3..<5, "👨‍👩‍👧"),
            ("a👋b", 2..<4, "👋b"),
            ("e\u{301}x", 1..<2, "e\u{301}"),
            ("🇺🇦!", 2..<4, "🇺🇦"),
        ] {
            let text = HushCore.RichText(text: text, spans: [.init(range: range, style: .bold)])
            let characters = try! #require(text.characterRange(of: text.spans[0]))
            #expect(String(text.text[characters]) == expected)
            let attributed = AttributedString(text, onAccent: false, revealsSpoilers: true)
            let bold = attributed.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
                .map { String(attributed[$0.range].characters) }.joined()
            #expect(bold == expected)
        }
    }

    /// A bare link with "://" later in it (an archived address, say) still gets https:// in front.
    @Test func bareLinksWithAnAddressInsideGetAScheme() {
        for text in ["web.archive.org/web/2024/https://example.com", "google.com/url?q=https://example.com"] {
            let link = rich(text, [(0, text.utf16.count, .textEntityTypeUrl)]).spans.first?.style
            #expect(link == .link(URL(string: "https://\(text)")!))
        }
        let explicit = "HTTP://EXAMPLE.COM"
        #expect(rich(explicit, [(0, 18, .textEntityTypeUrl)]).spans.first?.style == .link(URL(string: explicit)!))
    }

    /// Only web, Telegram, mail and phone links become clickable; file:, smb:, javascript: and the
    /// like stay plain text.
    @Test func onlySafeSchemesBecomeLinks() {
        for raw in ["smb://198.51.100.7/share", "file:///Applications/Utilities/Terminal.app", "ssh://root@198.51.100.7", "ftp://198.51.100.7/x"] {
            #expect(rich(raw, [(0, raw.utf16.count, .textEntityTypeUrl)]).spans.isEmpty, "\(raw) is a link")
        }
        for target in ["javascript:alert(1)", "file:///Applications/Calculator.app", "x-apple.systempreferences:com.apple.preference.security"] {
            #expect(rich("here", [(0, 4, .textEntityTypeTextUrl(.init(url: target)))]).spans.isEmpty, "\(target) is a link")
        }
        for target in ["https://example.com", "http://example.com", "tg://resolve?domain=durov", "mailto:a@b.co", "tel:+15550100", "https://t.me/durov"] {
            #expect(rich("here", [(0, 4, .textEntityTypeTextUrl(.init(url: target)))]).spans.first?.style == .link(URL(string: target)!))
        }
        #expect(rich("a+b@example.com", [(0, 15, .textEntityTypeEmailAddress)]).spans.first?.style == .link(URL(string: "mailto:a+b@example.com")!))
    }
}
