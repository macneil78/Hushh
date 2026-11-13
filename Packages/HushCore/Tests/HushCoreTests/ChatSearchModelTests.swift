import CryptoKit
import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushAI
@testable import HushCore

/// Search in a chat with the real model (multilingual-e5-small). Gated like ModelTests:
///
///     HUSH_MODEL_TESTS=1 swift test --filter ChatSearchModelTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HUSH_MODEL_TESTS"] != nil), .serialized)
struct ChatSearchModelTests {
    // MARK: The search panel, on a TDLib client that never logs in (every request fails)

    let directory = FileManager.default.temporaryDirectory.appending(path: "hush-test-search-\(UUID().uuidString)")

    /// An index of the calibration chat (ids from 1), as a finished earlier session left it,
    /// without text fingerprints (as indexes saved before them).
    func seedIndex(_ vault: LocalVault) async throws -> [Int64: String] {
        let texts = Dictionary(uniqueKeysWithValues: CalibrationCorpus.messages.enumerated().map { (Int64($0 + 1), $1.text) })
        let ids = texts.keys.sorted().filter { SearchText.isMeaningful(texts[$0]!) }
        let vectors = try await TextEmbedder(modelsIn: ModelTests.base).embed(passages: ids.map { texts[$0]! })
        var index = SemanticIndex()
        for (id, vector) in zip(ids, vectors) { index.add(id, vector: vector) }
        index.newestSeen = Int64(texts.count)
        index.oldestSeen = 1
        index.seenCount = texts.count
        index.isComplete = true
        try vault.write(index.serialized(), to: "index-\(Fixtures.chatId)")
        return texts
    }

    func saved(_ vault: LocalVault) -> SemanticIndex? {
        vault.read("index-\(Fixtures.chatId)").flatMap(SemanticIndex.init(serialized:))
    }

    func run(_ search: ChatSearch, _ query: String) async {
        search.query = ""
        search.query = query
        try? await Task.sleep(for: .milliseconds(350))
        for _ in 0..<400 where search.isSearching { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// A lookup TDLib can't answer keeps the index entry; only "not found" removes it.
    @Test func aFailedLookupKeepsIndexEntries() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory, key: SymmetricKey(size: .bits256))
        _ = try await seedIndex(vault)
        let before = try #require(saved(vault))
        let session = TDSession()
        let (conversation, _, _) = Fixtures.conversation(session: session)
        let models = ModelStore(base: ModelTests.base)
        let search = ChatSearch(conversation: conversation, models: models, vault: vault)
        search.start()
        let queries = ["зубной врач", "wifi password", "потерял ключи", "grandmother in hospital"]
        // The queries do have matches by meaning, which the search then has to look up.
        let generic = try await models.embedder.genericQuery()
        for query in queries {
            #expect(!before.meaningMatches(try await models.embedder.embed(query: query), generic: generic).isEmpty, "\(query)")
            await run(search, query)
        }
        search.stop()
        try await Task.sleep(for: .milliseconds(500))
        #expect(saved(vault)?.count == before.count, "index entries were deleted because a lookup failed")
        _ = try? await session.client.close()
    }

    /// An edited message is found by what it says now, never by what it said before.
    @Test func editedMessagesAreFoundByWhatTheySayNow() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory, key: SymmetricKey(size: .bits256))
        let texts = try await seedIndex(vault)
        let session = TDSession()
        let (conversation, _, _) = Fixtures.conversation(session: session)
        for id in texts.keys.sorted() { conversation.handle(Fixtures.newMessage(Fixtures.message(id, Fixtures.text(texts[id]!)))) }
        let pizza = try #require(texts.first { $0.value == "давай закажем пиццу на ужин" }?.key)
        let models = ModelStore(base: ModelTests.base)
        let search = ChatSearch(conversation: conversation, models: models, vault: vault)
        search.start()
        await run(search, "пицца на ужин")
        #expect(search.results.contains { $0.id == pizza && $0.matchesMeaning })

        // Edited while the search is open.
        conversation.handle(.updateMessageContent(UpdateMessageContent(
            chatId: Fixtures.chatId, messageId: pizza, newContent: Fixtures.text("записались на курсы испанского языка по вторникам")
        )))
        try await Task.sleep(for: .seconds(1))
        await run(search, "пицца на ужин")
        #expect(!search.results.contains { $0.id == pizza }, "the edited message still matches its old meaning")
        await run(search, "Spanish classes")
        #expect(search.results.contains { $0.id == pizza && $0.matchesMeaning }, "the edited message isn't found by its new meaning")
        search.stop()
        _ = try? await session.client.close()
    }

    /// The same edit, made before the search was ever opened in this chat.
    @Test func editsBeforeTheSearchOpensAreCaughtToo() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory, key: SymmetricKey(size: .bits256))
        let texts = try await seedIndex(vault)
        let session = TDSession()
        let (conversation, _, _) = Fixtures.conversation(session: session)
        for id in texts.keys.sorted() { conversation.handle(Fixtures.newMessage(Fixtures.message(id, Fixtures.text(texts[id]!)))) }
        let pizza = try #require(texts.first { $0.value == "давай закажем пиццу на ужин" }?.key)
        conversation.handle(.updateMessageContent(UpdateMessageContent(
            chatId: Fixtures.chatId, messageId: pizza, newContent: Fixtures.text("записались на курсы испанского языка по вторникам")
        )))
        let models = ModelStore(base: ModelTests.base)
        let search = ChatSearch(conversation: conversation, models: models, vault: vault)
        search.start()
        await run(search, "пицца на ужин")
        #expect(!search.results.contains { $0.id == pizza })
        try await Task.sleep(for: .seconds(3))
        await run(search, "Spanish classes")
        #expect(search.results.contains { $0.id == pizza && $0.matchesMeaning })
        search.stop()
        _ = try? await session.client.close()
    }

    // MARK: Damaged model files

    /// A clone of the downloaded model under a fresh base folder (APFS clones: no copying).
    static func clone() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "hush-test-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        let target = AIModel.search.folder(in: base)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/cp")
        process.arguments = ["-c", "-R", AIModel.search.folder(in: ModelTests.base).path, target.path]
        try process.run()
        process.waitUntilExit()
        return base
    }

    /// Zeroed weights of the right size are found damaged instead of giving empty vectors.
    @Test func zeroedWeightsAreFoundDamaged() async throws {
        let base = try Self.clone()
        defer { try? FileManager.default.removeItem(at: base) }
        let handle = try FileHandle(forUpdating: AIModel.search.folder(in: base).appending(path: "model.safetensors"))
        try handle.seek(toOffset: 200_000)
        for _ in 0..<40 { handle.write(Data(count: 10_000_000)) }
        try handle.close()
        await #expect(throws: TextEmbedder.Damaged.self) {
            _ = try await TextEmbedder(modelsIn: base).embed(query: "где встречаемся")
        }
    }

    /// A model that fails to load is marked damaged, and the panel asks for it to be downloaded
    /// again.
    @Test func aModelThatFailsToLoadSaysSo() async throws {
        let base = try Self.clone()
        defer { try? FileManager.default.removeItem(at: base) }
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"hidden_size\": 7}".utf8).write(to: AIModel.search.folder(in: base).appending(path: "config.json"))
        let vault = LocalVault(directory: directory, key: SymmetricKey(size: .bits256))
        _ = try await seedIndex(vault)
        let models = ModelStore(base: base)
        #expect(models.state(of: .search) == .ready)
        let session = TDSession()
        let (conversation, _, _) = Fixtures.conversation(session: session)
        let search = ChatSearch(conversation: conversation, models: models, vault: vault)
        search.start()
        await run(search, "зубной врач")
        #expect(models.state(of: .search) == .failed(ModelStore.damaged))
        #expect(search.indexState == .needsModel)
        search.stop()
        _ = try? await session.client.close()
    }

    /// Deleting the model in Settings turns search by meaning off in the open panel.
    @Test func deletingTheModelTurnsMeaningOff() async throws {
        let base = try Self.clone()
        defer { try? FileManager.default.removeItem(at: base) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = LocalVault(directory: directory, key: SymmetricKey(size: .bits256))
        _ = try await seedIndex(vault)
        let models = ModelStore(base: base)
        let session = TDSession()
        let (conversation, _, _) = Fixtures.conversation(session: session)
        let search = ChatSearch(conversation: conversation, models: models, vault: vault)
        search.start()
        for _ in 0..<40 where search.indexState == .needsModel || search.indexState == .indexing(0) {
            try await Task.sleep(for: .milliseconds(50))
        }
        await models.delete(.search)
        search.modelStateChanged()
        #expect(search.indexState == .needsModel)
        search.stop()
        _ = try? await session.client.close()
    }
}
