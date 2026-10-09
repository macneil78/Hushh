@preconcurrency import TDLibKit
import Foundation

/// A sponsored message Telegram places below the last post of large public channels. Clients
/// that show channels must show these (Telegram API terms §3.3), following
/// https://core.telegram.org/api/sponsored-messages.
public struct SponsoredAd: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let body: MessageModel.Body
    public let buttonText: String
    public let url: String
    /// Telegram's own recommendation rather than a paid ad; labelled accordingly.
    public let isRecommended: Bool
    public let canBeReported: Bool
    /// Who's behind the ad, shown under "Sponsor Info".
    public let sponsorInfo: String
    public let additionalInfo: String
    public let accentColorId: Int
    public let sponsorPhoto: PhotoMedia?

    public var label: String { isRecommended ? "Recommended" : "Sponsored" }

    public var hasSponsorInfo: Bool { !sponsorInfo.isEmpty || !additionalInfo.isEmpty }

    /// Links to Telegram's own sites open straight away; anything else asks first.
    public var opensWithoutConfirmation: Bool { Self.isTrusted(url) }

    static let trustedDomains = [
        "telegram.org", "t.me", "telegram.me", "telegram.dog", "telegra.ph", "graph.org", "fragment.com", "telesco.pe",
    ]

    /// Whether a link goes to one of Telegram's own sites.
    public static func isTrusted(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host()?.lowercased() else { return false }
        return trustedDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

extension SponsoredAd {
    init?(_ message: SponsoredMessage) {
        guard let body = MessageMapper.body(
            for: message.content, isOutgoing: false, senderId: 0, senderName: message.title, name: { _ in "" }
        ) else { return nil }
        self.init(
            id: message.messageId,
            title: message.title,
            body: body,
            buttonText: message.buttonText,
            url: message.sponsor.url,
            isRecommended: message.isRecommended,
            canBeReported: message.canBeReported,
            sponsorInfo: message.sponsor.info,
            additionalInfo: message.additionalInfo,
            accentColorId: message.accentColorId,
            sponsorPhoto: message.sponsor.photo.flatMap(MediaMapping.photo)
        )
    }
}

/// Reporting an ad: Telegram asks why, one choice at a time.
public struct SponsoredReport: Equatable, Sendable {
    public struct Option: Identifiable, Equatable, Sendable {
        public let id: Data
        public let text: String
    }

    public let title: String
    public let options: [Option]
}
