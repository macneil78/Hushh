@preconcurrency import TDLibKit
import Foundation

/// A picture TDLib can download.
public struct ImageSource: Equatable, Sendable {
    public let fileId: Int
    public let width: Int
    public let height: Int
}

public struct PhotoMedia: Equatable, Sendable {
    /// The size worth showing in a conversation.
    public let image: ImageSource
    /// A tiny, blurry JPEG to show until the image downloads.
    public let minithumbnail: Data?
}

/// A video, or a GIF (which Telegram stores as a silent MP4).
public struct VideoMedia: Equatable, Sendable {
    public let fileId: Int
    public let width: Int
    public let height: Int
    /// Seconds.
    public let duration: Int
    public let thumbnail: ImageSource?
    public let minithumbnail: Data?
    /// GIFs play silently in a loop, right in the conversation.
    public let isGIF: Bool
    public let size: Int64
}

/// A round video message.
public struct VideoNoteMedia: Equatable, Sendable {
    public let fileId: Int
    public let duration: Int
    public let thumbnail: ImageSource?
    public let minithumbnail: Data?
}

public struct VoiceNoteMedia: Equatable, Sendable {
    public let fileId: Int
    /// Seconds.
    public let duration: Int
    /// One level from 0 to 31 per bar.
    public let waveform: [UInt8]
    /// Whether the voice message has been played (yours: by the other side).
    public var isListened: Bool
}

public struct StickerMedia: Equatable, Sendable, Identifiable {
    public enum Format: Equatable, Sendable {
        /// WEBP, which ImageIO decodes.
        case image
        /// Telegram's .tgs: a gzipped Lottie animation.
        case lottie
        /// WEBM video, which macOS can't play; Hush shows the thumbnail instead.
        case video
    }

    public var id: Int { fileId }
    public let fileId: Int
    public let width: Int
    public let height: Int
    public let emoji: String
    public let format: Format
    public let thumbnail: ImageSource?
}

public struct DocumentMedia: Equatable, Sendable {
    public let fileId: Int
    public let fileName: String
    public let size: Int64
    public let thumbnail: ImageSource?
}

enum MediaMapping {
    /// The smallest photo size that still looks sharp in a bubble on a Retina screen (about
    /// 800 pixels on the long side), or the largest available.
    static func photo(_ photo: Photo) -> PhotoMedia? {
        let sizes = photo.sizes.sorted { $0.width * $0.height < $1.width * $1.height }
        guard let size = sizes.first(where: { max($0.width, $0.height) >= 800 }) ?? sizes.last else { return nil }
        return PhotoMedia(
            image: ImageSource(fileId: size.photo.id, width: size.width, height: size.height),
            minithumbnail: photo.minithumbnail?.data
        )
    }

    static func video(_ video: Video) -> VideoMedia {
        VideoMedia(
            fileId: video.video.id,
            width: video.width,
            height: video.height,
            duration: video.duration,
            thumbnail: image(video.thumbnail),
            minithumbnail: video.minithumbnail?.data,
            isGIF: false,
            size: max(video.video.size, video.video.expectedSize)
        )
    }

    static func animation(_ animation: Animation) -> VideoMedia {
        VideoMedia(
            fileId: animation.animation.id,
            width: animation.width,
            height: animation.height,
            duration: animation.duration,
            thumbnail: image(animation.thumbnail),
            minithumbnail: animation.minithumbnail?.data,
            isGIF: true,
            size: max(animation.animation.size, animation.animation.expectedSize)
        )
    }

    static func videoNote(_ note: VideoNote) -> VideoNoteMedia {
        VideoNoteMedia(
            fileId: note.video.id,
            duration: note.duration,
            thumbnail: image(note.thumbnail),
            minithumbnail: note.minithumbnail?.data
        )
    }

    static func voiceNote(_ note: VoiceNote, isListened: Bool) -> VoiceNoteMedia {
        VoiceNoteMedia(
            fileId: note.voice.id,
            duration: note.duration,
            waveform: Array(Waveform.unpack(note.waveform).prefix(Waveform.barCount)),
            isListened: isListened
        )
    }

    static func sticker(_ sticker: Sticker) -> StickerMedia {
        let format: StickerMedia.Format = switch sticker.format {
        case .stickerFormatWebp: .image
        case .stickerFormatTgs: .lottie
        case .stickerFormatWebm: .video
        }
        return StickerMedia(
            fileId: sticker.sticker.id,
            width: sticker.width,
            height: sticker.height,
            emoji: sticker.emoji,
            format: format,
            thumbnail: image(sticker.thumbnail)
        )
    }

    static func document(_ document: Document) -> DocumentMedia {
        DocumentMedia(
            fileId: document.document.id,
            fileName: document.fileName.isEmpty ? "File" : document.fileName,
            size: max(document.document.size, document.document.expectedSize),
            thumbnail: image(document.thumbnail)
        )
    }

    static func audio(_ audio: Audio) -> DocumentMedia {
        let title = [audio.performer, audio.title].filter { !$0.isEmpty }.joined(separator: " – ")
        return DocumentMedia(
            fileId: audio.audio.id,
            fileName: title.isEmpty ? (audio.fileName.isEmpty ? "Audio" : audio.fileName) : title,
            size: max(audio.audio.size, audio.audio.expectedSize),
            thumbnail: image(audio.albumCoverThumbnail)
        )
    }

    /// Only thumbnails in formats ImageIO can draw.
    private static func image(_ thumbnail: Thumbnail?) -> ImageSource? {
        guard let thumbnail else { return nil }
        switch thumbnail.format {
        case .thumbnailFormatJpeg, .thumbnailFormatPng, .thumbnailFormatWebp, .thumbnailFormatGif:
            return ImageSource(fileId: thumbnail.file.id, width: thumbnail.width, height: thumbnail.height)
        case .thumbnailFormatTgs, .thumbnailFormatWebm, .thumbnailFormatMpeg4:
            return nil
        }
    }
}

/// Unpacks gzip data, the wrapper around Telegram's .tgs animated stickers.
public enum Gzip {
    public static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        // Header: magic 1f 8b, method 8 (deflate), flags, then 6 bytes we don't need.
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        if flags & 0x08 != 0 {  // FNAME, zero-terminated
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT, zero-terminated
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        // The body is raw DEFLATE, followed by an 8-byte CRC and length trailer.
        guard offset < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[offset ..< bytes.count - 8])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}
