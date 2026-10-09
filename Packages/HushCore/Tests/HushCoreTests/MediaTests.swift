import AppKit
import Foundation
import ImageIO
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

struct GzipTests {
    private let payload = Data(#"{"v":"5.5.2","fr":60,"layers":[]}"#.utf8)

    @Test func unpacksPlainGzip() {
        let packed = Data(base64Encoded: "H4sIAAAAAAACE6tWKlOyUjLVM9UzUtJRSitSsjIz0FHKSaxMLSpWsoqOrQUAUdLQDyEAAAA=")!
        #expect(Gzip.decompress(packed) == payload)
    }

    @Test func skipsTheOptionalFileNameHeader() {
        let packed = Data(base64Encoded: "H4sICAAAAAAC/3N0aWNrZXIuanNvbgCrVipTslIy1TPVM1LSUUorUrIyM9BRykmsTC0qVrKKjq0FAFHS0A8hAAAA")!
        #expect(Gzip.decompress(packed) == payload)
    }

    @Test func rejectsNonGzipData() {
        #expect(Gzip.decompress(Data("not gzip at all, just text".utf8)) == nil)
    }
}

struct MediaMappingTests {
    private func file(_ id: Int) -> File {
        File(
            expectedSize: 0, id: id,
            local: LocalFile(
                canBeDeleted: false, canBeDownloaded: true, downloadOffset: 0, downloadedPrefixSize: 0,
                downloadedSize: 0, isDownloadingActive: false, isDownloadingCompleted: false, path: ""
            ),
            remote: RemoteFile(id: "", isUploadingActive: false, isUploadingCompleted: true, uniqueId: "", uploadedSize: 0),
            size: 0
        )
    }

    private func photo(_ sizes: [(id: Int, width: Int, height: Int)]) -> Photo {
        Photo(hasStickers: false, minithumbnail: nil, sizes: sizes.map {
            PhotoSize(height: $0.height, photo: file($0.id), progressiveSizes: [], type: "x", width: $0.width)
        })
    }

    @Test func picksTheSmallestSharpSize() {
        let chosen = MediaMapping.photo(photo([(1, 90, 60), (2, 320, 213), (3, 800, 533), (4, 1280, 853)]))
        #expect(chosen?.image.fileId == 3)
    }

    @Test func fallsBackToTheLargestSize() {
        let chosen = MediaMapping.photo(photo([(1, 90, 60), (2, 320, 213)]))
        #expect(chosen?.image.fileId == 2)
    }

    @Test func selfDestructingPhotosAreNotShown() {
        let content = MessageContent.messagePhoto(MessagePhoto(
            caption: FormattedText(entities: [], text: ""), hasSpoiler: false, isSecret: true,
            photo: photo([(1, 800, 600)]), showCaptionAboveMedia: false, video: nil
        ))
        let body = MessageMapper.body(for: content, isOutgoing: false, senderId: 1, senderName: "Alex", name: { _ in "" })
        #expect(body == MessageMapper.selfDestructingPlaceholder)
    }
}

struct AttachmentTests {
    @Test func classifiesByFileType() {
        #expect(Attachment(url: URL(filePath: "/tmp/a.jpg")).kind == .photo)
        #expect(Attachment(url: URL(filePath: "/tmp/a.HEIC")).kind == .photo)
        #expect(Attachment(url: URL(filePath: "/tmp/a.mov")).kind == .video)
        #expect(Attachment(url: URL(filePath: "/tmp/a.gif")).kind == .file)
        #expect(Attachment(url: URL(filePath: "/tmp/report.pdf")).kind == .file)
        #expect(Attachment(url: URL(filePath: "/tmp/noextension")).kind == .file)
        // Dropped on "Send as Files": original quality.
        #expect(Attachment(url: URL(filePath: "/tmp/a.jpg"), asFile: true).kind == .file)
    }

    @Test func photosBecomeJPEGsFlattenedOntoWhite() throws {
        // A 4000×1000 PNG that's fully transparent.
        let width = 4000, height = 1000
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let input = FileManager.default.temporaryDirectory.appending(path: "hush-test-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        defer { try? FileManager.default.removeItem(at: input) }

        let prepared = try #require(AttachmentPreparer.preparePhoto(input))
        defer { try? FileManager.default.removeItem(atPath: prepared.path) }
        #expect(prepared.path.hasSuffix(".jpg"))
        #expect(prepared.width == 2560)
        #expect(prepared.height == 640)

        let output = try #require(NSBitmapImageRep(data: Data(contentsOf: URL(filePath: prepared.path))))
        let pixel = try #require(output.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        #expect(pixel.redComponent > 0.95 && pixel.greenComponent > 0.95 && pixel.blueComponent > 0.95)
    }
}

struct MediaSizeTests {
    @Test func fitsIntoTheBoxKeepingShape() {
        #expect(MediaSize.fit(width: 1600, height: 800) == CGSize(width: 340, height: 170))
        #expect(MediaSize.fit(width: 600, height: 1200) == CGSize(width: 170, height: 340))
        // Very wide panoramas keep a usable height.
        #expect(MediaSize.fit(width: 5000, height: 500).height == 90)
    }
}

@MainActor
struct ImageCacheTests {
    @Test func imagesDecodeAtDisplaySizeAndAreReused() async throws {
        let context = CGContext(
            data: nil, width: 4000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let url = FileManager.default.temporaryDirectory.appending(path: "hush-test-\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try #require(await ImageCache.load(url, maxPixelSize: 720))
        #expect(image.size == CGSize(width: 720, height: 180))
        #expect(ImageCache.cached(url, maxPixelSize: 720) === image)
    }
}
