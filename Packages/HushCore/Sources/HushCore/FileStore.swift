@preconcurrency import TDLibKit
import Foundation
import Observation

/// One TDLib file. Views observe it to appear once the download finishes.
@MainActor @Observable
public final class FileHandle {
    public nonisolated let id: Int
    public internal(set) var localURL: URL?
    public internal(set) var isDownloading = false
    /// 0…1 while downloading, when the size is known.
    public internal(set) var progress: Double?

    init(id: Int) {
        self.id = id
    }
}

/// Downloads TDLib files on demand and tracks where they land on disk.
@MainActor
public final class FileStore {
    public init() {}

    private var handles: [Int: FileHandle] = [:]
    private var requested: Set<Int> = []
    private var client: TDLibClient?

    public func handle(for id: Int) -> FileHandle {
        if let handle = handles[id] { return handle }
        let handle = FileHandle(id: id)
        handles[id] = handle
        return handle
    }

    /// Starts downloading the file unless it's already on disk or on its way. Safe to call repeatedly.
    /// A file that's already on disk (the demo window's photo and voice message).
    public func provide(_ url: URL, for id: Int) {
        handle(for: id).localURL = url
    }

    public func download(_ id: Int, priority: Int = 1) {
        guard let client, handle(for: id).localURL == nil, requested.insert(id).inserted else { return }
        Task {
            do {
                let file = try await client.downloadFile(fileId: id, limit: 0, offset: 0, priority: priority, synchronous: false)
                apply(file)
            } catch {
                requested.remove(id)
                Log.session.error("Download of file \(id) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func attach(_ client: TDLibClient) {
        self.client = client
    }

    func reset() {
        client = nil
        handles = [:]
        requested = []
    }

    func apply(_ file: File) {
        let local = file.local
        let url = local.isDownloadingCompleted && !local.path.isEmpty ? URL(filePath: local.path) : nil
        let handle = handle(for: file.id)
        if handle.localURL != url { handle.localURL = url }
        if handle.isDownloading != local.isDownloadingActive { handle.isDownloading = local.isDownloadingActive }
        let expected = max(file.size, file.expectedSize)
        let progress = local.isDownloadingActive && expected > 0 ? Double(local.downloadedSize) / Double(expected) : nil
        // Whole percents only, so a download doesn't redraw its view thousands of times.
        let rounded = progress.map { ($0 * 100).rounded() / 100 }
        if handle.progress != rounded { handle.progress = rounded }
        // TDLib's storage optimizer may delete files; let a later download() fetch them again.
        if url == nil, !local.isDownloadingActive { requested.remove(file.id) }
    }
}
