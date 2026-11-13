import AppKit
import HushCore
import Lottie
import SwiftUI

/// One reaction as Telegram draws it: an emoji, or a custom emoji from someone's emoji pack.
struct ReactionGlyph: View {
    let kind: Reaction.Kind
    var size: CGFloat = 16
    let files: FileStore
    @Environment(\.stickerLibrary) private var library

    var body: some View {
        switch kind {
        case .emoji(let emoji):
            Text(Emoji.colorful(emoji))
                .font(.system(size: size))
        case .customEmoji(let id):
            Group {
                if let sticker = library?.customEmoji[id] {
                    CustomEmojiView(sticker: sticker, files: files, size: size * 1.2)
                } else {
                    Color.clear
                }
            }
            .frame(width: size * 1.2, height: size * 1.2)
            .task(id: id) { library?.loadCustomEmoji([id]) }
        case .paid:
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.85))
                .foregroundStyle(.yellow)
        }
    }
}

/// A custom emoji, still until the pointer is over it, then animated, as Telegram's panels do.
/// Animating every one on screen at once would make a picker full of them lag.
struct CustomEmojiView: View {
    let sticker: StickerMedia
    let files: FileStore
    let size: CGFloat
    @State private var isHovering = false
    @State private var still: NSImage?

    var body: some View {
        let handle = files.handle(for: sticker.fileId)
        content(url: handle.localURL)
            .frame(width: size, height: size)
            .onHover { isHovering = $0 }
            .task(id: sticker.fileId) {
                // Video emoji (WEBM) can't play on macOS: their still preview stands in.
                if sticker.format != .video { files.download(sticker.fileId, priority: 8) }
            }
            .task(id: handle.localURL) {
                guard sticker.format == .lottie, let url = handle.localURL else { return }
                still = await LottieStill.image(of: url, size: size)
            }
    }

    @ViewBuilder private func content(url: URL?) -> some View {
        switch sticker.format {
        case .image:
            LocalImage(url: url, maxPixelSize: Int(size * 2), contentMode: .fit) { fallback }
        case .lottie:
            if isHovering, let url {
                LottieSticker(url: url, loops: true) { stillOrFallback }
                    .allowsHitTesting(false)
            } else {
                stillOrFallback
            }
        case .video:
            fallback
        }
    }

    @ViewBuilder private var stillOrFallback: some View {
        if let still {
            Image(nsImage: still)
                .resizable()
                .scaledToFit()
        } else {
            fallback
        }
    }

    @ViewBuilder private var fallback: some View {
        if sticker.thumbnail != nil {
            RemoteImage(source: sticker.thumbnail, files: files, contentMode: .fit, maxPixelSize: Int(size * 2))
        } else {
            // The plain emoji the custom one stands for.
            Text(sticker.emoji)
                .font(.system(size: size * 0.8))
        }
    }
}

/// The first frame of an animated (.tgs) emoji as a picture, drawn once and kept.
@MainActor
enum LottieStill {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(of url: URL, size: CGFloat) async -> NSImage? {
        let key = "\(url.path)@\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let animation = try? await LottieCache.load(url), let image = render(animation, size: size) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func render(_ animation: LottieAnimation, size: CGFloat, scale: CGFloat = 2) -> NSImage? {
        // The main-thread engine draws into a context; Core Animation's only runs on screen.
        // Drawn at the animation's own size (512 points for Telegram's), then scaled down.
        let natural = animation.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let layer = LottieAnimationLayer(animation: animation, configuration: LottieConfiguration(renderingEngine: .mainThread))
        layer.frame = CGRect(origin: .zero, size: natural)
        layer.currentProgress = 0
        // LottieAnimationView centers the drawing inside; off screen, it's left centered on the
        // corner, so this does it.
        layer.sublayers?.forEach { $0.position = CGPoint(x: natural.width / 2, y: natural.height / 2) }
        layer.forceDisplayUpdate()
        let pixels = Int(size * scale)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let fit = CGFloat(pixels) / max(natural.width, natural.height)
        // Layers draw top-down; the context counts from the bottom.
        context.translateBy(x: (CGFloat(pixels) - natural.width * fit) / 2, y: CGFloat(pixels) - (CGFloat(pixels) - natural.height * fit) / 2)
        context.scaleBy(x: fit, y: -fit)
        layer.render(in: context)
        return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
    }
}

/// Picking a reaction, as in Telegram: a row of the ones you use most, and, expanded, your
/// recent and popular reactions, then your custom emoji packs if you have Premium. Telegram
/// works out the order for each message.
struct ReactionPicker: View {
    let message: MessageModel
    let conversation: ConversationModel
    let files: FileStore
    let onPick: (Reaction.Kind) -> Void
    @Environment(\.stickerLibrary) private var library
    @State private var options: ConversationModel.ReactionOptions?
    @State private var isExpanded = false

    private static let columns = 8
    private static let cell: CGFloat = 34

    private var chosen: Set<Reaction.Kind> {
        Set(message.reactions.filter(\.isChosen).map(\.kind))
    }

    var body: some View {
        Group {
            if let options {
                if options.top.isEmpty && options.more.isEmpty && !options.allowsCustomEmoji {
                    Text(options.unavailableReason ?? "Reactions are off in this chat.")
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else if isExpanded {
                    expanded(options)
                } else {
                    quickRow(options)
                }
            } else {
                // TDLib answers from its cache, in a moment.
                ProgressView()
                    .controlSize(.small)
                    .frame(width: CGFloat(Self.columns) * (Self.cell + 2) + 12, height: Self.cell + 12)
            }
        }
        .task {
            let options = await conversation.reactionOptions(for: message)
            self.options = options
            if options.allowsCustomEmoji { await library?.refreshEmojiSets() }
        }
    }

    private func quickRow(_ options: ConversationModel.ReactionOptions) -> some View {
        let canExpand = !options.more.isEmpty || options.allowsCustomEmoji || options.top.count > Self.columns
        return HStack(spacing: 2) {
            ForEach(options.top.prefix(Self.columns), id: \.self) { cell($0) }
            if canExpand {
                Button("More Reactions", systemImage: "chevron.down") { isExpanded = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: 26, height: Self.cell)
                    .help("More reactions")
            }
        }
        .padding(6)
    }

    private func expanded(_ options: ConversationModel.ReactionOptions) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                grid(options.top + options.more)
                if options.allowsCustomEmoji, let library {
                    ForEach(library.emojiSets) { set in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(set.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                            let emoji = (library.setStickers[set.id] ?? []).compactMap(\.customEmojiId).map(Reaction.Kind.customEmoji)
                            if emoji.isEmpty {
                                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: Self.cell)
                            } else {
                                grid(emoji)
                            }
                        }
                        .task { await library.loadSet(set.id) }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: CGFloat(Self.columns) * (Self.cell + 4) + 16, height: 300)
    }

    private func grid(_ kinds: [Reaction.Kind]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: 4), count: Self.columns), spacing: 4) {
            ForEach(kinds, id: \.self) { cell($0) }
        }
    }

    private func cell(_ kind: Reaction.Kind) -> some View {
        Button { onPick(kind) } label: {
            ReactionGlyph(kind: kind, size: 22, files: files)
                .frame(width: Self.cell, height: Self.cell)
                .background(chosen.contains(kind) ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
