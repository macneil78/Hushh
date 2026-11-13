import Foundation
import Lottie
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

/// Animated stickers (.tgs: gzipped Lottie JSON) that would take too much memory or crash Lottie.
@MainActor
struct StickerFileTests {
    /// A gzip file around `payload`: header, raw DEFLATE, and a trailer Hushh doesn't check.
    private func gzip(_ payload: Data) throws -> Data {
        var data = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        data.append(try (payload as NSData).compressed(using: .zlib) as Data)
        data.append(Data(count: 8))
        return data
    }

    /// A .tgs can unpack to 1,000 times its size; Telegram's 64 KB limit still allows 64 MB.
    @Test func gzipStopsAtTheSizeLimit() throws {
        #expect(Gzip.decompress(try gzip(Data(count: 64 << 20))) == nil)
        let sticker = Data((0 ..< 600_000).map { UInt8(truncatingIfNeeded: $0 * 7 % 251) })
        #expect(Gzip.decompress(try gzip(sticker)) == sticker)
    }

    /// Lottie stops the process with a trap on a frame rate of 0, so the loader refuses such a
    /// file, and others it can't play; the sticker shows its still preview.
    @Test func lottieRefusesAnimationsItCannotPlay() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func sticker(_ name: String, rate: Int, start: Int = 0, end: Int = 60, size: Int = 512) throws -> URL {
            let json = #"{"v":"5.5.2","fr":\#(rate),"ip":\#(start),"op":\#(end),"w":\#(size),"h":\#(size),"layers":[]}"#
            let url = folder.appending(path: name)
            try gzip(Data(json.utf8)).write(to: url)
            return url
        }
        #expect(try await LottieCache.load(sticker("ok.tgs", rate: 60)) != nil)
        #expect(try await LottieCache.load(sticker("fr0.tgs", rate: 0)) == nil)
        #expect(try await LottieCache.load(sticker("backwards.tgs", rate: 60, start: 10, end: -5)) == nil)
        #expect(try await LottieCache.load(sticker("empty.tgs", rate: 60, size: 0)) == nil)
    }
}

/// Media files that change on disk behind Hushh's back.
@MainActor
struct MediaFileTests {
    /// A file deleted from disk behind TDLib's back is downloaded again; FileStore forgets its
    /// address.
    @Test func aFileDeletedFromDiskIsFetchedAgain() {
        let files = FileStore()
        let gone = FileManager.default.temporaryDirectory.appending(path: "hush-gone-\(UUID().uuidString).jpg")
        files.apply(Fixtures.file(20, path: gone.path, completed: true))
        #expect(files.handle(for: 20).localURL == gone)
        files.download(20)
        #expect(files.handle(for: 20).localURL == nil)
    }

    /// Save As replaces the file you chose only once the copy is made, so a failed copy keeps it.
    @Test func saveAsKeepsTheReplacedFileWhenTheCopyFails() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "report.pdf")
        try Data("old".utf8).write(to: destination)

        let missing = folder.appending(path: "gone.pdf")
        #expect(throws: (any Swift.Error).self) { try FileActions.copy(missing, to: destination) }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))

        let source = folder.appending(path: "new.pdf")
        try Data("new".utf8).write(to: source)
        try FileActions.copy(source, to: destination)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(try Data(contentsOf: source) == Data("new".utf8))
    }

    /// TDLib's files folder is emptied on logout and filled again for the next account, so a
    /// path can come back with another picture. The cache decodes it again.
    @Test func aNewPictureAtAnOldPathIsDecodedAgain() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "photo_0.jpg")
        try DemoData.drawPhoto(to: path, size: CGSize(width: 600, height: 200))
        let first = try #require(await ImageCache.load(path, maxPixelSize: 720))
        try FileManager.default.removeItem(at: path)
        try DemoData.drawPhoto(to: path, size: CGSize(width: 200, height: 600))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: path.path)
        let second = try #require(await ImageCache.load(path, maxPixelSize: 720))
        #expect(first.size.width > first.size.height)
        #expect(second.size.width < second.size.height)
    }

    @Test func durationsOverAnHourShowHours() {
        #expect(MediaDuration.text(42) == "0:42")
        #expect(MediaDuration.text(3599) == "59:59")
        #expect(MediaDuration.text(7200) == "2:00:00")
        #expect(MediaDuration.text(86_400) == "24:00:00")
    }
}
