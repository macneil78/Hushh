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
        guard !isLaughter(text) else { return false }
        // Chinese and Japanese put no spaces between words, and one character carries about as
        // much as a short word: "记得买牛奶" ("remember to buy milk") is a whole message.
        if text.unicodeScalars.count(where: isWordlessScript) >= 4 { return true }
        let words = text.split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 2 }
        let letters = words.reduce(0) { $0 + $1.count }
        return (words.count >= 2 && letters >= 6) || letters >= 12
    }

    /// A short fingerprint of the text a vector was made from, kept with it in the index: when a
    /// message's text no longer matches, it was edited and its vector is out of date. Stable
    /// across launches (FNV-1a), unlike Swift's `Hasher`. Never 0, which means "not known".
    public static func fingerprint(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }

    /// What the index makes a vector from: a message's words, cut to a length the model reads.
    static func indexed(_ message: MessageModel) -> String {
        String(of(message).prefix(1000))
    }

    /// Han characters and kana: scripts written without spaces between words.
    public static func isWordlessScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: true  // hiragana, katakana
        default: scalar.properties.isIdeographic
        }
    }

    /// "ахахах", "хехе", "hahaha", "哈哈哈".
    private static func isLaughter(_ text: String) -> Bool {
        let letters = Set(text.lowercased().filter(\.isLetter))
        return !letters.isEmpty && letters.isSubset(of: ["а", "х", "е", "ы", "h", "a", "e", "x", "哈", "呵", "嘻"])
    }
}

/// When a message counts as close in meaning to a query.
///
/// e5 puts almost every pair of texts at a cosine of 0.75 to 0.90, and short, empty messages
/// ("ок, договорились", a link) close to every query. So a fixed cut-off either lets through
/// nearly everything or nothing. Instead:
/// - Only queries with something to mean are searched by meaning ("the", "и", "xx" and "123"
///   are left to word search).
/// - Each score has the message's closeness to queries in general taken off: that is the score
///   against `genericWeight` times the mean of `referenceQueries`. Chatter, close to every
///   query, drops; a message about the query's subject keeps its lead.
/// - A message counts when it is among the best `limit`, and stands out from the chat's other
///   messages (`minimumZ` standard deviations above their mean) or scores `minimumScore` or
///   more, for chats too small to stand out in.
///
/// The numbers are calibrated on about 250 messages and 125 queries in six languages (see
/// FixAISearchCalibrationTests): of the meaning results shown, 86% are right, against 10%
/// with the old rule (a floor of 0.80 within 0.05 of the best).
public enum MeaningMatch {
    static let genericWeight: Float = 0.75
    static let minimumZ: Float = 3.5
    static let minimumScore: Float = 0.27
    static let limit = 3

    /// Things people look for in chats, in several languages. Their mean is what a query in
    /// general looks like to the model.
    static let referenceQueries = [
        "address", "phone", "password", "meeting", "dinner", "money", "payment", "doctor", "flight", "hotel",
        "birthday", "party", "photos", "document", "link", "schedule", "weekend", "work", "school", "holiday",
        "адрес", "телефон", "деньги", "встреча", "врач", "работа", "фото", "документы", "выходные", "праздник",
        "dirección", "dinero", "trabajo", "fiesta", "médico", "Termin", "Geld", "Arbeit", "Urlaub", "Adresse",
        "住所", "電話", "仕事", "お金", "予定", "地址", "工作", "钱", "电话", "周末",
        "where to buy tickets", "how much did it cost", "who is coming tonight", "what time does it start",
        "send me the file", "when will you be back", "сколько стоит", "кто придёт", "во сколько начало", "скинь файл",
    ]

    /// Whether a query has anything to search for by meaning: a word of three letters or more
    /// that isn't one of the most common little words, a Chinese or Japanese character, or an
    /// emoji.
    public static func isWorthSearching(_ query: String) -> Bool {
        if query.unicodeScalars.contains(where: { SearchText.isWordlessScript($0) || $0.properties.isEmojiPresentation }) {
            return true
        }
        return query.lowercased()
            .split { !$0.isLetter }
            .contains { $0.count >= 3 && !littleWords.contains(String($0)) }
    }

    /// Words that carry no subject, in the languages the model knows best (two-letter words are
    /// left out by length).
    static let littleWords: Set<String> = Set("""
        the and for but not you are was were its this that these those what who how why when where which
        yes our they she his her does did have has had can will just all any some there here then than
        about get got with from into out
        что как все всё она так его только мне было вот меня еще ещё нет теперь когда даже если уже или
        быть был него вас вам ведь там потом себя может они тут где есть надо ней для тебя чем была сам
        чтоб без чего раз тоже себе под будет тогда кто этот того потому этого какой ним здесь этом мой
        тем чтобы нее сейчас были куда зачем всех можно при хоть после над тот через эти нас про всего
        них какая много эту моя свою этой перед том такой всю это эта
        que los del las por para con una como más mas pero sus este porque esta entre cuando muy sin
        sobre también hasta hay donde quien desde todo nos uno les ese eso esto antes unos otro qué
        der die das und den von mit sich des auf für ist dem nicht ein eine als auch aus hat dass sie
        nach wird bei einer sind noch wie einem über einen zum war haben nur oder aber vor zur bis mehr
        durch man dann was wer wann ich wir ihr
        les des une est qui dans pour pas sur avec elle nous vous par plus mais quoi
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}

/// A chat's messages as vectors, for search by meaning. Kept in the account's vault.
public struct SemanticIndex: Sendable {
    public static let dimensions = TextEmbedder.dimensions

    private(set) var ids: [Int64] = []
    /// `ids.count` rows of `dimensions` numbers, each row unit length.
    private(set) var vectors: [Float] = []
    /// Each row's text fingerprint (`SearchText.fingerprint`), 0 when not known.
    private(set) var fingerprints: [UInt32] = []
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
    /// Messages newer than the index that a catch-up hasn't read yet: those before `from` and
    /// after `stop`. A catch-up raises `newestSeen` with its first page, so without this a
    /// search closed half-way (or an error) would leave them out for good.
    public var gap: Gap?

    public struct Gap: Equatable, Sendable {
        public var from: Int64
        public var stop: Int64
    }

    public init() {}

    public var count: Int { ids.count }

    public func contains(_ id: Int64) -> Bool {
        rows[id] != nil
    }

    public mutating func add(_ id: Int64, vector: [Float], fingerprint: UInt32 = 0) {
        precondition(vector.count == Self.dimensions)
        if let row = rows[id] {
            vectors.replaceSubrange(row * Self.dimensions ..< (row + 1) * Self.dimensions, with: vector)
            fingerprints[row] = fingerprint
        } else {
            rows[id] = ids.count
            ids.append(id)
            vectors.append(contentsOf: vector)
            fingerprints.append(fingerprint)
        }
    }

    /// The fingerprint of the text a message's vector was made from: nil when it isn't indexed,
    /// 0 when not known (indexed before fingerprints were kept).
    public func fingerprint(of id: Int64) -> UInt32? {
        rows[id].map { fingerprints[$0] }
    }

    public mutating func remove(_ removed: Set<Int64>) {
        guard ids.contains(where: removed.contains) else { return }
        var keptIds: [Int64] = []
        var keptVectors: [Float] = []
        var keptFingerprints: [UInt32] = []
        for (row, id) in ids.enumerated() where !removed.contains(id) {
            keptIds.append(id)
            keptVectors.append(contentsOf: vectors[row * Self.dimensions ..< (row + 1) * Self.dimensions])
            keptFingerprints.append(fingerprints[row])
        }
        ids = keptIds
        vectors = keptVectors
        fingerprints = keptFingerprints
        rows = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    }

    /// The closest messages to a query vector, best first, with their cosine similarity.
    public func search(_ query: [Float], limit: Int) -> [(id: Int64, score: Float)] {
        let scores = scores(query)
        return scores.indices
            .sorted { scores[$0] > scores[$1] }
            .prefix(limit)
            .map { (ids[$0], scores[$0]) }
    }

    /// The messages close in meaning to a query, best first, by `MeaningMatch`'s rule. `generic`
    /// is the mean of the reference queries' vectors.
    public func meaningMatches(_ query: [Float], generic: [Float]) -> [Int64] {
        guard query.count == Self.dimensions, generic.count == Self.dimensions else { return [] }
        // Taking the generic query off the query takes each message's closeness to queries in
        // general off its score, in the same one product.
        let adjusted = zip(query, generic).map { $0 - MeaningMatch.genericWeight * $1 }
        let scores = scores(adjusted)
        guard !scores.isEmpty else { return [] }
        let mean = vDSP.mean(scores)
        let deviation = sqrt(vDSP.meanSquare(vDSP.add(-mean, scores)))
        return scores.indices
            .sorted { scores[$0] > scores[$1] }
            .prefix(MeaningMatch.limit)
            .filter { row in
                let standsOut = deviation > 0 && (scores[row] - mean) / deviation >= MeaningMatch.minimumZ
                return standsOut || scores[row] >= MeaningMatch.minimumScore
            }
            .map { ids[$0] }
    }

    /// Every row against a vector, in one matrix-vector product.
    private func scores(_ query: [Float]) -> [Float] {
        guard !ids.isEmpty, query.count == Self.dimensions else { return [] }
        var scores = [Float](repeating: 0, count: ids.count)
        vDSP_mmul(vectors, 1, query, 1, &scores, 1, vDSP_Length(ids.count), 1, vDSP_Length(Self.dimensions))
        return scores
    }

    // MARK: Saving

    /// HSI2 adds the text fingerprints and the catch-up gap to HSI1; HSI1 files still load.
    private static let magic = Data("HSI2".utf8)
    private static let magicV1 = Data("HSI1".utf8)
    private static let headerSizeV1 = 4 + 4 + 4 + 8 + 8 + 4 + 1
    private static let headerSize = headerSizeV1 + 8 + 8

    /// Vectors are stored as half floats: half the size, and plenty for ranking. Arrays are
    /// copied as they are in memory; every Mac is little-endian.
    public func serialized() -> Data {
        var data = Data(capacity: Self.headerSize + ids.count * 12 + vectors.count * 2)
        data.append(Self.magic)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(UInt32(Self.dimensions))
        append(UInt32(ids.count))
        append(newestSeen)
        append(oldestSeen)
        append(UInt32(seenCount))
        append(UInt8(isComplete ? 1 : 0))
        append(gap?.from ?? 0)
        append(gap?.stop ?? 0)
        ids.withUnsafeBytes { data.append(contentsOf: $0) }
        fingerprints.withUnsafeBytes { data.append(contentsOf: $0) }
        Self.halfFloats(from: vectors).withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public init?(serialized data: Data) {
        let isV1 = data.prefix(4) == Self.magicV1
        guard isV1 || data.prefix(4) == Self.magic else { return nil }
        let headerSize = isV1 ? Self.headerSizeV1 : Self.headerSize
        guard data.count >= headerSize else { return nil }
        func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        guard read(UInt32.self, at: 4) == UInt32(Self.dimensions) else { return nil }
        let count = Int(read(UInt32.self, at: 8))
        let fingerprintSize = isV1 ? 0 : count * 4
        guard data.count == headerSize + count * 8 + fingerprintSize + count * Self.dimensions * 2 else { return nil }
        newestSeen = read(Int64.self, at: 12)
        oldestSeen = read(Int64.self, at: 20)
        seenCount = Int(read(UInt32.self, at: 28))
        isComplete = read(UInt8.self, at: 32) == 1
        if !isV1 {
            let from = read(Int64.self, at: 33), stop = read(Int64.self, at: 41)
            gap = from == 0 ? nil : Gap(from: from, stop: stop)
        }
        let fingerprintStart = headerSize + count * 8
        let vectorStart = fingerprintStart + fingerprintSize
        var ids = [Int64](repeating: 0, count: count)
        var fingerprints = [UInt32](repeating: 0, count: count)
        var halves = [UInt16](repeating: 0, count: count * Self.dimensions)
        data.withUnsafeBytes { raw in
            ids.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[headerSize..<fingerprintStart])) }
            if !isV1 {
                fingerprints.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[fingerprintStart..<vectorStart])) }
            }
            halves.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[vectorStart...])) }
        }
        self.ids = ids
        self.fingerprints = fingerprints
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
