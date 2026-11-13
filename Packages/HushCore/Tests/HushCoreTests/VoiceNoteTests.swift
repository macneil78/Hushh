import AVFoundation
import Foundation
import Testing
@testable import HushCore

struct WaveformTests {
    @Test func packingRoundTrips() {
        let values: [UInt8] = (0 ..< 100).map { UInt8($0 % 32) }
        let packed = Waveform.pack(values)
        #expect(packed.count == 63)  // 100 bars × 5 bits, as Telegram sends them
        #expect(Array(Waveform.unpack(packed).prefix(100)) == values)
    }

    @Test func packsLeastSignificantBitFirst() {
        // 31 then 1: bits 11111 then 10000… → first byte 0b0011_1111.
        #expect([UInt8](Waveform.pack([31, 1])) == [0b0011_1111, 0b0000_0000])
    }

    @Test func barsFollowLoudness() {
        let quietThenLoud = (0 ..< 1000).map { Float($0) / 1000 }
        let bars = Waveform.bars(from: quietThenLoud, count: 10)
        #expect(bars.count == 10)
        #expect(bars.first! < bars.last!)
        #expect(bars.last == 31)
    }
}

struct OggCRCTests {
    @Test func matchesTheReferenceCheckSum() {
        // CRC-32/MPEG-2 without the initial 0xFFFFFFFF, as Ogg uses it, for "123456789".
        #expect(OggCRC.checksum(Data("123456789".utf8)) == 0x89A1_897F)
    }
}

struct VoiceNoteEncoderTests {
    /// Two seconds of a tone that grows louder, recorded the way Hush records: 48 kHz mono PCM.
    private func recording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hush-test-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frames = AVAudioFrameCount(96000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0 ..< Int(frames) {
            let loudness = Float(index) / Float(frames)
            buffer.floatChannelData![0][index] = 0.8 * loudness * sin(2 * .pi * 440 * Float(index) / 48000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @Test func producesOggOpusThatMacOSCanDecode() throws {
        let recording = try recording()
        defer { try? FileManager.default.removeItem(at: recording) }

        let note = try VoiceNoteEncoder.encode(recording)
        defer { try? FileManager.default.removeItem(at: note.url) }

        #expect(note.duration == 2)
        #expect(note.waveform.count == 63)
        let bars = Waveform.unpack(note.waveform)
        #expect(bars[5] < bars[95])  // the tone gets louder

        let data = try Data(contentsOf: note.url)
        #expect(data.prefix(4) == Data("OggS".utf8))

        // Apple's own decoder reading the file back proves the Ogg wrapping is valid.
        let decoded = try AVAudioFile(forReading: note.url)
        #expect(decoded.fileFormat.channelCount == 1)
        #expect(decoded.fileFormat.sampleRate == 48000)
        #expect(abs(Double(decoded.length) - 96000) < 2000)
    }

    /// AVAudioPlayer reads an Ogg file's length but can't prepare it for playback (macOS 27), so
    /// voice messages play from a decoded copy. This is what pressing play does.
    @Test @MainActor func voiceMessagesPlayFromADecodedCopy() throws {
        let recording = try recording()
        defer { try? FileManager.default.removeItem(at: recording) }
        let note = try VoiceNoteEncoder.encode(recording)
        defer { try? FileManager.default.removeItem(at: note.url) }

        let cache = FileManager.default.temporaryDirectory.appending(path: "hush-test-voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let playable = try VoicePlayback.playableCopy(of: note.url, in: cache)
        let player = try AVAudioPlayer(contentsOf: playable)
        #expect(player.prepareToPlay())
        #expect(abs(player.duration - 2) < 0.1)
        // A second play reuses the copy.
        #expect(try VoicePlayback.playableCopy(of: note.url, in: cache) == playable)
    }
}

/// Voice playback: one player for the whole app, so these run one at a time.
@MainActor
@Suite(.serialized)
struct VoicePlaybackTests {
    /// A mono tone of `seconds`, written as CAF.
    private func tone(_ url: URL, seconds: Double, hz: Float = 440) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0 ..< Int(frames) { buffer.floatChannelData![0][i] = 0.2 * sin(2 * .pi * hz * Float(i) / 16_000) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func seconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Every channel has a post 5. Playing chat B's post 5 while chat A's plays switches to B's
    /// audio.
    @Test func theSameMessageIdInAnotherChatPlaysItsOwnAudio() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appending(path: "a.caf"), b = folder.appending(path: "b.caf")
        try tone(a, seconds: 2, hz: 300)
        try tone(b, seconds: 6, hz: 600)
        let voice = VoicePlayback(cacheDirectory: folder.appending(path: "cache"))
        defer { voice.reset() }

        let inA = VoicePlayback.Key(chatId: 1, messageId: 5 << 20)
        let inB = VoicePlayback.Key(chatId: 2, messageId: 5 << 20)
        #expect(voice.toggle(inA, url: a))
        await Fixtures.wait { voice.duration > 0 }
        #expect(voice.toggle(inB, url: b))
        await Fixtures.wait { voice.duration > 3 }
        #expect(voice.current == inB)
        #expect(voice.isPlaying)
        #expect(abs(voice.duration - 6) < 0.1)
    }

    /// TDLib names voice files `file_0`, `file_1`… and starts again after a logout. Two
    /// recordings with one name get decoded copies of their own.
    @Test func recordingsWithTheSameFileNameDecodeSeparately() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "account1/voice/file_0.caf")
        let second = folder.appending(path: "account2/voice/file_0.caf")
        try tone(first, seconds: 1)
        try tone(second, seconds: 4)
        let cache = folder.appending(path: "cache")

        let copy1 = try VoicePlayback.playableCopy(of: first, in: cache)
        let copy2 = try VoicePlayback.playableCopy(of: second, in: cache)
        #expect(copy1 != copy2)
        #expect(abs(try seconds(copy1) - 1) < 0.05)
        #expect(abs(try seconds(copy2) - 4) < 0.05)
    }

    /// Logging out (or quitting) deletes every decoded voice message.
    @Test func resetDeletesTheDecodedCopies() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = folder.appending(path: "voice.caf")
        try tone(recording, seconds: 1)
        let cache = folder.appending(path: "cache")
        let voice = VoicePlayback(cacheDirectory: cache)
        voice.toggle(VoicePlayback.Key(chatId: 1, messageId: 1), url: recording)
        await Fixtures.wait { voice.duration > 0 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)

        voice.reset()
        #expect(voice.current == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    /// The app quits without hearing that its session closed, so a run's copies can outlive it.
    /// The next run's player deletes them, and loose copies named the earlier way.
    @Test func earlierRunsCopiesAreDeletedAtStart() throws {
        let temporary = FileManager.default.temporaryDirectory
        let earlierRun = temporary.appending(path: "hush-voicecache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: earlierRun, withIntermediateDirectories: true)
        try Data("decoded".utf8).write(to: earlierRun.appending(path: "copy.caf"))
        let looseCopy = temporary.appending(path: "hush-play-file_\(UUID().uuidString).caf")
        try Data("decoded".utf8).write(to: looseCopy)

        _ = VoicePlayback()
        #expect(!FileManager.default.fileExists(atPath: earlierRun.path))
        #expect(!FileManager.default.fileExists(atPath: looseCopy.path))
    }
}
