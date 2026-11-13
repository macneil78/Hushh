import CryptoKit
import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushAI
@testable import HushCore
@testable import HushUI

/// Indexing with a fake chat history (ids 1...newest, newest first, `before` exclusive like
/// ConversationModel.historyPage) and a fake embedder, through the real ChatSearch.updateIndex.
@MainActor
struct ChatIndexCatchUpTests {
    final class FakeChat {
        var newest: Int64
        var pagesRead = 0
        /// Throws this once that many pages were read in the current run.
        var failure: (afterPages: Int, error: any Swift.Error)?

        init(newest: Int64) { self.newest = newest }

        func historyPage(before: Int64, limit: Int) throws -> [MessageModel] {
            if let failure, pagesRead >= failure.afterPages { throw failure.error }
            pagesRead += 1
            let top = before == 0 ? newest : before - 1
            guard top >= 1 else { return [] }
            return stride(from: top, through: max(1, top - Int64(limit) + 1), by: -1).map(Self.message)
        }

        static func message(_ id: Int64) -> MessageModel {
            MessageModel(
                id: id, date: .now, isOutgoing: false,
                sender: .init(id: 2, name: "Anna", accentColorId: 0, photoFileId: nil),
                body: .text(RichText(text: "message number \(id) about the meeting")),
                replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
            )
        }
    }

    let directory = FileManager.default.temporaryDirectory.appending(path: "hush-test-catchup-\(UUID().uuidString)")
    let key = SymmetricKey(size: .bits256)

    /// One search session: a fresh ChatIndex from the vault, as when the panel opens, and a save
    /// at the end, as when it closes. Returns how it ended.
    func session(_ chat: FakeChat, failAfter pages: Int? = nil, with error: any Swift.Error = CancellationError()) async -> String {
        chat.pagesRead = 0
        chat.failure = pages.map { ($0, error) }
        let index = ChatIndex(vault: LocalVault(directory: directory, key: key), chatId: 1)
        await index.load()
        var outcome = "finished"
        do {
            try await ChatSearch.updateIndex(
                index,
                history: { try chat.historyPage(before: $0, limit: $1) },
                embed: { texts in texts.map { _ in [Float](repeating: 0.05, count: SemanticIndex.dimensions) } },
                progress: { _ in }
            )
        } catch {
            outcome = "\(error)"
        }
        await index.save()
        return outcome
    }

    func missing(upTo newest: Int64) async -> [Int64] {
        let index = ChatIndex(vault: LocalVault(directory: directory, key: key), chatId: 1)
        await index.load()
        var missing: [Int64] = []
        for id in Int64(1)...newest where !(await index.contains(id)) { missing.append(id) }
        return missing
    }

    /// 200 new messages, and the search closes after one page of catch-up: the next run fills
    /// the gap.
    @Test func closingSearchDuringCatchUpLeavesNoGap() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = FakeChat(newest: 300)
        #expect(await session(chat) == "finished")
        #expect(await missing(upTo: 300).isEmpty)

        chat.newest = 500
        #expect(await session(chat, failAfter: 1).contains("CancellationError"))
        #expect(await session(chat) == "finished")
        let missing = await missing(upTo: 500)
        #expect(missing.isEmpty, "\(missing.count) messages never indexed: \(missing.first ?? 0)...\(missing.last ?? 0)")
    }

    /// The same with a network error part-way, and new messages arriving before the next run.
    @Test func anErrorDuringCatchUpLeavesNoGap() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = FakeChat(newest: 300)
        _ = await session(chat)
        chat.newest = 600
        #expect(await session(chat, failAfter: 2, with: URLError(.notConnectedToInternet)).contains("URLError"))
        chat.newest = 650
        // Closed again while finishing the earlier catch-up.
        _ = await session(chat, failAfter: 1)
        #expect(await session(chat) == "finished")
        let missing = await missing(upTo: 650)
        #expect(missing.isEmpty, "\(missing.count) messages never indexed: \(missing.first ?? 0)...\(missing.last ?? 0)")
    }
}

@MainActor
struct ChatSearchLookupTests {
    /// A lookup TDLib can't answer (here the client isn't logged in, as when offline or under a
    /// flood wait) is not a deleted message.
    @Test func aFailedLookupIsNotADeletedMessage() async {
        // Its own client, closed at the end: TDLib's receive loop can crash a process that
        // exits with a client open.
        let session = TDSession()
        let (conversation, _, _) = Fixtures.conversation(session: session)
        conversation.handle(Fixtures.newMessage(Fixtures.message(1, Fixtures.text("встречаемся в кафе на Тверской"))))
        let (found, gone) = await conversation.messages(withIds: [1, 2, 3])
        #expect(found.map(\.id) == [1])
        #expect(gone.isEmpty)
        _ = try? await session.client.close()
    }
}

/// What the search panel shows for a query and its results.
@MainActor
struct ChatSearchPanelTests {
    func result(_ text: String, words: Bool, meaning: Bool) -> ChatSearch.Result {
        let message = MessageModel(
            id: 1, date: .now, isOutgoing: false,
            sender: .init(id: 2, name: "Anna", accentColorId: 0, photoFileId: nil),
            body: .text(RichText(text: text)),
            replyToMessageId: nil, reply: nil, forwardedFrom: nil, isEdited: false, status: .sent
        )
        return ChatSearch.Result(message: message, matchesWords: words, matchesMeaning: meaning)
    }

    func bold(_ snippet: AttributedString) -> [String] {
        snippet.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(snippet[$0.range].characters) }
    }

    /// One Chinese or Japanese character is a word ("雨", rain); one Latin or Cyrillic letter isn't.
    @Test func oneCharacterQueriesInChineseAndJapanese() {
        #expect(ChatSearch.isSearchable("雨"))
        #expect(ChatSearch.isSearchable(" 猫 "))
        #expect(!ChatSearch.isSearchable("a"))
        #expect(!ChatSearch.isSearchable("я"))
        #expect(ChatSearch.isSearchable("ok"))
    }

    /// A result found only by meaning has no bold words, even where a word of the query is in it.
    @Test func meaningMatchesHaveNoBoldWords() {
        let text = "mentoring kids for math competitions"
        #expect(bold(ChatSearchView.snippet(for: result(text, words: false, meaning: true), query: "pizza for dinner")).isEmpty)
        #expect(bold(ChatSearchView.snippet(for: result(text, words: true, meaning: true), query: "math")) == ["math"])
        #expect(bold(ChatSearchView.snippet(for: result("今日は雨です", words: true, meaning: false), query: "雨")) == ["雨"])
    }

    /// Result dates say Today and Yesterday, as the chat does.
    @Test func datesSayTodayAndYesterdayLikeTheChat() {
        let now = Date.now
        #expect(ChatSearchView.date(now).hasPrefix("Today, "))
        #expect(ChatSearchView.date(now.addingTimeInterval(-86_400)).hasPrefix("Yesterday, "))
        let older = now.addingTimeInterval(-10 * 86_400)
        #expect(ChatSearchView.date(older) == older.formatted(date: .abbreviated, time: .shortened))
    }
}
