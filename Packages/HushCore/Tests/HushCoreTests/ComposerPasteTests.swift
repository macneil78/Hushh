import AppKit
import Testing
@testable import HushUI

@MainActor
struct ComposerPasteTests {
    private let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

    private var png: Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    /// A private pasteboard, so the tests never touch your clipboard.
    private func textView(types: [NSPasteboard.PasteboardType], fill: (NSPasteboard) -> Void) -> (ComposerNSTextView, () -> [URL]?) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hush-tests-\(UUID().uuidString)"))
        pasteboard.declareTypes(types, owner: nil)
        fill(pasteboard)
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.pasteboard = pasteboard
        var pasted: [URL]?
        textView.onPasteFiles = { pasted = $0 }
        return (textView, { pasted })
    }

    @Test func aCopiedPictureCanBePastedAndBecomesAnAttachment() throws {
        let (textView, pasted) = textView(types: [.png]) { $0.setData(png, forType: .png) }
        #expect(textView.validateUserInterfaceItem(pasteItem))
        textView.paste(nil)
        let url = try #require(pasted()?.first)
        #expect(url.pathExtension == "png")
        #expect(NSImage(contentsOf: url) != nil)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func filesCopiedInFinderAreAttached() {
        let file = URL(filePath: "/tmp/report.pdf")
        let (textView, pasted) = textView(types: [.fileURL, .string]) {
            $0.setString(file.absoluteString, forType: .fileURL)
            $0.setString("report.pdf", forType: .string)
        }
        #expect(textView.validateUserInterfaceItem(pasteItem))
        textView.paste(nil)
        #expect(pasted() == [file])
    }

    @Test func textCopiedWithPicturesStillPastesAsText() {
        let (textView, pasted) = textView(types: [.string, .png]) {
            $0.setString("Look at this", forType: .string)
            $0.setData(png, forType: .png)
        }
        textView.paste(nil)
        #expect(pasted() == nil)
    }
}
