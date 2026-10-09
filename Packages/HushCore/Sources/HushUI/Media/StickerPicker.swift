import HushCore
import SwiftUI

/// Your recent and favourite stickers, your sticker sets, and your saved GIFs.
struct StickerPicker: View {
    let library: StickerLibrary
    let files: FileStore
    let onSticker: (StickerMedia) -> Void
    let onGIF: (VideoMedia) -> Void

    enum Tab: Hashable {
        case recent
        case favorites
        case set(Int64)
        case gifs
    }

    @State private var tab: Tab = .recent

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider()
            ScrollView {
                content
                    .padding(10)
            }
        }
        .frame(width: 380, height: 420)
        .task { await library.refresh() }
        .task(id: tab) {
            if case .set(let id) = tab { await library.loadSet(id) }
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tabButton(.recent, help: "Recent") { Image(systemName: "clock") }
                if !library.favorites.isEmpty {
                    tabButton(.favorites, help: "Favourites") { Image(systemName: "star") }
                }
                tabButton(.gifs, help: "GIFs") { Text("GIF").font(.caption.weight(.bold)) }
                Divider().frame(height: 20)
                ForEach(library.sets) { set in
                    tabButton(.set(set.id), help: set.title) {
                        if let cover = set.cover {
                            StickerView(sticker: cover, files: files, size: 26, animates: false)
                                .allowsHitTesting(false)
                        } else {
                            Text(set.title.prefix(1))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func tabButton(_ tab: Tab, help: String, @ViewBuilder label: () -> some View) -> some View {
        Button { self.tab = tab } label: {
            label()
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .background(self.tab == tab ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .recent:
            stickerGrid(library.recent, empty: "Stickers you send appear here.")
        case .favorites:
            stickerGrid(library.favorites, empty: "No favourite stickers.")
        case .set(let id):
            if let stickers = library.setStickers[id] {
                stickerGrid(stickers, empty: "This set is empty.")
            } else {
                ProgressView().padding(40)
            }
        case .gifs:
            gifGrid
        }
    }

    @ViewBuilder private func stickerGrid(_ stickers: [StickerMedia], empty: String) -> some View {
        if stickers.isEmpty {
            Text(empty)
                .foregroundStyle(.secondary)
                .padding(40)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
                ForEach(stickers) { sticker in
                    StickerView(sticker: sticker, files: files, size: 72, animates: false)
                        .onTapGesture { onSticker(sticker) }
                        .help(sticker.emoji)
                }
            }
        }
    }

    @ViewBuilder private var gifGrid: some View {
        if library.gifs.isEmpty {
            Text("GIFs you save on Telegram appear here.")
                .foregroundStyle(.secondary)
                .padding(40)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(library.gifs, id: \.fileId) { gif in
                    Button { onGIF(gif) } label: {
                        RemoteImage(source: gif.thumbnail, minithumbnail: gif.minithumbnail, files: files)
                            .frame(height: 84)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
