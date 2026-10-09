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

        let playable = try VoicePlayback.playableCopy(of: note.url)
        defer { try? FileManager.default.removeItem(at: playable) }
        let player = try AVAudioPlayer(contentsOf: playable)
        #expect(player.prepareToPlay())
        #expect(abs(player.duration - 2) < 0.1)
        // A second play reuses the copy.
        #expect(try VoicePlayback.playableCopy(of: note.url) == playable)
    }
}
