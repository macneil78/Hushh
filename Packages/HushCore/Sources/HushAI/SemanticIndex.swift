import Accelerate
import Foundation
import HushCore

/// What's worth searching by meaning in a message.
public enum SearchText {
    /// The words a message carries: its text or caption, and a voice message's or circle's
    /// transcript from Telegram.
    public static func of(_ message: MessageModel) -> String {
        [message.plainText, message.transcript ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// "ок", "ахахах" and emoji have no meaning to match, and sit close to everything, so they'd
    /// crowd real matches out. They stay findable by word search.
    public static func isMeaningful(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 2 }
        let letters = words.reduce(0) { $0 + $1.count }
        guard !isLaughter(text) else { return false }
        return (words.count >= 2 && letters >= 6) || letters >= 12
    }

    /// "ахахах", "хехе", "hahaha".
    private static func isLaughter(_ text: String) -> Bool {
        let letters = Set(text.lowercased().filter(\.isLetter))
        return !letters.isEmpty && letters.isSubset(of: ["а", "х", "е", "ы", "h", "a", "e", "x"])
    }
}

/// A chat's messages as vectors, for search by meaning. Kept in the account's vault.
public struct SemanticIndex: Sendable {
    public static let dimensions = TextEmbedder.dimensions

    private(set) var ids: [Int64] = []
    /// `ids.count` rows of `dimensions` numbers, each row unit length.
    private(set) var vectors: [Float] = []
    /// Each message's row, so adding never scans the whole index.
    private var rows: [Int64: Int] = [:]
    /// The newest and oldest messages looked at (indexed or skipped), so indexing picks up where
    /// it stopped, in both directions.
    public var newestSeen: Int64 = 0
    public var oldestSeen: Int64 = 0
    /// How many messages have been looked at.
    public var seenCount = 0
    /// Reached the start of the chat.
    public var isComplete = false

    public init() {}

    public var count: Int { ids.count }

    public func contains(_ id: Int64) -> Bool {
        rows[id] != nil
    }

    public mutating func add(_ id: Int64, vector: [Float]) {
        precondition(vector.count == Self.dimensions)
        if let row = rows[id] {
            vectors.replaceSubrange(row * Self.dimensions ..< (row + 1) * Self.dimensions, with: vector)
        } else {
            rows[id] = ids.count
            ids.append(id)
            vectors.append(contentsOf: vector)
        }
    }

    public mutating func remove(_ removed: Set<Int64>) {
        guard ids.contains(where: removed.contains) else { return }
        var keptIds: [Int64] = []
        var keptVectors: [Float] = []
        for (row, id) in ids.enumerated() where !removed.contains(id) {
            keptIds.append(id)
            keptVectors.append(contentsOf: vectors[row * Self.dimensions ..< (row + 1) * Self.dimensions])
        }
        ids = keptIds
        vectors = keptVectors
        rows = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    }

    /// The closest messages to a query vector, best first, with their cosine similarity.
    public func search(_ query: [Float], limit: Int) -> [(id: Int64, score: Float)] {
        guard !ids.isEmpty, query.count == Self.dimensions else { return [] }
        var scores = [Float](repeating: 0, count: ids.count)
        // Every row against the query in one matrix-vector product.
        vDSP_mmul(vectors, 1, query, 1, &scores, 1, vDSP_Length(ids.count), 1, vDSP_Length(Self.dimensions))
        return scores.indices
            .sorted { scores[$0] > scores[$1] }
            .prefix(limit)
            .map { (ids[$0], scores[$0]) }
    }

    // MARK: Saving

    private static let magic = Data("HSI1".utf8)
    private static let headerSize = 4 + 4 + 4 + 8 + 8 + 4 + 1

    /// Vectors are stored as half floats: half the size, and plenty for ranking. Arrays are
    /// copied as they are in memory; every Mac is little-endian.
    public func serialized() -> Data {
        var data = Data(capacity: Self.headerSize + ids.count * 8 + vectors.count * 2)
        data.append(Self.magic)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(UInt32(Self.dimensions))
        append(UInt32(ids.count))
        append(newestSeen)
        append(oldestSeen)
        append(UInt32(seenCount))
        append(UInt8(isComplete ? 1 : 0))
        ids.withUnsafeBytes { data.append(contentsOf: $0) }
        Self.halfFloats(from: vectors).withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public init?(serialized data: Data) {
        guard data.count >= Self.headerSize, data.prefix(4) == Self.magic else { return nil }
        func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        guard read(UInt32.self, at: 4) == UInt32(Self.dimensions) else { return nil }
        let count = Int(read(UInt32.self, at: 8))
        guard data.count == Self.headerSize + count * 8 + count * Self.dimensions * 2 else { return nil }
        newestSeen = read(Int64.self, at: 12)
        oldestSeen = read(Int64.self, at: 20)
        seenCount = Int(read(UInt32.self, at: 28))
        isComplete = read(UInt8.self, at: 32) == 1
        let vectorStart = Self.headerSize + count * 8
        var ids = [Int64](repeating: 0, count: count)
        var halves = [UInt16](repeating: 0, count: count * Self.dimensions)
        data.withUnsafeBytes { raw in
            ids.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[Self.headerSize..<vectorStart])) }
            halves.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[vectorStart...])) }
        }
        self.ids = ids
        vectors = Self.floats(fromHalf: halves)
        rows = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    }

    // vImage converts to and from half floats on both Apple silicon and Intel (Swift's Float16
    // doesn't exist on Intel Macs), and does a whole index in one call.

    static func halfFloats(from floats: [Float]) -> [UInt16] {
        guard !floats.isEmpty else { return [] }
        var halves = [UInt16](repeating: 0, count: floats.count)
        floats.withUnsafeBufferPointer { source in
            halves.withUnsafeMutableBufferPointer { destination in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1, width: vImagePixelCount(floats.count), rowBytes: floats.count * 4)
                var output = vImage_Buffer(data: destination.baseAddress!, height: 1, width: vImagePixelCount(floats.count), rowBytes: floats.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&input, &output, vImage_Flags(kvImageNoFlags))
            }
        }
        return halves
    }

    static func floats(fromHalf halves: [UInt16]) -> [Float] {
        guard !halves.isEmpty else { return [] }
        var floats = [Float](repeating: 0, count: halves.count)
        halves.withUnsafeBufferPointer { source in
            floats.withUnsafeMutableBufferPointer { destination in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1, width: vImagePixelCount(halves.count), rowBytes: halves.count * 2)
                var output = vImage_Buffer(data: destination.baseAddress!, height: 1, width: vImagePixelCount(halves.count), rowBytes: halves.count * 4)
                vImageConvert_Planar16FtoPlanarF(&input, &output, vImage_Flags(kvImageNoFlags))
            }
        }
        return floats
    }
}

/// Merges ranked lists, as reciprocal rank fusion: each list adds 1/(60 + rank) for an item, so
/// items both lists rank well come first, and either list alone still counts.
public enum RankFusion {
    public static func fuse(_ lists: [[Int64]], k: Double = 60) -> [Int64] {
        var scores: [Int64: Double] = [:]
        var firstSeen: [Int64: Int] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() {
                scores[id, default: 0] += 1 / (k + Double(rank + 1))
                if firstSeen[id] == nil { firstSeen[id] = firstSeen.count }
            }
        }
        return scores.keys.sorted { scores[$0]! != scores[$1]! ? scores[$0]! > scores[$1]! : firstSeen[$0]! < firstSeen[$1]! }
    }
}
