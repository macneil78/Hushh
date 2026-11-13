import Foundation

/// How a typed query finds chat names, the same in ⌘K, the sidebar search and Choose Chats.
/// Case and accents don't count ("emile" finds "Émile"), and Cyrillic and Latin find each other
/// ("ivan" finds "Иван", "иван" finds "Ivan"), as in Telegram's own search.
struct NameMatch {
    /// How well a name matches, best first.
    enum Rank: Int, Comparable {
        /// The name starts with the query.
        case start
        /// A later word in the name starts with it ("smi" in "John Smith").
        case wordStart
        /// It's inside a word ("smi" in "Cosmic Club").
        case inside

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let queries: [String]

    /// Nil for a query that's empty once spaces are trimmed.
    init?(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        queries = Self.forms(of: query)
    }

    /// How well `name` matches, or nil if it doesn't.
    func rank(_ name: String) -> Rank? {
        var best: Rank?
        for form in Self.forms(of: name) {
            for query in queries {
                guard let rank = Self.rank(of: query, in: form) else { continue }
                best = min(best ?? rank, rank)
            }
        }
        return best
    }

    func matches(_ name: String) -> Bool {
        rank(name) != nil
    }

    /// The matching items, best match first; equally good ones keep their order.
    func ranked<Item>(_ items: [Item], name: (Item) -> String) -> [Item] {
        items.enumerated()
            .compactMap { index, item in rank(name(item)).map { (rank: $0, index: index, item: item) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.item)
    }

    // MARK: Comparing

    private static func rank(of query: String, in name: String) -> Rank? {
        guard var found = name.range(of: query) else { return nil }
        if found.lowerBound == name.startIndex { return .start }
        while true {
            let before = name[name.index(before: found.lowerBound)]
            if !before.isLetter, !before.isNumber { return .wordStart }
            guard let next = name.range(of: query, range: name.index(after: found.lowerBound)..<name.endIndex) else {
                return .inside
            }
            found = next
        }
    }

    /// The ways a name (or query) can be spelled for comparing: as typed without case and
    /// accents, and for other scripts also in Latin letters, once as people usually write
    /// Russian names ("Михаил" → "mikhail") and once letter by letter ("mihail").
    static func forms(of text: String) -> [String] {
        let lower = text.lowercased()
        var forms = [fold(lower)]
        guard lower.unicodeScalars.contains(where: { !$0.isASCII }) else { return forms }
        let common = lower.map { cyrillic[$0] ?? String($0) }.joined()
        for spelling in [common, lower] {
            let form = fold(latin(spelling))
            if !forms.contains(form) { forms.append(form) }
        }
        return forms
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func latin(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return text }
        return text.applyingTransform(.toLatin, reverse: false) ?? text
    }

    /// Russian, Ukrainian and Belarusian letters as Latin, the way names are usually written.
    private static let cyrillic: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh",
        "щ": "shch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g", "ў": "u",
    ]
}
