@preconcurrency import TDLibKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file waiting in the composer to be sent.
public struct Attachment: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case photo
        case video
        case file
    }

    public let id: UUID
    public let url: URL
    public let kind: Kind

    public var name: String { url.lastPathComponent }

    /// `asFile` sends a picture or video as a file, in original quality, instead of compressed.
    public init(url: URL, asFile: Bool = false) {
        id = UUID()
        self.url = url
        kind = asFile ? .file : Self.kind(of: url)
    }

    static func kind(of url: URL) -> Kind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        // Telegram turns GIF files into its own looping GIFs; sent as photos they'd freeze.
        if type.conforms(to: .gif) { return .file }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) { return .video }
        return .file
    }
}

/// Turns attachments into TDLib message content. Runs off the main actor: re-encoding photos
/// and measuring videos takes a moment.
enum AttachmentPreparer {
    /// Telegram compresses photos to at most 2560 pixels anyway; doing it here keeps uploads small.
    static let maxPhotoDimension = 2560

    static func content(for item: Attachment, caption: FormattedText?) async -> InputMessageContent {
        switch item.kind {
        case .photo:
            if let photo = preparePhoto(item.url) {
                return .inputMessagePhoto(InputMessagePhoto(
                    caption: caption,
                    hasSpoiler: false,
                    photo: InputPhoto(
                        addedStickerFileIds: [], height: photo.height,
                        photo: .inputFileLocal(InputFileLocal(path: photo.path)),
                        thumbnail: nil, video: nil, width: photo.width
                    ),
                    selfDestructType: nil,
                    showCaptionAboveMedia: false
                ))
            }
        case .video:
            if let video = await videoInfo(item.url) {
                return .inputMessageVideo(InputMessageVideo(
                    caption: caption,
                    hasSpoiler: false,
                    selfDestructType: nil,
                    showCaptionAboveMedia: false,
                    video: InputVideo(
                        addedStickerFileIds: [], cover: nil, duration: video.duration, height: video.height,
                        startTimestamp: 0, supportsStreaming: true, thumbnail: nil,
                        video: .inputFileLocal(InputFileLocal(path: item.url.path)), width: video.width
                    )
                ))
            }
        case .file:
            break
        }
        // Anything Hush can't read as a photo or video still goes through, as a file.
        return document(item, caption: caption)
    }

    static func document(_ item: Attachment, caption: FormattedText?) -> InputMessageContent {
        .inputMessageDocument(InputMessageDocument(
            caption: caption,
            document: InputDocument(
                disableContentTypeDetection: false,
                document: .inputFileLocal(InputFileLocal(path: item.url.path)),
                thumbnail: nil
            )
        ))
    }

    /// Re-encodes a picture as a JPEG of at most `maxPhotoDimension` pixels, upright, with any
    /// transparency flattened onto white. Returns the temporary file and its size.
    static func preparePhoto(_ url: URL) -> (path: String, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPhotoDimension,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)

        let output = FileManager.default.temporaryDirectory.appending(path: "hush-photo-\(UUID().uuidString).jpg")
        guard
            let flattened = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output.path, image.width, image.height)
    }

    /// Duration in seconds and on-screen size (rotation applied).
    static func videoInfo(_ url: URL) async -> (duration: Int, width: Int, height: Int)? {
        let asset = AVURLAsset(url: url)
        guard
            let duration = try? await asset.load(.duration),
            let track = try? await asset.loadTracks(withMediaType: .video).first,
            let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let frame = CGRect(origin: .zero, size: size).applying(transform)
        return (Int(duration.seconds.rounded()), Int(abs(frame.width)), Int(abs(frame.height)))
    }
}
