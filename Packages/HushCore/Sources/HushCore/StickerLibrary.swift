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

    @ObservationIgnored private var client: TDLibClient?

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
            setStickers[id] = set.stickers.map(MediaMapping.sticker)
        }
    }
}
