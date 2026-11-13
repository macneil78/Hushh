import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

struct ReactionTests {
    private func emoji(_ emoji: String, premium: Bool = false) -> AvailableReaction {
        AvailableReaction(needsPremium: premium, type: .reactionTypeEmoji(ReactionTypeEmoji(emoji: emoji)))
    }

    private func custom(_ id: Int64, premium: Bool = true) -> AvailableReaction {
        AvailableReaction(needsPremium: premium, type: .reactionTypeCustomEmoji(ReactionTypeCustomEmoji(customEmojiId: TdInt64(id))))
    }

    private func available(top: [AvailableReaction], recent: [AvailableReaction] = [], popular: [AvailableReaction] = [], allowCustomEmoji: Bool = false, reason: ReactionUnavailabilityReason? = nil) -> AvailableReactions {
        AvailableReactions(allowCustomEmoji: allowCustomEmoji, areTags: false, popularReactions: popular, recentReactions: recent, topReactions: top, unavailabilityReason: reason)
    }

    @Test func keepsTelegramsOrderWithoutRepeats() {
        let options = ConversationModel.reactionOptions(
            from: available(top: [emoji("❤️"), emoji("👍")], recent: [emoji("👍"), emoji("🔥")], popular: [emoji("🔥"), emoji("😂")]),
            isPremium: false
        )
        #expect(options.top == [.emoji("❤️"), .emoji("👍")])
        #expect(options.more == [.emoji("🔥"), .emoji("😂")])
    }

    @Test func premiumReactionsAreLeftOutWithoutPremium() {
        let reactions = available(top: [emoji("❤️"), custom(42)], recent: [custom(7)], allowCustomEmoji: true)
        let free = ConversationModel.reactionOptions(from: reactions, isPremium: false)
        #expect(free.top == [.emoji("❤️")])
        #expect(free.more.isEmpty)
        #expect(!free.allowsCustomEmoji)

        let premium = ConversationModel.reactionOptions(from: reactions, isPremium: true)
        #expect(premium.top == [.emoji("❤️"), .customEmoji(42)])
        #expect(premium.more == [.customEmoji(7)])
        #expect(premium.allowsCustomEmoji)
    }

    @Test func saysWhyYouCantReact() {
        let options = ConversationModel.reactionOptions(from: available(top: [], reason: .reactionUnavailabilityReasonGuest), isPremium: false)
        #expect(options.unavailableReason == "Join the chat to react.")
    }

    @Test func customEmojiReactionsKeepTheirId() {
        let type = ReactionType.reactionTypeCustomEmoji(ReactionTypeCustomEmoji(customEmojiId: TdInt64(5_368_324_170_671_202_286)))
        let kind = Reaction.Kind(type)
        #expect(kind == .customEmoji(5_368_324_170_671_202_286))
        #expect(kind?.reactionType == type)
        #expect(Reaction.Kind(.reactionTypePaid) == nil)
    }
}
