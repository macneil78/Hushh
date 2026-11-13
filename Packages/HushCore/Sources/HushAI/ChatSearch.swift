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
    @ObservationIgnored private var editsTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Set<Int64>, any Error>?

    /// Indexing reads at most this many messages back.
    static let historyLimit = 10_000
    /// A page of history at a time, then a pause: indexing should never make the Mac stutter.
    static let pageSize = 50
    static let pause = Duration.milliseconds(150)

    private static let log = Logger(subsystem: "Hush", category: "ai")

    public init(conversation: ConversationModel, models: ModelStore, vault: LocalVault?) {
        self.conversation = conversation
        self.models = models
        index = ChatIndex(vault: vault, chatId: conversation.chatId)
    }

    /// Whether a query is long enough to search for: two characters, or one Chinese or Japanese
    /// character (a whole word: "雨", rain).
    public nonisolated static func isSearchable(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.count >= 2 || query.unicodeScalars.contains(where: SearchText.isWordlessScript)
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
        editsTask = Task(priority: .utility) { await followEdits() }
    }

    /// When the search closes: stops reading history and saves what's indexed.
    public func stop() {
        indexTask?.cancel()
        indexTask = nil
        editsTask?.cancel()
        editsTask = nil
        searchTask?.cancel()
        let index = index
        Task { await index.save() }
    }

    /// When the model is downloaded, deleted or found damaged while the search is open.
    public func modelStateChanged() {
        if models.isReady(.search) {
            start()
        } else {
            indexTask?.cancel()
            indexTask = nil
            editsTask?.cancel()
            editsTask = nil
            indexState = .needsModel
        }
        // Results by meaning come or go with the model.
        scheduleSearch()
    }

    // MARK: Indexing

    private func updateIndex() async {
        await index.load()
        indexState = .indexing(await index.status.count)
        do {
            try await Self.updateIndex(
                index,
                history: { [conversation] in try await conversation.historyPage(before: $0, limit: $1) },
                embed: { [weak self] texts in try await self?.embed(passages: texts) ?? [] },
                progress: { [weak self] in self?.indexState = .indexing($0) }
            )
            indexState = .ready(await index.status.count)
        } catch is CancellationError {
            return
        } catch {
            Self.log.error("Indexing chat failed: \(String(describing: error), privacy: .public)")
            let count = await index.status.count
            indexState = count > 0 ? .ready(count) : .failed
            if !models.isReady(.search) { indexState = .needsModel }
        }
        await index.save()
        indexTask = nil
        // A query typed while indexing ran got what was indexed then: search again with it all.
        if Self.isSearchable(query) { scheduleSearch() }
    }

    /// Brings an index up to date, from where earlier runs stopped: first the rest of a catch-up
    /// an earlier run didn't finish, then messages newer than the index, then further back.
    /// Whatever stops it (closing the search, an error), the next run goes on without a gap.
    static func updateIndex(
        _ index: ChatIndex,
        history: (_ before: Int64, _ limit: Int) async throws -> [MessageModel],
        embed: ([String]) async throws -> [[Float]],
        progress: (Int) -> Void
    ) async throws {
        if let gap = await index.status.gap {
            try await read(index, from: gap.from, stopAt: gap.stop, history: history, embed: embed, progress: progress)
        }
        let newest = await index.status.newestSeen
        if newest > 0 {
            try await read(index, from: 0, stopAt: newest, history: history, embed: embed, progress: progress)
        }
        let status = await index.status
        if !status.isComplete, status.seenCount < historyLimit {
            try await read(index, from: status.oldestSeen, stopAt: 0, history: history, embed: embed, progress: progress)
        }
    }

    /// Reads history back from `start` (0: the newest) until `stopAt` (0: the beginning, or the
    /// history limit), embedding what's meaningful. Fetching a page and picking out its text is
    /// quick; embedding and the index work happen off the main thread.
    private static func read(
        _ index: ChatIndex,
        from start: Int64,
        stopAt: Int64,
        history: (Int64, Int) async throws -> [MessageModel],
        embed: ([String]) async throws -> [[Float]],
        progress: (Int) -> Void
    ) async throws {
        let isCatchUp = stopAt > 0
        var before = start
        while true {
            try Task.checkCancellation()
            if !isCatchUp, await index.status.seenCount >= historyLimit { return }
            let page = try await history(before, pageSize)
            if page.isEmpty {
                if isCatchUp { await index.closeGap() } else { await index.markComplete() }
                return
            }
            let fresh = page.filter { $0.id > stopAt }
            let texts = fresh.compactMap { message -> (Int64, String)? in
                let text = SearchText.indexed(message)
                return SearchText.isMeaningful(text) ? (message.id, text) : nil
            }
            let vectors = texts.isEmpty ? [] : try await embed(texts.map(\.1))
            let entries = zip(texts, vectors).map { ChatIndex.Entry(id: $0.0, vector: $1, fingerprint: SearchText.fingerprint($0.1)) }
            // Caught up with what was indexed before, when the page reaches it.
            let isCaughtUp = fresh.count < page.count
            let gap = isCatchUp && !isCaughtUp ? SemanticIndex.Gap(from: page.last!.id, stop: stopAt) : nil
            progress(await index.add(entries, seen: fresh.map(\.id), gap: gap, isCatchUp: isCatchUp))
            if isCaughtUp { return }
            before = page.last!.id
            try await Task.sleep(for: pause)
        }
    }

    /// While the search is open, edits to the chat's loaded messages are re-embedded, so the
    /// index follows what messages say now. The first pass also catches edits made before.
    private func followEdits() async {
        let conversation = conversation
        for await messages in Observations({ conversation.messages }) {
            do {
                _ = try await refresh(messages)
            } catch is CancellationError {
                return
            } catch {
                Self.log.error("Re-indexing edited messages failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Re-embeds the messages whose text changed since they were indexed, adds those that became
    /// worth indexing, and drops those that stopped being. Only messages indexing went past.
    /// Returns the ids whose vectors changed. One at a time: a refresh still embedding a
    /// message's old text must not write after one that has its new text.
    @discardableResult
    private func refresh(_ messages: [MessageModel]) async throws -> Set<Int64> {
        let previous = refreshing
        let task = Task {
            _ = await previous?.result
            return try await refreshNow(messages)
        }
        refreshing = task
        return try await task.value
    }

    private func refreshNow(_ messages: [MessageModel]) async throws -> Set<Int64> {
        guard models.isReady(.search) else { return [] }
        await index.load()
        let status = await index.status
        let seen = messages.filter { status.hasSeen($0.id) }
        guard !seen.isEmpty else { return [] }
        let known = await index.fingerprints(of: seen.map(\.id))
        var changed: [(id: Int64, text: String)] = []
        var dropped: Set<Int64> = []
        for message in seen {
            let text = SearchText.indexed(message)
            if let fingerprint = known[message.id], fingerprint == SearchText.fingerprint(text) { continue }
            if SearchText.isMeaningful(text) {
                changed.append((message.id, text))
            } else if known[message.id] != nil {
                dropped.insert(message.id)
            }
        }
        guard !changed.isEmpty || !dropped.isEmpty else { return [] }
        let vectors = try await embed(passages: changed.map(\.text))
        let entries = zip(changed, vectors).map { ChatIndex.Entry(id: $0.id, vector: $1, fingerprint: SearchText.fingerprint($0.text)) }
        await index.update(entries, removing: dropped)
        return Set(changed.map(\.id)).union(dropped)
    }

    /// The model's vectors; when the model fails (damaged files), Settings and the panel say so.
    private func embed(passages: [String]) async throws -> [[Float]] {
        do {
            return try await models.embedder.embed(passages: passages)
        } catch {
            models.modelFailed(.search, error)
            throw error
        }
    }

    // MARK: Searching

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSearchable(query) else {
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
        var known = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for message in conversation.messages where wordTranscriptMatches.contains(message.id) { known[message.id] = message }

        let vectors = await queryVectors(query)
        var meaning: [Int64] = []
        if let vectors { meaning = await index.meaningMatches(vectors.query, generic: vectors.generic) }
        guard !Task.isCancelled else { return }
        if let vectors, !meaning.isEmpty {
            let (found, gone) = await conversation.messages(withIds: meaning.filter { known[$0] == nil })
            guard !Task.isCancelled else { return }
            for message in found { known[message.id] = message }
            // Deleted since they were indexed. (A lookup that failed only leaves a result out.)
            if !gone.isEmpty { await index.remove(gone) }
            // Edited since they were indexed: their vectors said what they used to say. Once
            // they (and edits being re-embedded already) have new vectors, they stay only if
            // they still match.
            _ = try? await refresh(meaning.compactMap { known[$0] })
            let still = Set(await index.meaningMatches(vectors.query, generic: vectors.generic))
            meaning.removeAll { !still.contains($0) }
        }
        guard !Task.isCancelled else { return }

        let wordIds = words.map(\.id)
        let ordered = RankFusion.fuse([wordIds, Array(wordTranscriptMatches), meaning]).prefix(30)
        let wordSet = Set(wordIds).union(wordTranscriptMatches)
        let meaningSet = Set(meaning)
        results = ordered.compactMap { id in
            known[id].map { Result(message: $0, matchesWords: wordSet.contains(id), matchesMeaning: meaningSet.contains(id)) }
        }
        isSearching = false
    }

    /// The query's vector and the generic one, to find what's close in meaning to it (see
    /// `MeaningMatch`). Nil when there's nothing to search by meaning.
    private func queryVectors(_ query: String) async -> (query: [Float], generic: [Float])? {
        guard models.isReady(.search), MeaningMatch.isWorthSearching(query), await index.status.count > 0 else { return nil }
        do {
            return (try await models.embedder.embed(query: query), try await models.embedder.genericQuery())
        } catch {
            models.modelFailed(.search, error)
            if !models.isReady(.search) { indexState = .needsModel }
            return nil
        }
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
        var gap: SemanticIndex.Gap?

        /// Whether indexing went past a message: it's in the range read, and not in a gap.
        func hasSeen(_ id: Int64) -> Bool {
            guard seenCount > 0, id >= oldestSeen, id <= newestSeen else { return false }
            if let gap, id > gap.stop, id < gap.from { return false }
            return true
        }
    }

    struct Entry: Sendable {
        var id: Int64
        var vector: [Float]
        var fingerprint: UInt32
    }

    private var index = SemanticIndex()
    private let vault: LocalVault?
    private let fileName: String
    private var isLoaded = false
    /// Messages looked at since the last save.
    private var unsaved = 0
    /// Anything changed since the last save: closing the search doesn't rewrite megabytes for
    /// nothing.
    private var isChanged = false

    /// Saved along the way, so a long first pass isn't lost if Hushh quits.
    static let saveEvery = 2_000

    private static let log = Logger(subsystem: "Hush", category: "ai")

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
        Status(count: index.count, newestSeen: index.newestSeen, oldestSeen: index.oldestSeen, seenCount: index.seenCount, isComplete: index.isComplete, gap: index.gap)
    }

    func contains(_ id: Int64) -> Bool {
        index.contains(id)
    }

    /// Adds vectors, and notes which messages were looked at and, in a catch-up, what's left of
    /// it (nil: it's done). Returns how many are indexed.
    func add(_ entries: [Entry], seen: [Int64], gap: SemanticIndex.Gap? = nil, isCatchUp: Bool = false) -> Int {
        for entry in entries { index.add(entry.id, vector: entry.vector, fingerprint: entry.fingerprint) }
        if let newest = seen.max() { index.newestSeen = max(index.newestSeen, newest) }
        if let oldest = seen.min(), index.oldestSeen == 0 || oldest < index.oldestSeen { index.oldestSeen = oldest }
        if isCatchUp { index.gap = gap }
        index.seenCount += seen.count
        unsaved += seen.count
        isChanged = true
        if unsaved >= Self.saveEvery { save() }
        return index.count
    }

    /// New vectors for messages already looked at (edited ones), and ones to drop.
    func update(_ entries: [Entry], removing removed: Set<Int64>) {
        for entry in entries { index.add(entry.id, vector: entry.vector, fingerprint: entry.fingerprint) }
        index.remove(removed)
        isChanged = true
    }

    /// The fingerprints of the indexed ones among these messages.
    func fingerprints(of ids: [Int64]) -> [Int64: UInt32] {
        var result: [Int64: UInt32] = [:]
        for id in ids {
            if let fingerprint = index.fingerprint(of: id) { result[id] = fingerprint }
        }
        return result
    }

    func markComplete() {
        index.isComplete = true
        isChanged = true
    }

    /// A catch-up ran out of history before reaching what was indexed before (those messages
    /// were deleted): nothing is left to read.
    func closeGap() {
        index.gap = nil
        isChanged = true
    }

    func remove(_ ids: Set<Int64>) {
        index.remove(ids)
        isChanged = true
    }

    func meaningMatches(_ vector: [Float], generic: [Float]) -> [Int64] {
        index.meaningMatches(vector, generic: generic)
    }

    func save() {
        guard isLoaded, isChanged, let vault else { return }
        unsaved = 0
        do {
            try vault.write(index.serialized(), to: fileName)
            isChanged = false
        } catch {
            Self.log.error("Saving a search index failed: \(String(describing: error), privacy: .public)")
        }
    }
}
