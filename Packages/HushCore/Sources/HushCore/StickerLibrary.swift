@preconcurrency import TDLibKit
import Foundation
import Observation

/// Your stickers and saved GIFs, for the picker. TDLib keeps them in sync with your other devices.
@MainActor @Observable
public final class StickerLibrary {
    public struct StickerSet: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let title: String
        /// The sticker shown on the set's tab.
        public let cover: StickerMedia?
    }

    public private(set) var recent: [StickerMedia] = []
    public private(set) var favorites: [StickerMedia] = []
    public private(set) var sets: [StickerSet] = []
    public private(set) var gifs: [VideoMedia] = []
    /// Stickers of each set, loaded when you open its tab.
    public private(set) var setStickers: [Int64: [StickerMedia]] = [:]
    /// Your custom emoji packs (Premium), for custom reactions.
    public private(set) var emojiSets: [StickerSet] = []
    /// Custom emoji seen so far, by id: in reactions, or in packs.
    public private(set) var customEmoji: [Int64: StickerMedia] = [:]

    @ObservationIgnored private var client: TDLibClient?
    @ObservationIgnored private var requestedEmoji: Set<Int64> = []
    @ObservationIgnored private var pendingEmoji: Set<Int64> = []
    @ObservationIgnored private var isFetchScheduled = false

    func attach(_ client: TDLibClient) {
        self.client = client
    }

    func reset() {
        client = nil
        recent = []
        favorites = []
        sets = []
        gifs = []
        setStickers = [:]
        emojiSets = []
        customEmoji = [:]
        requestedEmoji = []
    }

    /// Reloads everything the picker shows. Cheap: TDLib answers from its local cache.
    public func refresh() async {
        guard let client else { return }
        if let stickers = try? await client.getRecentStickers(isAttached: false) {
            recent = stickers.stickers.map(MediaMapping.sticker)
        }
        if let stickers = try? await client.getFavoriteStickers() {
            favorites = stickers.stickers.map(MediaMapping.sticker)
        }
        if let installed = try? await client.getInstalledStickerSets(stickerType: .stickerTypeRegular) {
            sets = installed.sets.map {
                StickerSet(id: $0.id.rawValue, title: $0.title, cover: $0.covers.first.map(MediaMapping.sticker))
            }
        }
        if let animations = try? await client.getSavedAnimations() {
            gifs = animations.animations.map(MediaMapping.animation)
        }
    }

    public func loadSet(_ id: Int64) async {
        guard setStickers[id] == nil, let client else { return }
        if let set = try? await client.getStickerSet(setId: TdInt64(id)) {
            let stickers = set.stickers.map(MediaMapping.sticker)
            setStickers[id] = stickers
            for sticker in stickers {
                if let emojiId = sticker.customEmojiId, customEmoji[emojiId] == nil { customEmoji[emojiId] = sticker }
            }
        }
    }

    /// Your custom emoji packs, for the reaction picker.
    public func refreshEmojiSets() async {
        guard let client, let installed = try? await client.getInstalledStickerSets(stickerType: .stickerTypeCustomEmoji) else { return }
        emojiSets = installed.sets.map {
            StickerSet(id: $0.id.rawValue, title: $0.title, cover: $0.covers.first.map(MediaMapping.sticker))
        }
    }

    /// Fetches custom emoji not seen yet (a reaction on a message, say), a batch at a time.
    public func loadCustomEmoji(_ ids: [Int64]) {
        let missing = ids.filter { customEmoji[$0] == nil && !requestedEmoji.contains($0) }
        guard client != nil, !missing.isEmpty else { return }
        requestedEmoji.formUnion(missing)
        pendingEmoji.formUnion(missing)
        guard !isFetchScheduled else { return }
        // Gathered for a moment, so a screenful of badges is one request rather than dozens.
        isFetchScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            isFetchScheduled = false
            let ids = Array(pendingEmoji)
            pendingEmoji = []
            guard let client else { return }
            for batch in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
                guard let stickers = await Self.customEmojiStickers(batch, client: client) else {
                    requestedEmoji.subtract(batch)
                    continue
                }
                for sticker in stickers {
                    if let emojiId = sticker.customEmojiId { customEmoji[emojiId] = sticker }
                }
            }
        }
    }

    private nonisolated static func customEmojiStickers(_ ids: [Int64], client: TDLibClient) async -> [StickerMedia]? {
        guard let stickers = try? await client.getCustomEmojiStickers(customEmojiIds: ids.map { TdInt64($0) }) else { return nil }
        return stickers.stickers.map(MediaMapping.sticker)
    }
}
