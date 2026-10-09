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
}

extension RichText {
    init(_ formatted: FormattedText) {
        let text = formatted.text
        self.init(text: text, spans: formatted.entities.compactMap { entity in
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
            case .textEntityTypeTextUrl(let link): URL(string: link.url).map(Style.link)
            case .textEntityTypeUrl: Self.webURL(Self.substring(of: text, utf16: range)).map(Style.link)
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
            let lower = utf16.index(utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex),
            let upper = utf16.index(lower, offsetBy: range.count, limitedBy: utf16.endIndex)
        else { return nil }
        return String(text[lower..<upper])
    }

    private static func webURL(_ text: String?) -> URL? {
        guard let text else { return nil }
        return URL(string: text.contains("://") ? text : "https://\(text)")
    }
}
