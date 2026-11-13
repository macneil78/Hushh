@preconcurrency import TDLibKit
import Foundation

/// Message text with its formatting, in a form views can render without knowing about TDLib.
public struct RichText: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case bold
        case italic
        case underline
        case strikethrough
        case code
        case pre
        case spoiler
        case quote
        case link(URL)
        /// @mentions, hashtags and bot commands: highlighted, not clickable.
        case mention
    }

    public struct Span: Equatable, Sendable {
        /// Offsets in UTF-16 code units, as Telegram counts them.
        public let range: Range<Int>
        public let style: Style
    }

    public var text: String
    public var spans: [Span]

    public init(text: String, spans: [Span] = []) {
        self.text = text
        self.spans = spans
    }

    public var isEmpty: Bool { text.isEmpty }

    public var hasSpoilers: Bool { spans.contains { $0.style == .spoiler } }

    /// Whether the text reads right to left: its first letter is Hebrew, Arabic or another
    /// right-to-left script, as Unicode's paragraph direction rule decides.
    public var isRightToLeft: Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return Self.rightToLeftBlocks.contains { $0.contains(scalar.value) }
        }
        return false
    }

    /// Hebrew, Arabic, Syriac, Thaana, N'Ko and the other right-to-left scripts, with their
    /// presentation forms.
    private static let rightToLeftBlocks: [ClosedRange<UInt32>] = [
        0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF,
    ]

    /// What stands in for a spoiler wherever it can't be hidden until clicked.
    public static let spoilerMask = "▒▒▒▒"

    /// The text with every spoiler replaced by `spoilerMask`, for the places that show text
    /// outside its bubble: the chat list, notifications, reply quotes and search results. The
    /// mask has a fixed length, so it doesn't give away how long the hidden words are.
    public var textHidingSpoilers: String {
        let hidden = spans.filter { $0.style == .spoiler }
            .compactMap(characterRange)
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !hidden.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        var masked = false
        for range in hidden {
            // Overlapping or touching spoilers share one mask.
            if !masked || range.lowerBound > cursor {
                result += text[cursor..<range.lowerBound]
                result += Self.spoilerMask
                masked = true
            }
            cursor = max(cursor, range.upperBound)
        }
        return result + text[cursor...]
    }

    /// Where a span lies in `text`, widened to whole characters: Telegram counts UTF-16 units, so
    /// a span can end between an emoji and its skin tone, or before a combining accent. Nil when
    /// the span lies outside the text.
    public func characterRange(of span: Span) -> Range<String.Index>? {
        let utf16 = text.utf16
        let lowerOffset = max(span.range.lowerBound, 0)
        let upperOffset = min(span.range.upperBound, utf16.count)
        guard lowerOffset < upperOffset else { return nil }
        var lower = utf16.index(utf16.startIndex, offsetBy: lowerOffset)
        var upper = utf16.index(lower, offsetBy: upperOffset - lowerOffset)
        while String.Index(lower, within: text) == nil { lower = utf16.index(before: lower) }
        while String.Index(upper, within: text) == nil { upper = utf16.index(after: upper) }
        return lower..<upper
    }

    /// Link schemes a click may open: the web, Telegram's own links, mail and phone numbers.
    /// Anything else (file:, smb:, javascript:, ssh:…) stays plain text, so a click can't open a
    /// local app or mount a stranger's file share.
    static let openableSchemes: Set<String> = ["http", "https", "tg", "mailto", "tel"]

    /// Whether some text in the message links to `url` without plainly naming it, as in
    /// "[https://bank.com](https://evil.example)" or "[click here](https://…)". Such a link asks
    /// before it opens, as in Telegram's own apps.
    public func hidesDestination(of url: URL) -> Bool {
        spans.contains { span in
            guard case .link(let target) = span.style, target == url,
                  let range = characterRange(of: span)
            else { return false }
            return !Self.names(url, visibleText: String(text[range]))
        }
    }

    /// Where the links that don't plainly name their destination go, in order.
    public var hiddenLinkDestinations: [URL] {
        var seen = Set<URL>()
        return spans.compactMap { span in
            guard case .link(let url) = span.style, hidesDestination(of: url), seen.insert(url).inserted else { return nil }
            return url
        }
    }

    /// Whether `visibleText` is the link's own address: the same site and path, give or take the
    /// scheme ("example.com/a" names https://example.com/a), letter case in the host and a
    /// trailing slash.
    static func names(_ url: URL, visibleText: String) -> Bool {
        let visible = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if visible == url.absoluteString { return true }
        if url.scheme?.lowercased() == "mailto" { return "mailto:\(visible)" == url.absoluteString }
        guard let shown = webURL(visible) else { return false }
        func parts(_ url: URL) -> [String?] {
            let scheme = url.scheme?.lowercased()
            let path = url.path(percentEncoded: true)
            return [
                scheme == "http" || scheme == "https" ? "web" : scheme,
                url.user(), url.password(), url.host(percentEncoded: true)?.lowercased(), url.port.map(String.init),
                path.hasSuffix("/") ? String(path.dropLast()) : path,
                url.query(percentEncoded: true), url.fragment(percentEncoded: true),
            ]
        }
        return parts(shown) == parts(url)
    }
}

extension RichText {
    init(_ formatted: FormattedText) {
        let text = formatted.text
        let length = text.utf16.count
        self.init(text: text, spans: formatted.entities.compactMap { entity in
            // TDLib never sends these, but one malformed entity must not crash the chat.
            guard entity.offset >= 0, entity.length > 0, entity.offset <= length - entity.length else { return nil }
            let range = entity.offset ..< entity.offset + entity.length
            let style: Style? = switch entity.type {
            case .textEntityTypeBold: .bold
            case .textEntityTypeItalic: .italic
            case .textEntityTypeUnderline: .underline
            case .textEntityTypeStrikethrough: .strikethrough
            case .textEntityTypeCode: .code
            case .textEntityTypePre, .textEntityTypePreCode: .pre
            case .textEntityTypeSpoiler: .spoiler
            case .textEntityTypeBlockQuote, .textEntityTypeExpandableBlockQuote: .quote
            case .textEntityTypeTextUrl(let link): Self.openable(URL(string: link.url)).map(Style.link)
            case .textEntityTypeUrl: Self.openable(Self.webURL(Self.substring(of: text, utf16: range))).map(Style.link)
            case .textEntityTypeEmailAddress:
                Self.substring(of: text, utf16: range).flatMap { URL(string: "mailto:\($0)") }.map(Style.link)
            case .textEntityTypeMention, .textEntityTypeMentionName, .textEntityTypeHashtag,
                 .textEntityTypeCashtag, .textEntityTypeBotCommand:
                .mention
            // Custom emoji already carry a plain emoji in the text, which is all Hush shows.
            default: nil
            }
            return style.map { Span(range: range, style: $0) }
        })
    }

    static func substring(of text: String, utf16 range: Range<Int>) -> String? {
        let utf16 = text.utf16
        guard
            range.lowerBound >= 0,
            let lower = utf16.index(utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex),
            let upper = utf16.index(lower, offsetBy: range.count, limitedBy: utf16.endIndex)
        else { return nil }
        return String(text[lower..<upper])
    }

    /// A bare link as typed: "example.com/a" opens as https://example.com/a. Only a scheme at the
    /// start counts, so "web.archive.org/web/2024/https://example.com" gets one too.
    static func webURL(_ text: String?) -> URL? {
        guard let text else { return nil }
        let hasScheme = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
        return URL(string: hasScheme ? text : "https://\(text)")
    }

    private static func openable(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), openableSchemes.contains(scheme) else { return nil }
        return url
    }
}
