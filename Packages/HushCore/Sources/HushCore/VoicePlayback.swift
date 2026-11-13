import AVFoundation
import CryptoKit
import Foundation
import Observation

/// Plays one voice message at a time. Starting another stops the current one.
@MainActor @Observable
public final class VoicePlayback {
    /// A voice message. Telegram numbers messages per chat, so an id alone can name a message in
    /// every channel at once.
    public struct Key: Hashable, Sendable {
        public let chatId: Int64
        public let messageId: Int64

        public init(chatId: Int64, messageId: Int64) {
            self.chatId = chatId
            self.messageId = messageId
        }
    }

    /// Decoded copies live in a folder of their own, deleted by `reset()` when the session closes
    /// (logout or quit). Without a folder given, the player first deletes the ones earlier runs
    /// left behind (the app quits before it hears that the session closed).
    public init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            Self.removeLeftoverCopies()
            self.cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "hush-voicecache-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
    }

    /// The message playing or paused, if any.
    public private(set) var current: Key?
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    @ObservationIgnored public let cacheDirectory: URL
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public var progress: Double {
        duration > 0 ? currentTime / duration : 0
    }

    /// Plays or pauses a voice message. Returns true when this started it from the beginning.
    @discardableResult
    public func toggle(_ key: Key, url: URL) -> Bool {
        if current == key {
            guard let player else {
                stop()  // still preparing: a second click cancels
                return false
            }
            if player.isPlaying {
                player.pause()
                isPlaying = false
                ticker?.cancel()
            } else {
                player.play()
                isPlaying = true
                startTicking()
            }
            return false
        }
        stop()
        current = key
        isPlaying = true  // shows the pause button right away while the audio is prepared
        let directory = cacheDirectory
        Task {
            let playable: URL
            do {
                playable = try await Task.detached { try VoicePlayback.playableCopy(of: url, in: directory) }.value
            } catch {
                Log.session.error("Can't decode voice message: \(String(describing: error), privacy: .public)")
                if self.current == key { stop() }
                return
            }
            guard self.current == key else { return }  // another one was started meanwhile
            guard let player = try? AVAudioPlayer(contentsOf: playable), player.prepareToPlay() else {
                stop()
                return
            }
            self.player = player
            duration = player.duration
            player.play()
            startTicking()
        }
        return true
    }

    /// macOS decodes Telegram's Ogg/Opus voice messages, but AVAudioPlayer can't play that
    /// container. Play a decoded copy instead, kept until `reset()`. The copy is named after a
    /// hash of the file's bytes: TDLib names files `file_0`, `file_1`… and starts again after a
    /// logout, so a name can belong to another message, or another account's.
    nonisolated static func playableCopy(of url: URL, in directory: URL) throws -> URL {
        let output = directory.appending(path: "\(try contentHash(of: url)).caf")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let partial = directory.appending(path: "\(UUID().uuidString).partial.caf")
        defer { try? FileManager.default.removeItem(at: partial) }
        // 16-bit samples: half the size of the decoder's floats, and more than a voice needs.
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 16
        settings[AVLinearPCMIsFloatKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try file.write(from: buffer)
        }
        file.close()
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
        return output
    }

    /// SHA-256 of the file, read a megabyte at a time.
    private nonisolated static func contentHash(of url: URL) throws -> String {
        let handle = try Foundation.FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Jumps within the message that's playing or paused.
    public func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(fraction, 1)) * player.duration
        currentTime = player.currentTime
    }

    public func stop() {
        ticker?.cancel()
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// Stops playback and deletes the decoded copies, so the next account can't hear them.
    public func reset() {
        stop()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Earlier runs' folders, and the copies older builds kept loose in the temporary folder.
    /// Only this cache's own names: other parts of Hushh write `hush-voice-…` files while they work.
    private static func removeLeftoverCopies() {
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix("hush-voicecache-") || (name.hasPrefix("hush-play-") && name.hasSuffix(".caf")) {
            try? FileManager.default.removeItem(at: temporary.appending(path: name))
        }
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player else { return }
                if player.isPlaying {
                    self.currentTime = player.currentTime
                } else {
                    self.stop()  // reached the end
                    return
                }
            }
        }
    }
}

/// Records a voice message from the microphone.
@MainActor @Observable
public final class VoiceRecorder {
    public enum State: Equatable, Sendable {
        case idle
        /// macOS is asking whether Hushh may use the microphone. Nothing is recorded yet, and
        /// nothing will be: once you answer, you press Record again.
        case waitingForPermission
        case recording
        /// Turning the recording into Ogg/Opus.
        case encoding
    }

    public struct MicrophoneDenied: Error, CustomStringConvertible {
        public var description: String {
            "Hushh can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
        }
    }

    /// The first time, macOS asks for the microphone. Recording doesn't start by itself when you
    /// answer, which can be long after you pressed Record and moved on to typing.
    public struct MicrophoneAllowed: Error, CustomStringConvertible {
        public var description: String { "Hushh can use the microphone now. Press Record again to start." }
    }

    public private(set) var state: State = .idle
    public private(set) var elapsed: TimeInterval = 0
    /// The input level, from 0 to 1, for the live meter.
    public private(set) var level: Double = 0

    /// Whether macOS has said yes or no to the microphone yet, and asking it. Replaceable so
    /// tests never touch the real microphone or its permission prompt.
    @ObservationIgnored var permission: () -> AVAudioApplication.recordPermission = { AVAudioApplication.shared.recordPermission }
    @ObservationIgnored var requestPermission: () async -> Bool = { await AVAudioApplication.requestRecordPermission() }

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var url: URL?

    /// Starts recording at once if Hushh may use the microphone. Otherwise asks for it and
    /// stops there (throwing `MicrophoneAllowed` or `MicrophoneDenied`).
    public func start() async throws {
        guard state == .idle else { return }
        switch permission() {
        case .granted:
            break
        case .denied:
            throw MicrophoneDenied()
        default:
            state = .waitingForPermission
            let isAllowed = await requestPermission()
            // Cancelled meanwhile (Esc, another chat): the answer no longer matters.
            guard state == .waitingForPermission else { return }
            state = .idle
            throw isAllowed ? MicrophoneAllowed() as any Error : MicrophoneDenied()
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "hush-recording-\(UUID().uuidString).caf")
        // Uncompressed 48 kHz mono, which the Opus encoder takes as is.
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            recorder.deleteRecording()
            throw MicrophoneDenied()
        }
        self.recorder = recorder
        self.url = url
        elapsed = 0
        state = .recording
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                // Decibels (−160…0) to a 0…1 level that moves visibly with speech.
                self.level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
            }
        }
    }

    /// Stops and encodes the recording. Nil for a slip of under half a second.
    func finish() async throws -> VoiceNoteEncoder.VoiceNote? {
        guard state == .recording, let recorder, let url else { return nil }
        let length = recorder.currentTime
        recorder.stop()
        ticker?.cancel()
        self.recorder = nil
        state = .encoding
        defer {
            state = .idle
            level = 0
            try? FileManager.default.removeItem(at: url)
        }
        guard length >= 0.5 else { return nil }
        return try await Task.detached { try VoiceNoteEncoder.encode(url) }.value
    }

    /// Throws the recording away, or stops waiting for the microphone permission.
    public func cancel() {
        if state == .waitingForPermission {
            state = .idle
            return
        }
        guard state == .recording else { return }
        recorder?.stop()
        recorder?.deleteRecording()
        ticker?.cancel()
        recorder = nil
        url = nil
        state = .idle
        level = 0
    }
}
