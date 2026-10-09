import AppKit
import HushCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Each step of a drop, in Console.app under the "Hush" subsystem. File counts only, never names.
private let dropLog = Logger(subsystem: "Hush", category: "drop")

/// What's being dragged over the conversation, and which zone it's over.
struct DropState: Equatable {
    enum Zone: Equatable {
        /// Original quality, as files.
        case files
        /// Compressed, shown in the chat as photos and videos.
        case media
    }

    /// Only drags with pictures or videos get the choice; other files just send as files.
    var hasMedia: Bool
    var zone: Zone
}

/// Drops on the conversation, Telegram-style: the top half sends as files, the bottom half as
/// photos and videos. One delegate for the whole area, choosing by position, so the zones never
/// fight over the drag.
struct AttachmentDropDelegate: DropDelegate {
    @Binding var state: DropState?
    let height: CGFloat
    let isEnabled: Bool
    /// Where the dragged files are listed: the system's drag pasteboard (tests pass their own).
    var pasteboard: @MainActor () -> NSPasteboard = { NSPasteboard(name: .drag) }
    let onDrop: @MainActor (_ urls: [URL], _ asFiles: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let isValid = isEnabled && info.hasItemsConforming(to: [.fileURL])
        if !isValid { dropLog.notice("Drop refused (can post: \(isEnabled, privacy: .public))") }
        return isValid
    }

    func dropEntered(info: DropInfo) {
        state = DropState(hasMedia: info.hasItemsConforming(to: [.image, .movie]), zone: zone(for: info))
        dropLog.notice("Drag entered the conversation (pictures or videos: \(state?.hasMedia == true, privacy: .public))")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        state?.zone = zone(for: info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        state = nil
        dropLog.notice("Drag left the conversation")
    }

    func performDrop(info: DropInfo) -> Bool {
        let asFiles = state.map { !$0.hasMedia || $0.zone == .files } ?? true
        state = nil
        // Read the files off the drag pasteboard now, while the drop is under way: that's when
        // the sandbox lets Hushh open them. Item providers load later, which can be too late.
        let urls = Self.fileURLs(on: pasteboard())
        dropLog.notice("Drop: \(urls.count, privacy: .public) file(s) on the drag pasteboard, as files: \(asFiles, privacy: .public)")
        if !urls.isEmpty {
            onDrop(urls, asFiles)
            return true
        }
        let collected = DroppedURLs()
        let group = DispatchGroup()
        for itemProvider in info.itemProviders(for: [.fileURL]) {
            // NSItemProvider loads on its own queues and is safe to use from any of them.
            nonisolated(unsafe) let provider = itemProvider
            group.enter()
            // Ask for the file URL itself, as Finder provides it. @Sendable: AppKit calls this on a
            // background queue.
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { @Sendable item, _ in
                if let url = Self.fileURL(from: item) {
                    collected.append(url)
                    group.leave()
                } else {
                    // Some sources only offer the URL as an object.
                    _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                        if let url { collected.append(url) }
                        group.leave()
                    }
                }
            }
        }
        let onDrop = onDrop
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = collected.urls
                dropLog.notice("Drop: \(urls.count, privacy: .public) file(s) from item providers")
                if !urls.isEmpty { onDrop(urls, asFiles) }
            }
        }
        return true
    }

    /// The file URLs on a pasteboard, as Finder puts them there.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    /// Finder hands over file URLs as URL objects or as their data representation.
    nonisolated static func fileURL(from item: (any NSSecureCoding)?) -> URL? {
        if let url = item as? URL { return url.isFileURL ? url : nil }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url.isFileURL ? url : nil }
        if let string = item as? String, let url = URL(string: string) { return url.isFileURL ? url : nil }
        return nil
    }

    private func zone(for info: DropInfo) -> DropState.Zone {
        info.location.y < height / 2 ? .files : .media
    }
}

/// The overlay while dragging: two big zones, the one under the pointer highlighted.
struct DropZonesOverlay: View {
    let state: DropState

    var body: some View {
        VStack(spacing: 12) {
            if state.hasMedia {
                zone("Send as Files", detail: "Original quality, nothing compressed", systemImage: "doc.on.doc", isActive: state.zone == .files)
                zone("Send as Photos & Videos", detail: "Compressed and shown right in the chat", systemImage: "photo.on.rectangle", isActive: state.zone == .media)
            } else {
                zone("Drop to Send", detail: "Add a caption, then press Enter", systemImage: "doc.on.doc", isActive: true)
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .allowsHitTesting(false)  // the drop delegate underneath handles everything
    }

    private func zone(_ title: String, detail: String, systemImage: String, isActive: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
        .animation(.easeOut(duration: 0.12), value: isActive)
    }
}

/// URLs gathered from a drop's item providers, which deliver on background queues.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] { lock.withLock { storage } }

    func append(_ url: URL) {
        lock.withLock { storage.append(url) }
    }
}

extension NSItemProvider {
    /// A downloaded file, ready to drag out of Hushh into Finder or another app. Empty when the
    /// file isn't on disk yet.
    static func file(_ url: URL?) -> NSItemProvider {
        url.flatMap(NSItemProvider.init(contentsOf:)) ?? NSItemProvider()
    }
}
