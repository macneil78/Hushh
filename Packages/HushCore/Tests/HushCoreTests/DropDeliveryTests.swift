import AppKit
import SwiftUI
import Testing
@testable import HushUI

/// Drives a drop through SwiftUI's real drop handling, as AppKit does when you let go of a file
/// dragged from Finder, and checks the file reaches the conversation.
@MainActor
struct DropDeliveryTests {
    /// The usual path: the files are read off the drag pasteboard during the drop.
    @Test func droppedFinderFileReachesTheConversation() async throws {
        try await dropFile(readingPasteboard: true)
    }

    /// The fallback, for drags whose pasteboard Hushh can't read directly: item providers.
    @Test func itemProvidersAreTheFallback() async throws {
        try await dropFile(readingPasteboard: false)
    }

    private func dropFile(readingPasteboard: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hush-drop-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hush-drop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let empty = NSPasteboard(name: NSPasteboard.Name("hush-drop-test-empty-\(UUID().uuidString)"))
        empty.clearContents()
        defer {
            pasteboard.releaseGlobally()
            empty.releaseGlobally()
        }

        let received = Received()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: DropHost(received: received, pasteboard: readingPasteboard ? pasteboard : empty))
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI register its drop targets.
        try await Task.sleep(for: .milliseconds(250))

        let target = try #require(Self.dropTarget(in: hosting), "no view registered for drags")
        // Bottom half of the window (AppKit's y grows upward): the "photos & videos" zone.
        let drag = FakeDrag(pasteboard: pasteboard, location: NSPoint(x: 200, y: 150), window: window)

        let entered = target.draggingEntered(drag)
        let updated = target.draggingUpdated(drag)
        let prepared = target.prepareForDragOperation(drag)
        let performed = target.performDragOperation(drag)
        target.concludeDragOperation(drag)

        for _ in 0..<40 where received.urls.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!entered.isEmpty, "draggingEntered refused the drag")
        #expect(!updated.isEmpty, "draggingUpdated refused the drag")
        #expect(prepared)
        #expect(performed, "performDragOperation returned false")
        #expect(received.urls.map(\.standardizedFileURL) == [file.standardizedFileURL])
        #expect(received.asFiles == false)
    }

    private static func dropTarget(in view: NSView) -> NSView? {
        if !view.registeredDraggedTypes.isEmpty { return view }
        for subview in view.subviews {
            if let found = dropTarget(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private final class Received {
    var urls: [URL] = []
    var asFiles: Bool?
}

private struct DropHost: View {
    let received: Received
    let pasteboard: NSPasteboard
    @State private var drop: DropState?

    var body: some View {
        Color.clear
            .frame(width: 400, height: 600)
            .onDrop(of: [.fileURL], delegate: AttachmentDropDelegate(
                state: $drop,
                height: 600,
                isEnabled: true,
                pasteboard: { pasteboard },
                onDrop: { urls, asFiles in
                    received.urls = urls
                    received.asFiles = asFiles
                }
            ))
            .overlay {
                if let drop { DropZonesOverlay(state: drop) }
            }
    }
}

/// What AppKit hands a drop target while a file from Finder is dragged over it.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic, .move] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
