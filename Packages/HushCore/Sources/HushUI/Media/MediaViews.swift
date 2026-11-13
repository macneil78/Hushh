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

/// How long a video or voice message is, as people read it.
enum MediaDuration {
    /// "0:42", or "2:00:00" from an hour on.
    static func text(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// "1 minute, 15 seconds", for VoiceOver.
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// Whether GIFs, circles and stickers may move on their own: not with Reduce Motion, or with
/// "Play animated images" turned off in Accessibility settings.
extension EnvironmentValues {
    var autoplaysMedia: Bool {
        accessibilityPlayAnimatedImages && !accessibilityReduceMotion
    }
}

/// An image from a TDLib file. While it downloads: a blurry miniature, or a neutral tile.
struct RemoteImage: View {
    let source: ImageSource?
    var minithumbnail: Data?
    let files: FileStore
    var contentMode: ContentMode = .fill
    var priority = 1
    /// Decoded no larger than this: twice the biggest size media appears at, for Retina.
    var maxPixelSize = 720

    var body: some View {
        LocalImage(
            url: source.flatMap { files.handle(for: $0.fileId).localURL },
            maxPixelSize: maxPixelSize,
            contentMode: contentMode
        ) {
            if let minithumbnail, let image = NSImage(data: minithumbnail) {
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
    /// Opens the viewer, which fetches the full resolution itself.
    let onOpen: () -> Void
    /// Set for album cells; otherwise the photo's own shape, fitted.
    var size: CGSize?
    var cornerRadius: CGFloat = 12

    var body: some View {
        let size = size ?? MediaSize.fit(width: photo.image.width, height: photo.image.height)
        RemoteImage(source: photo.image, minithumbnail: photo.minithumbnail, files: files, priority: 2)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
            // Drag into Finder or another app for a copy, full resolution when it's downloaded.
            .onDrag {
                .file(files.handle(for: photo.largest.fileId).localURL ?? files.handle(for: photo.image.fileId).localURL)
            }
    }
}

/// Videos show a poster with a play button and open in the viewer. GIFs play silently in a loop.
struct VideoView: View {
    let video: VideoMedia
    let files: FileStore
    /// Opens the viewer, which downloads the video if needed.
    let onOpen: () -> Void
    /// Set for album cells; otherwise the video's own shape, fitted.
    var size: CGSize?
    var cornerRadius: CGFloat = 12

    @Environment(\.autoplaysMedia) private var autoplays

    /// Small videos download on their own, as in Telegram; bigger ones wait for a click. A video
    /// of unknown size waits too.
    private static let autoDownloadLimit: Int64 = 15 * 1024 * 1024

    var body: some View {
        let size = size ?? MediaSize.fit(width: video.width, height: video.height)
        let handle = files.handle(for: video.fileId)
        ZStack {
            if video.isGIF, autoplays, let url = handle.localURL {
                LoopingVideoPlayer(url: url, isMuted: true)
                    .allowsHitTesting(false)
            } else {
                RemoteImage(source: video.thumbnail, minithumbnail: video.minithumbnail, files: files)
            }
            if video.isGIF, !autoplays {
                // Still, as Reduce Motion asks: click to watch it in the viewer.
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.45), in: Circle())
            } else if !video.isGIF {
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
            Text(badge(isDownloaded: handle.localURL != nil))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(6)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(video.isGIF ? "GIF" : "Video, \(MediaDuration.spoken(Double(video.duration)))")
        .accessibilityValue(handle.isDownloading ? "Downloading" : handle.localURL == nil && !video.isGIF ? "Not downloaded" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .onDrag { .file(files.handle(for: video.fileId).localURL) }
        .task(id: video.fileId) {
            if video.isGIF || (video.size > 0 && video.size <= Self.autoDownloadLimit) { files.download(video.fileId) }
        }
    }

    /// "GIF", the length, and the size of a video that waits for a click.
    private func badge(isDownloaded: Bool) -> String {
        if video.isGIF { return "GIF" }
        let length = MediaDuration.text(Double(video.duration))
        guard !isDownloaded, video.size > Self.autoDownloadLimit else { return length }
        return "\(length) · \(video.size.formatted(.byteCount(style: .file)))"
    }
}

/// A round video message. It loops silently (or stays still with Reduce Motion); click to hear it
/// from the start.
struct VideoNoteView: View {
    let note: VideoNoteMedia
    let files: FileStore
    @State private var isMuted = true
    @Environment(\.autoplaysMedia) private var autoplays

    var body: some View {
        let handle = files.handle(for: note.fileId)
        ZStack {
            if let url = handle.localURL, autoplays || !isMuted {
                LoopingVideoPlayer(url: url, isMuted: isMuted)
                    .allowsHitTesting(false)
            } else {
                RemoteImage(source: note.thumbnail, minithumbnail: note.minithumbnail, files: files)
                if handle.isDownloading {
                    ProgressView()
                        .controlSize(.small)
                } else if handle.localURL == nil {
                    // The download failed or was never started: a click fetches it.
                    Image(systemName: "arrow.down")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(Circle())
        // Bottom left: the transcribe button takes the bottom right.
        .overlay(alignment: .bottomLeading) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.45), in: Circle())
                .padding(8)
        }
        .contentShape(Circle())
        .onTapGesture { tap(handle) }
        .help(isMuted ? "Click to play with sound" : "Click to mute")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video message, \(MediaDuration.spoken(Double(note.duration)))")
        .accessibilityValue(handle.localURL == nil ? "Not downloaded" : isMuted ? "Muted" : "Playing with sound")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap(handle) }
        .task(id: note.fileId) { files.download(note.fileId, priority: 2) }
    }

    private func tap(_ handle: HushCore.FileHandle) {
        if handle.localURL == nil {
            files.download(note.fileId, priority: 32)
        } else {
            isMuted.toggle()
        }
    }
}

struct StickerView: View {
    let sticker: StickerMedia
    let files: FileStore
    var size: CGFloat = 160
    /// In chats, animated stickers play once when they appear (and again on click). The picker
    /// shows each one's still preview and plays only the one under the pointer, as Telegram's
    /// panel does: building an animation view for every sticker made opening it lag.
    var animates = true
    @State private var replays = 0
    @State private var isHovering = false
    @Environment(\.autoplaysMedia) private var autoplays

    /// With Reduce Motion, a sticker in a chat stays still until you click it.
    private var playsAnimation: Bool { (animates && (autoplays || replays > 0)) || isHovering }

    var body: some View {
        let view = content
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .task(id: playsAnimation) {
                // Still previews in the picker don't need the animation file until hovered.
                if sticker.format != .video, playsAnimation || sticker.format == .image {
                    files.download(sticker.fileId)
                }
            }
        if animates, sticker.format == .lottie {
            view.onTapGesture { replays += 1 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sticker \(sticker.emoji)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { replays += 1 }
        } else if animates {
            view.accessibilityElement(children: .ignore)
                .accessibilityLabel("Sticker \(sticker.emoji)")
        } else {
            // No tap gesture here, so a surrounding button or tap handler (the picker) gets the
            // click; hovering doesn't take clicks.
            view.onHover { isHovering = $0 }
        }
    }

    @ViewBuilder private var content: some View {
        let handle = files.handle(for: sticker.fileId)
        switch sticker.format {
        case .image:
            LocalImage(url: handle.localURL, maxPixelSize: Int(size * 2), contentMode: .fit) {
                placeholder
            }
        case .lottie:
            if playsAnimation, let url = handle.localURL {
                // Lottie draws with an AppKit view, which would swallow clicks meant for SwiftUI.
                LottieSticker(url: url, loops: !animates) { placeholder }
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
            RemoteImage(source: sticker.thumbnail, files: files, contentMode: .fit, maxPixelSize: Int(size * 2))
        } else {
            Text(sticker.emoji)
                .font(.system(size: size * 0.5))
        }
    }
}

/// An animated (.tgs) sticker, parsed off the main thread; its still preview shows meanwhile.
struct LottieSticker<Placeholder: View>: View {
    let url: URL
    var loops = false
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        LottieView { try await LottieCache.load(url) } placeholder: { placeholder() }
            .resizable()
            .playing(loopMode: loops ? .loop : .playOnce)
    }
}

/// Decoded animations, so scrolling back to a sticker doesn't unzip and parse it again.
enum LottieCache {
    nonisolated(unsafe) private static let cache = NSCache<NSString, LottieAnimation>()

    /// Nil for a file that isn't an animation Lottie can play.
    nonisolated static func load(_ url: URL) async throws -> LottieAnimation? {
        // The path alone isn't enough: TDLib reuses file names after a logout.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)#\(attributes[.size] ?? 0)#\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let json = Gzip.decompress(try Data(contentsOf: url)) else { return nil }
        let animation = try LottieAnimation.from(data: json)
        guard isPlayable(animation) else { return nil }
        cache.setObject(animation, forKey: key)
        return animation
    }

    /// Lottie stops the app with a trap on a frame rate of 0, and Telegram's own limits for
    /// stickers (512 px, a few seconds) are far inside these. A sticker Telegram didn't check, or
    /// a damaged file, shows its still preview instead.
    nonisolated static func isPlayable(_ animation: LottieAnimation) -> Bool {
        let rate = animation.framerate
        let start = Double(animation.startFrame)
        let end = Double(animation.endFrame)
        let size = animation.size
        return rate.isFinite && rate > 0 && rate <= 240
            && start.isFinite && end.isFinite && end > start && (end - start) / rate <= 600
            && size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0 && size.width <= 4096 && size.height <= 4096
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
                if document.size > 0 {  // Telegram doesn't always know
                    Text(document.size.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .opacity(0.7)
                }
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .contentShape(Rectangle())
        .onDrag { .file(files.handle(for: document.fileId).localURL) }
        .onTapGesture { tap(handle) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(handle))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap(handle) }
    }

    /// Opens the file, or downloads it; a click while it downloads stops the download.
    private func tap(_ handle: HushCore.FileHandle) {
        if let url = handle.localURL, FileManager.default.fileExists(atPath: url.path) {
            onOpen(url)
        } else if handle.isDownloading {
            files.cancelDownload(document.fileId)
        } else {
            files.download(document.fileId, priority: 32)
        }
    }

    private func accessibilityText(_ handle: HushCore.FileHandle) -> String {
        var parts = ["File \(document.fileName)"]
        if document.size > 0 { parts.append(document.size.formatted(.byteCount(style: .file))) }
        if handle.isDownloading {
            parts.append("downloading")
        } else if handle.localURL == nil {
            parts.append("not downloaded")
        }
        return parts.joined(separator: ", ")
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
        do {
            try copy(url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Copies a file, replacing what's at the destination (the save panel already asked) only
    /// once the copy has worked, so a failed copy never costs you the file you chose to replace.
    static func copy(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let copy = manager.temporaryDirectory.appending(path: "hush-save-\(UUID().uuidString)-\(destination.lastPathComponent)")
        try manager.copyItem(at: source, to: copy)
        defer { try? manager.removeItem(at: copy) }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: copy)
        } else {
            try manager.moveItem(at: copy, to: destination)
        }
    }
}
