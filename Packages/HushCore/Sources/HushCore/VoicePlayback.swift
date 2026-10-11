import AVFoundation
import Foundation
import Observation

/// Plays one voice message at a time. Starting another stops the current one.
@MainActor @Observable
public final class VoicePlayback {
    public init() {}

    /// The message playing or paused, if any.
    public private(set) var messageId: Int64?
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public var progress: Double {
        duration > 0 ? currentTime / duration : 0
    }

    /// Plays or pauses a voice message. Returns true when this started it from the beginning.
    @discardableResult
    public func toggle(messageId: Int64, url: URL) -> Bool {
        if self.messageId == messageId {
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
        self.messageId = messageId
        isPlaying = true  // shows the pause button right away while the audio is prepared
        Task {
            let playable: URL
            do {
                playable = try await Task.detached { try VoicePlayback.playableCopy(of: url) }.value
            } catch {
                Log.session.error("Can't decode voice message: \(String(describing: error), privacy: .public)")
                if self.messageId == messageId { stop() }
                return
            }
            guard self.messageId == messageId else { return }  // another one was started meanwhile
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
    /// container. Play a decoded copy instead, cached per file for the rest of the session.
    nonisolated static func playableCopy(of url: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let output = directory.appending(path: "hush-play-\(url.deletingPathExtension().lastPathComponent).caf")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let partial = directory.appending(path: "hush-play-\(UUID().uuidString).partial.caf")
        let file = try AVAudioFile(forWriting: partial, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
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
        messageId = nil
        isPlaying = false
        currentTime = 0
        duration = 0
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
        case recording
        /// Turning the recording into Ogg/Opus.
        case encoding
    }

    public struct MicrophoneDenied: Error, CustomStringConvertible {
        public var description: String {
            "Hushh can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
        }
    }

    public private(set) var state: State = .idle
    public private(set) var elapsed: TimeInterval = 0
    /// The input level, from 0 to 1, for the live meter.
    public private(set) var level: Double = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var url: URL?

    /// Starts recording, asking for the microphone the first time.
    public func start() async throws {
        guard state == .idle else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw MicrophoneDenied() }
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

    public func cancel() {
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
