import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

struct ResilientDecodingTests {
    /// Decodes like TDLibKit does.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct Envelope: Decodable {
        let content: MessageContent
        let others: [Inner]
        struct Inner: Decodable { let content: MessageContent }
    }

    @Test func giftsTDLibKitCantReadBecomeAGiftLine() throws {
        // A gift without the "background" TDLibKit insists on: what hid your chats.
        let json = Data(#"""
        {"content": {"@type": "messageGift", "gift": {"id": "1"}},
         "others": [{"content": {"@type": "messageText", "text": {"@type": "formattedText", "text": "hi", "entities": []}}},
                    {"content": {"@type": "messagePoll", "broken": true}}]}
        """#.utf8)
        #expect(throws: (any Swift.Error).self) { try decoder.decode(Envelope.self, from: json) }

        let envelope = try ResilientDecoding.decode(Envelope.self, from: json, decoder: decoder)
        #expect(envelope.content == .messageCustomServiceAction(.init(text: "🎁 Gift")))
        // Readable content is left alone; other unreadable content becomes "unsupported".
        if case .messageText(let text) = envelope.others[0].content { #expect(text.text.text == "hi") } else { Issue.record("text changed") }
        #expect(envelope.others[1].content == .messageUnsupported)
    }

    @Test func otherFailuresStillThrow() {
        let json = Data(#"{"content": 42, "others": []}"#.utf8)
        #expect(throws: (any Swift.Error).self) { try ResilientDecoding.decode(Envelope.self, from: json, decoder: decoder) }
    }
}
