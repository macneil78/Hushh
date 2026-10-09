import AVKit
import AppKit
import HushCore
import SwiftUI

/// Photos and videos, full window, over the chat. ← → step through the chat's media, Esc or a
/// click outside closes, pinch or double-click zooms a photo.
struct MediaViewer: View {
    let conversation: ConversationModel
    let message: MessageModel
    let files: FileStore
    @FocusState private var isFocused: Bool

    private var media: [MessageModel] { conversation.viewableMedia }
    private var index: Int? { media.firstIndex { $0.id == message.id } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
                .onTapGesture { conversation.closeViewer() }

            content
                .id(message.id)  // fresh zoom and player for each item
                .padding(.horizontal, 64)
                .padding(.vertical, 56)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let caption = message.caption, !caption.isEmpty {
                    RichTextView(text: caption, onAccent: true)
                        .foregroundStyle(.white)
                        .padding(12)
                        .frame(maxWidth: 640)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.bottom, 16)
                }
            }

            HStack {
                arrowButton(step: -1, systemImage: "chevron.left")
                Spacer()
                arrowButton(step: 1, systemImage: "chevron.right")
            }
            .padding(.horizontal, 12)
        }
        .foregroundStyle(.white)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.escape) {
            conversation.closeViewer()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            conversation.showAdjacentMedia(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            conversation.showAdjacentMedia(1)
            return .handled
        }
    }

    @ViewBuilder private var content: some View {
        switch message.body {
        case .photo(let photo, _):
            ZoomablePhoto(photo: photo, files: files)
        case .video(let video, _):
            ViewerVideo(video: video, files: files)
        default:
            EmptyView()
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(message.isOutgoing ? "You" : message.sender.name)
                    .font(.headline)
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .opacity(0.7)
            }
            Spacer()
            if let index, media.count > 1 {
                Text("\(index + 1) of \(media.count)")
                    .font(.callout.monospacedDigit())
                    .opacity(0.7)
            }
            if let url = localURL {
                if case .photo = message.body {
                    Button("Copy", systemImage: "doc.on.doc") { copyPhoto(at: url) }
                }
                Button("Save As…", systemImage: "square.and.arrow.down") {
                    FileActions.saveAs(url, suggestedName: url.lastPathComponent)
                }
            }
            Button("Close", systemImage: "xmark") { conversation.closeViewer() }
                .keyboardShortcut(.cancelAction)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.35))
    }

    private func arrowButton(step: Int, systemImage: String) -> some View {
        let target = index.map { $0 + step }
        let isAvailable = target.map(media.indices.contains) ?? false
        return Button(step < 0 ? "Previous" : "Next", systemImage: systemImage) {
            conversation.showAdjacentMedia(step)
        }
        .keyboardShortcut(step < 0 ? .leftArrow : .rightArrow, modifiers: [])
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title)
        .frame(width: 44, height: 44)
        .background(.black.opacity(0.35), in: Circle())
        .opacity(isAvailable ? 1 : 0)
        .disabled(!isAvailable)
    }

    /// The best file on disk: full resolution for photos (once downloaded), the video itself.
    private var localURL: URL? {
        switch message.body {
        case .photo(let photo, _):
            files.handle(for: photo.largest.fileId).localURL ?? files.handle(for: photo.image.fileId).localURL
        case .video(let video, _):
            files.handle(for: video.fileId).localURL
        default:
            nil
        }
    }

    private func copyPhoto(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

/// A photo at full resolution, fitted to the window. Pinch or double-click to zoom; drag to look
/// around while zoomed. Until the full size arrives, the conversation-size image stands in.
struct ZoomablePhoto: View {
    let photo: PhotoMedia
    let files: FileStore
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        LocalImage(url: files.handle(for: photo.largest.fileId).localURL, maxPixelSize: 4096, contentMode: .fit) {
            RemoteImage(source: photo.image, minithumbnail: photo.minithumbnail, files: files, contentMode: .fit)
        }
        .scaleEffect(zoom)
        .offset(offset)
        .gesture(
            MagnifyGesture()
                .onChanged { zoom = max(1, min(settledZoom * $0.magnification, 6)) }
                .onEnded { _ in
                    settledZoom = zoom
                    if zoom == 1 { resetOffset() }
                }
        )
        .simultaneousGesture(
            DragGesture()
                .onChanged { value in
                    guard zoom > 1 else { return }
                    offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                }
                .onEnded { _ in settledOffset = offset }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) {
                zoom = zoom > 1 ? 1 : 2.5
                settledZoom = zoom
                if zoom == 1 { resetOffset() }
            }
        }
        .task(id: photo.largest.fileId) { files.download(photo.largest.fileId, priority: 32) }
    }

    private func resetOffset() {
        offset = .zero
        settledOffset = .zero
    }
}

/// A video with playback controls, or a GIF looping silently. Downloads first if needed.
struct ViewerVideo: View {
    let video: VideoMedia
    let files: FileStore
    @State private var player: AVPlayer?

    var body: some View {
        let handle = files.handle(for: video.fileId)
        Group {
            if let url = handle.localURL {
                if video.isGIF {
                    LoopingVideoPlayer(url: url, isMuted: true)
                        .allowsHitTesting(false)
                        .aspectRatio(CGFloat(max(video.width, 1)) / CGFloat(max(video.height, 1)), contentMode: .fit)
                } else {
                    VideoPlayer(player: player)
                        .task(id: url) {
                            let player = AVPlayer(url: url)
                            self.player = player
                            player.play()
                        }
                        .onDisappear { player?.pause() }
                }
            } else {
                ZStack {
                    RemoteImage(source: video.thumbnail, minithumbnail: video.minithumbnail, files: files, contentMode: .fit)
                    ProgressView(value: handle.progress ?? 0)
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                .task(id: video.fileId) { files.download(video.fileId, priority: 32) }
            }
        }
    }
}
