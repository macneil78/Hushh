import AVFoundation
import AppKit
import HushCore
import Lottie
import SwiftUI
import UniformTypeIdentifiers

/// How big media appears in a conversation: fitted into a box, keeping its shape.
enum MediaSize {
    static let box = CGSize(width: 340, height: 340)

    static func fit(width: Int, height: Int, in box: CGSize = box, minimum: CGFloat = 90) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: box.width * 0.7, height: box.width * 0.7) }
        let aspect = CGFloat(width) / CGFloat(height)
        if aspect >= box.width / box.height {
            return CGSize(width: box.width, height: max(box.width / aspect, minimum))
        }
        return CGSize(width: max(box.height * aspect, minimum), height: box.height)
    }
}

/// An image from a TDLib file. While it downloads: a blurry miniature, or a neutral tile.
struct RemoteImage: View {
    let source: ImageSource?
    var minithumbnail: Data?
    let files: FileStore
    var contentMode: ContentMode = .fill
    var priority = 1

    var body: some View {
        Group {
            if let source, let image = ImageCache.image(at: files.handle(for: source.fileId).localURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let minithumbnail, let image = NSImage(data: minithumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .blur(radius: 6)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: source?.fileId) {
            if let source { files.download(source.fileId, priority: priority) }
        }
    }
}

struct PhotoView: View {
    let photo: PhotoMedia
    let files: FileStore
    let onOpen: (URL) -> Void
    /// Set for album cells; otherwise the photo's own shape, fitted.
    var size: CGSize?
    var cornerRadius: CGFloat = 12

    var body: some View {
        let size = size ?? MediaSize.fit(width: photo.image.width, height: photo.image.height)
        RemoteImage(source: photo.image, minithumbnail: photo.minithumbnail, files: files, priority: 2)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                if let url = files.handle(for: photo.image.fileId).localURL { onOpen(url) }
            }
    }
}

/// Videos show a poster with a play button and open in Quick Look. GIFs play silently in a loop.
struct VideoView: View {
    let video: VideoMedia
    let files: FileStore
    let onOpen: (URL) -> Void
    /// Set for album cells; otherwise the video's own shape, fitted.
    var size: CGSize?
    var cornerRadius: CGFloat = 12

    /// Small videos download on their own, as in Telegram; bigger ones wait for a click.
    private static let autoDownloadLimit: Int64 = 15 * 1024 * 1024

    var body: some View {
        let size = size ?? MediaSize.fit(width: video.width, height: video.height)
        let handle = files.handle(for: video.fileId)
        ZStack {
            if video.isGIF, let url = handle.localURL {
                LoopingVideoPlayer(url: url, isMuted: true)
                    .allowsHitTesting(false)
            } else {
                RemoteImage(source: video.thumbnail, minithumbnail: video.minithumbnail, files: files)
            }
            if !video.isGIF {
                if handle.isDownloading {
                    ProgressView(value: handle.progress ?? 0)
                        .progressViewStyle(.circular)
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                } else {
                    Image(systemName: handle.localURL == nil ? "arrow.down" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text(video.isGIF ? "GIF" : Duration.seconds(video.duration).formatted(.time(pattern: .minuteSecond)))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(6)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = handle.localURL {
                onOpen(url)
            } else {
                files.download(video.fileId, priority: 32)
            }
        }
        .task(id: video.fileId) {
            if video.isGIF || video.size <= Self.autoDownloadLimit { files.download(video.fileId) }
        }
    }
}

/// A round video message. It loops silently; click to hear it from the start.
struct VideoNoteView: View {
    let note: VideoNoteMedia
    let files: FileStore
    @State private var isMuted = true

    var body: some View {
        let handle = files.handle(for: note.fileId)
        ZStack {
            if let url = handle.localURL {
                LoopingVideoPlayer(url: url, isMuted: isMuted)
                    .allowsHitTesting(false)
            } else {
                RemoteImage(source: note.thumbnail, minithumbnail: note.minithumbnail, files: files)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.45), in: Circle())
                .padding(8)
        }
        .contentShape(Circle())
        .onTapGesture { isMuted.toggle() }
        .help(isMuted ? "Click to play with sound" : "Click to mute")
        .task(id: note.fileId) { files.download(note.fileId, priority: 2) }
    }
}

struct StickerView: View {
    let sticker: StickerMedia
    let files: FileStore
    var size: CGFloat = 160
    /// Animated stickers play once when they appear (and again on click). The picker shows
    /// them still, so dozens don't animate at once.
    var animates = true
    @State private var replays = 0

    var body: some View {
        let view = content
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .task(id: sticker.fileId) {
                if sticker.format != .video { files.download(sticker.fileId) }
            }
        if animates, sticker.format == .lottie {
            view.onTapGesture { replays += 1 }
        } else {
            // No gesture here, so a surrounding button or tap handler (the picker) gets the click.
            view
        }
    }

    @ViewBuilder private var content: some View {
        let handle = files.handle(for: sticker.fileId)
        switch sticker.format {
        case .image:
            if let image = ImageCache.image(at: handle.localURL) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        case .lottie:
            if let url = handle.localURL {
                // Lottie draws with an AppKit view, which would swallow clicks meant for SwiftUI.
                LottieSticker(url: url, animates: animates)
                    .id(replays)
                    .allowsHitTesting(false)
            } else {
                placeholder
            }
        case .video:
            // macOS can't play WEBM, so video stickers stay still.
            placeholder
        }
    }

    @ViewBuilder private var placeholder: some View {
        if sticker.thumbnail != nil {
            RemoteImage(source: sticker.thumbnail, files: files, contentMode: .fit)
        } else {
            Text(sticker.emoji)
                .font(.system(size: size * 0.5))
        }
    }
}

struct LottieSticker: View {
    let url: URL
    let animates: Bool

    var body: some View {
        let view = LottieView { try await Self.load(url) }
            .resizable()
        if animates {
            view.playing(loopMode: .playOnce)
        } else {
            view.paused(at: .progress(0))
        }
    }

    /// Decoded animations, so scrolling back to a sticker doesn't unzip and parse it again.
    nonisolated(unsafe) private static let cache = NSCache<NSURL, LottieAnimation>()

    nonisolated static func load(_ url: URL) async throws -> LottieAnimation? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let json = Gzip.decompress(try Data(contentsOf: url)) else { return nil }
        let animation = try LottieAnimation.from(data: json)
        cache.setObject(animation, forKey: url as NSURL)
        return animation
    }
}

/// A file or song: its icon, name and size. Click to download, then click to open in Quick Look.
struct DocumentView: View {
    let document: DocumentMedia
    let files: FileStore
    let onOpen: (URL) -> Void

    var body: some View {
        let handle = files.handle(for: document.fileId)
        HStack(spacing: 10) {
            ZStack {
                if handle.isDownloading {
                    ProgressView(value: handle.progress ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else if handle.localURL == nil {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 30))
                } else {
                    Image(nsImage: Self.icon(for: document.fileName))
                        .resizable()
                        .frame(width: 36, height: 36)
                }
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text(document.size.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .opacity(0.7)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = handle.localURL {
                onOpen(url)
            } else {
                files.download(document.fileId, priority: 32)
            }
        }
    }

    private static func icon(for fileName: String) -> NSImage {
        let type = UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// A silent or sounding video that loops, for GIFs and round video messages.
struct LoopingVideoPlayer: NSViewRepresentable {
    let url: URL
    var isMuted = true

    func makeNSView(context: Context) -> LoopingPlayerView {
        LoopingPlayerView()
    }

    func updateNSView(_ view: LoopingPlayerView, context: Context) {
        view.play(url, isMuted: isMuted)
    }

    static func dismantleNSView(_ view: LoopingPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class LoopingPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var url: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func play(_ url: URL, isMuted: Bool) {
        guard url != self.url else {
            if player?.isMuted == true, !isMuted { player?.seek(to: .zero) }  // unmuting plays from the start
            player?.isMuted = isMuted
            return
        }
        self.url = url
        let player = AVQueuePlayer()
        player.isMuted = isMuted
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        playerLayer.player = player
        self.player = player
        player.play()
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        playerLayer.player = nil
        url = nil
    }
}

enum FileActions {
    /// Lets you save a downloaded file anywhere, starting in Downloads.
    @MainActor
    static func saveAs(_ url: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)  // the panel already asked about replacing
        try? FileManager.default.copyItem(at: url, to: destination)
    }
}
