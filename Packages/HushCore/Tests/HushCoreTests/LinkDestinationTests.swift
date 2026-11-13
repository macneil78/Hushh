import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

/// A link whose visible text names one place and opens another must ask first (the conversation
/// confirms it and shows the address on hover); a link that shows its own address opens at once.
struct LinkDestinationTests {
    private func textURL(_ visible: String, _ target: String) -> HushCore.RichText {
        HushCore.RichText(FormattedText(
            entities: [TextEntity(length: visible.utf16.count, offset: 0, type: .textEntityTypeTextUrl(.init(url: target)))],
            text: visible
        ))
    }

    @Test func linksThatHideWhereTheyGoAreFlagged() throws {
        for (visible, target) in [
            ("https://www.paypal.com/signin", "https://paypal.com.account-check.example/signin"),
            ("https://bank.com/login", "https://evil.example/phish"),
            ("bank.com", "https://bank.com.evil.example"),
            ("click here", "https://example.com"),
            ("https://example.com/a", "https://example.com/b"),
            ("https://example.com", "https://user@example.com"),
        ] {
            let text = textURL(visible, target)
            let url = try #require(URL(string: target))
            #expect(text.hidesDestination(of: url), "\(visible) -> \(target) opens without asking")
            #expect(text.hiddenLinkDestinations == [url])
        }
    }

    @Test func linksThatShowTheirOwnAddressOpenAtOnce() throws {
        for (visible, target) in [
            ("https://example.com/a", "https://example.com/a"),
            ("example.com/a", "https://example.com/a"),
            ("Example.COM/", "https://example.com"),
            ("http://example.com/a?b=1#c", "https://example.com/a?b=1#c"),
        ] {
            let url = try #require(URL(string: target))
            #expect(!textURL(visible, target).hidesDestination(of: url), "\(visible) -> \(target) asks")
        }
        // Bare links and e-mail addresses are made from the text itself.
        let bare = HushCore.RichText(FormattedText(
            entities: [
                TextEntity(length: 13, offset: 4, type: .textEntityTypeUrl),
                TextEntity(length: 7, offset: 21, type: .textEntityTypeEmailAddress),
            ],
            text: "see example.com/a or a@b.com"
        ))
        #expect(bare.spans.count == 2)
        #expect(bare.hiddenLinkDestinations.isEmpty)
    }
}
