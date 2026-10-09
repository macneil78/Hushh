import AVFoundation
import AudioToolbox
import Foundation

/// Telegram's voice-message waveform: one level from 0 to 31 per bar, packed five bits at a
/// time, least significant bit first (as Telegram's own apps read and write it).
public enum Waveform {
    public static let barCount = 100

    public static func unpack(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        return (0 ..< bytes.count * 8 / 5).map { index in
            let bitOffset = index * 5
            let byteIndex = bitOffset / 8
            let shift = bitOffset % 8
            var value = Int(bytes[byteIndex]) >> shift
            if shift > 3, byteIndex + 1 < bytes.count {
                value |= Int(bytes[byteIndex + 1]) << (8 - shift)
            }
            return UInt8(value & 0x1f)
        }
    }

    public static func pack(_ values: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: (values.count * 5 + 7) / 8)
        for (index, value) in values.enumerated() {
            let value = Int(min(value, 31))
            let bitOffset = index * 5
            let byteIndex = bitOffset / 8
            let shift = bitOffset % 8
            bytes[byteIndex] |= UInt8((value << shift) & 0xff)
            if shift > 3 { bytes[byteIndex + 1] |= UInt8(value >> (8 - shift)) }
        }
        return Data(bytes)
    }

    /// Bars for a recording: the loudest sample in each slice, scaled so the loudest bar is 31.
    static func bars(from samples: [Float], count: Int = barCount) -> [UInt8] {
        guard !samples.isEmpty else { return [] }
        let slice = Int((Double(samples.count) / Double(count)).rounded(.up))
        let peaks = stride(from: 0, to: samples.count, by: slice).map { start in
            samples[start ..< min(start + slice, samples.count)].reduce(Float(0)) { max($0, abs($1)) }
        }
        let loudest = peaks.max() ?? 0
        guard loudest > 0 else { return peaks.map { _ in 0 } }
        return peaks.map { UInt8(($0 / loudest * 31).rounded()) }
    }
}

/// Wraps Opus packets in an Ogg container (RFC 7845), the format Telegram expects for voice
/// messages. macOS can encode Opus and read Ogg files, but it can't write them.
enum OggOpusWriter {
    struct Stream {
        var packets: [Data]
        var framesPerPacket: Int
        /// Samples the decoder drops at the start: the encoder's priming.
        var preSkip: Int
        /// Samples of real audio, so players trim the encoder's padding at the end.
        var validFrames: Int
        var channels = 1
        var inputSampleRate = 48000
    }

    static func data(for stream: Stream, serial: UInt32 = .random(in: .min ... .max)) -> Data {
        var output = Data()
        var sequence: UInt32 = 0

        func appendPage(_ packets: [Data], granule: Int64, flags: UInt8) {
            var lacing: [UInt8] = []
            for packet in packets {
                var size = packet.count
                while size >= 255 {
                    lacing.append(255)
                    size -= 255
                }
                lacing.append(UInt8(size))
            }
            var page = Data("OggS".utf8)
            page.append(0)  // version
            page.append(flags)
            page.appendLittleEndian(UInt64(bitPattern: granule))
            page.appendLittleEndian(serial)
            page.appendLittleEndian(sequence)
            page.appendLittleEndian(UInt32(0))  // checksum, filled in below
            page.append(UInt8(lacing.count))
            page.append(contentsOf: lacing)
            packets.forEach { page.append($0) }
            let checksum = OggCRC.checksum(page)
            page.replaceSubrange(22 ..< 26, with: withUnsafeBytes(of: checksum.littleEndian) { Data($0) })
            output.append(page)
            sequence += 1
        }

        var head = Data("OpusHead".utf8)
        head.append(1)  // version
        head.append(UInt8(stream.channels))
        head.appendLittleEndian(UInt16(stream.preSkip))
        head.appendLittleEndian(UInt32(stream.inputSampleRate))
        head.appendLittleEndian(UInt16(0))  // output gain
        head.append(0)  // channel mapping family: mono or stereo
        appendPage([head], granule: 0, flags: 0x02)  // beginning of stream

        let vendor = Data("Hushh".utf8)
        var tags = Data("OpusTags".utf8)
        tags.appendLittleEndian(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLittleEndian(UInt32(0))  // no comments
        appendPage([tags], granule: 0, flags: 0)

        // Audio pages of about a second each. A page's granule position is the sample count
        // decoded by its end; the last one marks where real audio stops.
        var index = 0
        var decoded: Int64 = 0
        while index < stream.packets.count {
            var batch: [Data] = []
            var lacingCount = 0
            while index < stream.packets.count, batch.count < 50 {
                let needed = stream.packets[index].count / 255 + 1
                guard lacingCount + needed <= 255 else { break }
                batch.append(stream.packets[index])
                lacingCount += needed
                index += 1
            }
            decoded += Int64(batch.count * stream.framesPerPacket)
            let isLast = index == stream.packets.count
            let granule = isLast ? min(decoded, Int64(stream.preSkip + stream.validFrames)) : decoded
            appendPage(batch, granule: granule, flags: isLast ? 0x04 : 0)  // end of stream
        }
        return output
    }
}

/// Ogg's page checksum: CRC-32 with polynomial 0x04C11DB7, no reflection, starting from zero.
enum OggCRC {
    private static let table: [UInt32] = (0 ..< 256).map { index in
        var value = UInt32(index) << 24
        for _ in 0 ..< 8 {
            value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { crc, byte in
            (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(byte))]
        }
    }
}

/// Turns a recording into a Telegram voice message: Opus in Ogg, with its waveform and length.
enum VoiceNoteEncoder {
    struct VoiceNote: Sendable {
        let url: URL
        /// Seconds.
        let duration: Int
        let waveform: Data
    }

    struct EncodingError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "Couldn't encode the voice message (\(step): \(status))." }
    }

    static func encode(_ recording: URL) throws -> VoiceNote {
        let input = try AVAudioFile(forReading: recording)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)) else {
            throw EncodingError(step: "buffer", status: -1)
        }
        try input.read(into: buffer)
        let samples = buffer.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength))) } ?? []

        // Apple's Opus encoder only writes CAF files, so encode to one, then rewrap its packets.
        let caf = FileManager.default.temporaryDirectory.appending(path: "hush-voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: caf) }
        try encodeOpus(buffer, to: caf)
        let stream = try readPackets(caf)

        let ogg = FileManager.default.temporaryDirectory.appending(path: "hush-voice-\(UUID().uuidString).ogg")
        try OggOpusWriter.data(for: stream).write(to: ogg)
        return VoiceNote(
            url: ogg,
            duration: max(1, Int((Double(stream.validFrames) / 48000).rounded())),
            waveform: Waveform.pack(Waveform.bars(from: samples))
        )
    }

    private static func encodeOpus(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        var opus = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        var file: ExtAudioFileRef?
        try check("create", ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &opus, nil, AudioFileFlags.eraseFile.rawValue, &file))
        guard let file else { throw EncodingError(step: "create", status: -1) }
        defer { ExtAudioFileDispose(file) }
        var client = buffer.format.streamDescription.pointee
        try check("format", ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client
        ))
        try check("write", ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList))
    }

    private static func readPackets(_ url: URL) throws -> OggOpusWriter.Stream {
        var fileID: AudioFileID?
        try check("open", AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileCAFType, &fileID))
        guard let fileID else { throw EncodingError(step: "open", status: -1) }
        defer { AudioFileClose(fileID) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("format", AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size, &format))
        var packetCount: UInt64 = 0
        size = UInt32(MemoryLayout<UInt64>.size)
        try check("count", AudioFileGetProperty(fileID, kAudioFilePropertyAudioDataPacketCount, &size, &packetCount))
        var table = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        try check("table", AudioFileGetProperty(fileID, kAudioFilePropertyPacketTableInfo, &size, &table))
        var maxPacketSize: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        try check("size", AudioFileGetProperty(fileID, kAudioFilePropertyMaximumPacketSize, &size, &maxPacketSize))

        var packets: [Data] = []
        packets.reserveCapacity(Int(packetCount))
        var bytes = [UInt8](repeating: 0, count: Int(maxPacketSize))
        for index in 0 ..< Int64(packetCount) {
            var byteCount = maxPacketSize
            var count: UInt32 = 1
            var description = AudioStreamPacketDescription()
            try check("read", AudioFileReadPacketData(fileID, false, &byteCount, &description, index, &count, &bytes))
            packets.append(Data(bytes[0 ..< Int(byteCount)]))
        }
        return OggOpusWriter.Stream(
            packets: packets,
            framesPerPacket: Int(format.mFramesPerPacket),
            preSkip: Int(table.mPrimingFrames),
            validFrames: Int(table.mNumberValidFrames)
        )
    }

    private static func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw EncodingError(step: step, status: status) }
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
