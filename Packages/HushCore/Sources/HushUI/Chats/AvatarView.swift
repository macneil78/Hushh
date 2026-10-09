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
        } else if let photoFileId, let image = ImageCache.image(at: files.handle(for: photoFileId).localURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else if let thumbnail, let image = NSImage(data: thumbnail) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: 2)
        } else {
            Circle()
                .fill(AccentPalette.color(for: accentColorId).gradient)
                .overlay {
                    Text(Self.initials(of: title))
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
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

/// Decoded images, so rows don't reread their avatar from disk every time they redraw.
@MainActor
enum ImageCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(at url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
