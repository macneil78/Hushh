import AppKit
import HushCore
import SwiftUI

/// A chat's round picture.
struct AvatarView: View {
    let item: ChatItem
    let files: FileStore
    var size: CGFloat = 40

    var body: some View {
        Avatar(
            title: item.displayTitle,
            accentColorId: item.accentColorId,
            photoFileId: item.photoFileId,
            thumbnail: item.photoThumbnail,
            isSavedMessages: item.kind == .savedMessages,
            files: files,
            size: size
        )
    }
}

/// A round picture: the photo, a blurry placeholder while it downloads, or initials.
struct Avatar: View {
    let title: String
    let accentColorId: Int
    let photoFileId: Int?
    var thumbnail: Data?
    var isSavedMessages = false
    let files: FileStore
    var size: CGFloat = 40

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .task(id: photoFileId) {
                if let photoFileId { files.download(photoFileId) }
            }
    }

    @ViewBuilder private var content: some View {
        if isSavedMessages {
            Circle()
                .fill(Color.blue.gradient)
                .overlay {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white)
                }
        } else {
            LocalImage(url: photoFileId.flatMap { files.handle(for: $0).localURL }, maxPixelSize: Int(size * 2)) {
                if let thumbnail, let image = NSImage(data: thumbnail) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 2)
                } else {
                    initials
                }
            }
        }
    }

    private var initials: some View {
        Circle()
            .fill(AccentPalette.color(for: accentColorId).gradient)
            .overlay {
                Text(Self.initials(of: title))
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private static func initials(of title: String) -> String {
        let words = title.split(whereSeparator: \.isWhitespace).prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// Telegram's seven built-in accent colors, in its order. Used for avatars and sender names.
enum AccentPalette {
    private static let colors: [Color] = [.red, .orange, .purple, .green, .teal, .blue, .pink]

    static func color(for accentColorId: Int) -> Color {
        colors[abs(accentColorId) % colors.count]
    }
}

/// Decoded images, sized for display, so scrolling never decodes a full-size photo on the main thread.
@MainActor
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    private static func key(_ url: URL, _ maxPixelSize: Int) -> NSString {
        "\(url.path)#\(maxPixelSize)" as NSString
    }

    static func cached(_ url: URL, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixelSize))
    }

    /// Decodes in the background, scaled down to `maxPixelSize` on the long side.
    static func load(_ url: URL, maxPixelSize: Int) async -> NSImage? {
        if let image = cached(url, maxPixelSize: maxPixelSize) { return image }
        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: .zero)
        cache.setObject(image, forKey: key(url, maxPixelSize))
        return image
    }
}

/// A local image file, decoded off the main thread at the size it's shown. Until it's ready
/// (or when there's no file), the placeholder shows.
struct LocalImage<Placeholder: View>: View {
    let url: URL?
    let maxPixelSize: Int
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: NSImage)?

    var body: some View {
        if let url, let image = loaded?.url == url ? loaded?.image : ImageCache.cached(url, maxPixelSize: maxPixelSize) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            placeholder()
                .task(id: url) {
                    guard let url, let image = await ImageCache.load(url, maxPixelSize: maxPixelSize) else { return }
                    loaded = (url, image)
                }
        }
    }
}
