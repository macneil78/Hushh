import Testing
@testable import HushCore

struct VisibilityPolicyTests {
    private func chat(_ kind: ChatKind, joinedStub: Bool = false) -> ChatSummary {
        ChatSummary(id: 1, kind: kind, title: "Chat", isJoinedTelegramStub: joinedStub)
    }

    @Test(arguments: [ChatKind.group, .channel, .bot, .service])
    func groupsChannelsBotsAndServiceAreHiddenUntilPicked(kind: ChatKind) {
        #expect(!VisibilityPolicy.isVisible(chat(kind), choice: nil))
        #expect(VisibilityPolicy.isVisible(chat(kind), choice: .show))
        #expect(!VisibilityPolicy.isVisible(chat(kind), choice: .hide))
    }

    @Test(arguments: [ChatKind.person, .savedMessages, .secret])
    func peopleAreVisibleUntilHidden(kind: ChatKind) {
        #expect(VisibilityPolicy.isVisible(chat(kind), choice: nil))
        #expect(!VisibilityPolicy.isVisible(chat(kind), choice: .hide))
    }

    @Test func joinedTelegramStubIsHiddenUntilARealMessageArrives() {
        #expect(!VisibilityPolicy.isVisible(chat(.person, joinedStub: true), choice: nil))
        #expect(VisibilityPolicy.isVisible(chat(.person, joinedStub: false), choice: nil))
        #expect(VisibilityPolicy.isVisible(chat(.person, joinedStub: true), choice: .show))
    }
}
