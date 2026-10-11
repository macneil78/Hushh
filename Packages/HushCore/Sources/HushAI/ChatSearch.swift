import Foundation
import HushCore
import Observation
import OSLog

/// Search in one chat: Telegram's word search across the whole history, and search by meaning
/// over the chat's index, merged. While search is open, the index catches up with new messages
/// and keeps reading back through older ones.
@MainActor @Observable
public final class ChatSearch {
    public struct Result: Identifiable, Equatable, Sendable {
        public let message: MessageModel
        public let matchesWords: Bool
        public let matchesMeaning: Bool
        public var id: Int64 { message.id }
    }

    public enum IndexState: Equatable, Sendable {
        /// The search model isn't downloaded: word search only.
        case needsModel
        case indexing(Int)
        case ready(Int)
        case failed
    }

    public var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    public private(set) var results: [Result] = []
    public private(set) var isSearching = false
    public private(set) var indexState = IndexState.needsModel

    @ObservationIgnored private let conversation: ConversationModel
    @ObservationIgnored private let models: ModelStore
    @ObservationIgnored private let index: ChatIndex
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Indexing reads at most this many messages back.
    static let historyLimit = 10_000
    /// A page of history at a time, then a pause: indexing should never make the Mac stutter.
    static let pageSize = 50
    static let pause = Duration.milliseconds(150)
    /// Of the meaning matches, those within this much of the best and above the floor count.
    static let scoreWindow: Float = 0.05
    static let scoreFloor: Float = 0.80

    private static let log = Logger(subsystem: "Hush", category: "ai")

    public init(conversation: ConversationModel, models: ModelStore, vault: LocalVault?) {
        self.conversation = conversation
        self.models = models
        index = ChatIndex(vault: vault, chatId: conversation.chatId)
    }

    /// When the search opens: loads the index and, if the model is there, brings it up to date.
    public func start() {
        guard models.isReady(.search) else {
            indexState = .needsModel
            return
        }
        guard indexTask == nil else { return }
        // Low priority, in the background: search works meanwhile with what's indexed so far.
        indexTask = Task(priority: .utility) { await updateIndex() }
    }

    /// When the search closes: stops reading history and saves what's indexed.
    public func stop() {
        indexTask?.cancel()
        indexTask = nil
        searchTask?.cancel()
        let index = index
        Task { await index.save() }
    }

    // MARK: Indexing

    private func updateIndex() async {
        await index.load()
        indexState = .indexing(await index.status.count)
        do {
            // Messages newer than the index first, then further back.
            try await read(from: 0, stopAt: await index.status.newestSeen)
            let status = await index.status
            if !status.isComplete, status.seenCount < Self.historyLimit {
                try await read(from: status.oldestSeen, stopAt: 0)
            }
            indexState = .ready(await index.status.count)
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Indexing chat failed: \(String(describing: error), privacy: .public)")
            let count = await index.status.count
            indexState = count > 0 ? .ready(count) : .failed
        }
        await index.save()
        indexTask = nil
    }

    /// Reads history back from `start` (0: the newest) until `stopAt` (0: the beginning, or the
    /// history limit), embedding what's meaningful. Fetching a page and picking out its text is
    /// quick; embedding and the index work happen off the main thread.
    private func read(from start: Int64, stopAt: Int64) async throws {
        var before = start
        while true {
            try Task.checkCancellation()
            if stopAt == 0, await index.status.seenCount >= Self.historyLimit { return }
            let page = try await conversation.historyPage(before: before, limit: Self.pageSize)
            if page.isEmpty {
                if stopAt == 0 { await index.markComplete() }
                return
            }
            let fresh = page.filter { $0.id > stopAt }
            let texts = fresh.compactMap { message -> (Int64, String)? in
                let text = SearchText.of(message)
                return SearchText.isMeaningful(text) ? (message.id, String(text.prefix(1000))) : nil
            }
            let vectors = texts.isEmpty ? [] : try await models.embedder.embed(passages: texts.map(\.1))
            let count = await index.add(Array(zip(texts.map(\.0), vectors)), seen: fresh.map(\.id))
            indexState = .indexing(count)
            // Caught up with what was indexed before.
            if fresh.count < page.count { return }
            before = page.last!.id
            try await Task.sleep(for: Self.pause)
        }
    }

    // MARK: Searching

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            // Wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private func search(_ query: String) async {
        // Word matches show at once; meaning matches join when they're computed.
        let words = (try? await conversation.searchMessages(query, limit: 30)) ?? []
        guard !Task.isCancelled else { return }
        // Telegram's word search doesn't look in transcripts; the loaded ones are checked here.
        let wordTranscriptMatches = conversation.messages
            .filter { $0.transcript?.localizedStandardContains(query) == true }
            .map(\.id).reversed()
        results = words.map { Result(message: $0, matchesWords: true, matchesMeaning: false) }

        var meaning: [Int64] = []
        if models.isReady(.search), await index.status.count > 0, let vector = try? await models.embedder.embed(query: query) {
            let hits = await index.search(vector, limit: 30)
            let best = hits.first?.score ?? 0
            meaning = hits.filter { $0.score >= max(Self.scoreFloor, best - Self.scoreWindow) }.map(\.id)
        }
        guard !Task.isCancelled else { return }

        let wordIds = words.map(\.id)
        let ordered = Array(RankFusion.fuse([wordIds, Array(wordTranscriptMatches), meaning]).prefix(30))
        var known = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = ordered.filter { known[$0] == nil }
        for message in await conversation.messages(withIds: missing) { known[message.id] = message }
        guard !Task.isCancelled else { return }

        // Gone since they were indexed.
        let gone = Set(missing.filter { known[$0] == nil })
        if !gone.isEmpty { await index.remove(gone) }
        let wordSet = Set(wordIds).union(wordTranscriptMatches)
        let meaningSet = Set(meaning)
        results = ordered.compactMap { id in
            known[id].map { Result(message: $0, matchesWords: wordSet.contains(id), matchesMeaning: meaningSet.contains(id)) }
        }
        isSearching = false
    }
}

/// A chat's search index, off the main thread: adding, searching, and saving (sealing and
/// writing megabytes) happen here, so the window never waits for them.
actor ChatIndex {
    struct Status: Sendable {
        var count = 0
        var newestSeen: Int64 = 0
        var oldestSeen: Int64 = 0
        var seenCount = 0
        var isComplete = false
    }

    private var index = SemanticIndex()
    private let vault: LocalVault?
    private let fileName: String
    private var isLoaded = false
    private var unsaved = 0

    /// Saved along the way, so a long first pass isn't lost if Hushh quits.
    static let saveEvery = 2_000

    init(vault: LocalVault?, chatId: Int64) {
        self.vault = vault
        fileName = "index-\(chatId)"
    }

    func load() {
        guard !isLoaded else { return }
        isLoaded = true
        if let data = vault?.read(fileName), let saved = SemanticIndex(serialized: data) {
            index = saved
        }
    }

    var status: Status {
        Status(count: index.count, newestSeen: index.newestSeen, oldestSeen: index.oldestSeen, seenCount: index.seenCount, isComplete: index.isComplete)
    }

    func contains(_ id: Int64) -> Bool {
        index.contains(id)
    }

    /// Adds vectors, and notes which messages were looked at. Returns how many are indexed.
    func add(_ entries: [(Int64, [Float])], seen: [Int64]) -> Int {
        for (id, vector) in entries { index.add(id, vector: vector) }
        if let newest = seen.max() { index.newestSeen = max(index.newestSeen, newest) }
        if let oldest = seen.min(), index.oldestSeen == 0 || oldest < index.oldestSeen { index.oldestSeen = oldest }
        index.seenCount += seen.count
        unsaved += seen.count
        if unsaved >= Self.saveEvery { save() }
        return index.count
    }

    func markComplete() {
        index.isComplete = true
    }

    func remove(_ ids: Set<Int64>) {
        index.remove(ids)
    }

    func search(_ vector: [Float], limit: Int) -> [(id: Int64, score: Float)] {
        index.search(vector, limit: limit)
    }

    func save() {
        guard isLoaded else { return }
        unsaved = 0
        try? vault?.write(index.serialized(), to: fileName)
    }
}
