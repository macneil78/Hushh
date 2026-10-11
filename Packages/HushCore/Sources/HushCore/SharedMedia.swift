@preconcurrency import TDLibKit
import Foundation
import Observation

/// The tabs of a chat's shared media, as Telegram's apps group them. (Gifts are left out, like
/// the rest of Telegram's gift noise.)
public enum SharedMediaKind: String, CaseIterable, Identifiable, Sendable {
    case media
    case files
    case links
    case voice
    case music

    public var id: Self { self }

    public var title: String {
        switch self {
        case .media: "Media"
        case .files: "Files"
        case .links: "Links"
        case .voice: "Voice"
        case .music: "Music"
        }
    }

    /// "1 photo or video", "12 files"…
    public func countText(_ count: Int) -> String {
        let (one, many) = switch self {
        case .media: ("photo or video", "photos and videos")
        case .files: ("file", "files")
        case .links: ("link", "links")
        case .voice: ("voice message", "voice messages")
        case .music: ("song", "songs")
        }
        return "\(count) \(count == 1 ? one : many)"
    }

    var filter: SearchMessagesFilter {
        switch self {
        case .media: .searchMessagesFilterPhotoAndVideo
        case .files: .searchMessagesFilterDocument
        case .links: .searchMessagesFilterUrl
        case .voice: .searchMessagesFilterVoiceNote
        case .music: .searchMessagesFilterAudio
        }
    }
}

/// A chat's photos and videos, files, links, voice messages and music: each kind newest first,
/// loaded a page at a time as you scroll.
@MainActor @Observable
public final class SharedMediaModel {
    public private(set) var counts: [SharedMediaKind: Int] = [:]
    private var lists: [SharedMediaKind: [MessageModel]] = [:]
    private var loading: Set<SharedMediaKind> = []
    private var finished: Set<SharedMediaKind> = []
    @ObservationIgnored private var nextFromMessageId: [SharedMediaKind: Int64] = [:]
    @ObservationIgnored private var countsTask: Task<Void, Never>?

    @ObservationIgnored private let chatId: Int64
    @ObservationIgnored private let client: TDLibClient
    @ObservationIgnored private let map: (Message) -> MessageModel?

    static let pageSize = 60

    init(chatId: Int64, client: TDLibClient, map: @escaping (Message) -> MessageModel?) {
        self.chatId = chatId
        self.client = client
        self.map = map
    }

    public func items(_ kind: SharedMediaKind) -> [MessageModel] {
        lists[kind] ?? []
    }

    public func isLoading(_ kind: SharedMediaKind) -> Bool {
        loading.contains(kind)
    }

    public func hasMore(_ kind: SharedMediaKind) -> Bool {
        !finished.contains(kind)
    }

    /// How many of each kind there are, for the tabs. Asked once.
    public func loadCounts() async {
        if let countsTask { return await countsTask.value }
        let task = Task {
            for kind in SharedMediaKind.allCases {
                if let count = try? await client.getChatMessageCount(chatId: chatId, filter: kind.filter, returnLocal: false, topicId: nil) {
                    counts[kind] = count.count
                }
            }
        }
        countsTask = task
        await task.value
    }

    /// The next page of one kind. Does nothing while a page is on its way, or once all are in.
    public func loadMore(_ kind: SharedMediaKind) async {
        guard !loading.contains(kind), !finished.contains(kind) else { return }
        loading.insert(kind)
        defer { loading.remove(kind) }
        do {
            let found = try await client.resilientSearchChatMessages(
                chatId: chatId,
                filter: kind.filter,
                fromMessageId: nextFromMessageId[kind] ?? 0,
                limit: Self.pageSize
            )
            var list = lists[kind] ?? []
            let known = Set(list.map(\.id))
            list.append(contentsOf: found.messages.compactMap(map).filter { !known.contains($0.id) })
            lists[kind] = list
            if found.nextFromMessageId == 0 || found.messages.isEmpty {
                finished.insert(kind)
            } else {
                nextFromMessageId[kind] = found.nextFromMessageId
            }
        } catch {
            Log.session.error("Loading shared \(kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            finished.insert(kind)
        }
    }

    /// A message's content changed (a transcription arrived, say).
    func replaceBody(of messageId: Int64, with body: MessageModel.Body) {
        for (kind, list) in lists {
            if let index = list.firstIndex(where: { $0.id == messageId }) { lists[kind]![index].body = body }
        }
    }

    /// Messages deleted in the chat leave the lists too.
    func remove(_ ids: Set<Int64>) {
        for (kind, list) in lists where list.contains(where: { ids.contains($0.id) }) {
            lists[kind] = list.filter { !ids.contains($0.id) }
            if let count = counts[kind] { counts[kind] = max(0, count - (list.count - lists[kind]!.count)) }
        }
    }
}

extension MessageModel {
    /// The web links in a message's text or caption, in order.
    public var links: [URL] {
        let text: RichText? = switch body {
        case .text(let text): text
        case .voiceNote(_, let caption), .media(_, _, let caption): caption
        default: caption
        }
        var seen = Set<URL>()
        return (text?.spans ?? []).compactMap { span in
            guard case .link(let url) = span.style, seen.insert(url).inserted else { return nil }
            return url
        }
    }
}

extension TDLibClient {
    /// `searchChatMessages`, by kind or by words, tolerant of messages TDLibKit can't decode.
    func resilientSearchChatMessages(
        chatId: Int64,
        query: String = "",
        filter: SearchMessagesFilter?,
        fromMessageId: Int64,
        limit: Int
    ) async throws -> FoundChatMessages {
        let query = SearchChatMessages(
            chatId: chatId,
            filter: filter,
            fromMessageId: fromMessageId,
            limit: limit,
            offset: 0,
            query: query,
            senderId: nil,
            topicId: nil
        )
        return try await resilientRun(query) { try ResilientDecoding.decode(FoundChatMessages.self, from: $0, decoder: $1) }
    }
}
