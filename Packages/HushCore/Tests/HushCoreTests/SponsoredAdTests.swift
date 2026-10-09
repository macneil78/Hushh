import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

struct SponsoredAdTests {
    @Test func telegramLinksOpenDirectlyOthersAskFirst() {
        #expect(SponsoredAd.isTrusted("https://t.me/somechannel"))
        #expect(SponsoredAd.isTrusted("https://fragment.com/number"))
        #expect(SponsoredAd.isTrusted("https://www.telegram.org/blog"))
        #expect(!SponsoredAd.isTrusted("https://example.com/offer"))
        // Look-alikes don't count.
        #expect(!SponsoredAd.isTrusted("https://t.me.example.com/"))
        #expect(!SponsoredAd.isTrusted("https://nott.me/"))
    }

    private func message(recommended: Bool, url: String) -> SponsoredMessage {
        SponsoredMessage(
            accentColorId: 3,
            additionalInfo: "",
            backgroundCustomEmojiId: 0,
            buttonText: "Open",
            canBeReported: true,
            content: .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil, text: FormattedText(entities: [], text: "Try it"))),
            isRecommended: recommended,
            messageId: 42,
            sponsor: AdvertisementSponsor(info: "Ad by Example Ltd.", photo: nil, url: url),
            title: "Example"
        )
    }

    @Test func labelsFollowTelegram() throws {
        let ad = try #require(SponsoredAd(message(recommended: false, url: "https://example.com")))
        #expect(ad.label == "Sponsored")
        #expect(ad.body == .text(RichText(text: "Try it")))
        #expect(ad.hasSponsorInfo)
        #expect(!ad.opensWithoutConfirmation)
        let recommended = try #require(SponsoredAd(message(recommended: true, url: "https://t.me/example")))
        #expect(recommended.label == "Recommended")
        #expect(recommended.opensWithoutConfirmation)
    }
}
