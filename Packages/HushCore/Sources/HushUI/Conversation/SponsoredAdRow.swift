import AppKit
import HushCore
import SwiftUI

/// Telegram's sponsored message, below a channel's last post. Shown as Telegram's API terms
/// require: labelled, its view counted only once fully on screen, clicks reported, outside links
/// confirmed first, with Sponsor Info and Report in the right-click menu.
struct SponsoredAdRow: View {
    let ad: SponsoredAd
    let conversation: ConversationModel
    let files: FileStore
    @State private var linkToConfirm: URL?
    @State private var showsSponsorInfo = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let photo = ad.sponsorPhoto {
                RemoteImage(source: photo.image, minithumbnail: photo.minithumbnail, files: files)
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .onTapGesture { open(isMediaClick: false) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(ad.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(ad.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AccentPalette.color(for: ad.accentColorId))
                    .onTapGesture { open(isMediaClick: false) }
                content
                    // The view only counts once the whole text is visible.
                    .onScrollVisibilityChange(threshold: 0.99) { isVisible in
                        if isVisible { conversation.sponsoredAdBecameFullyVisible() }
                    }
                if !ad.buttonText.isEmpty {
                    Button { open(isMediaClick: false) } label: {
                        Text(ad.buttonText).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contextMenu {
                if ad.hasSponsorInfo {
                    Button("Sponsor Info") { showsSponsorInfo = true }
                }
                if ad.canBeReported {
                    Button("Report Ad…") { conversation.reportSponsoredAd() }
                }
            }
            Spacer(minLength: 80)
        }
        .padding(.top, 14)
        .confirmationDialog(
            "Open this link?",
            isPresented: Binding(get: { linkToConfirm != nil }, set: { if !$0 { linkToConfirm = nil } }),
            presenting: linkToConfirm
        ) { url in
            Button("Open") { NSWorkspace.shared.open(url) }
        } message: { url in
            Text(url.absoluteString)
        }
        .alert("Sponsor Info", isPresented: $showsSponsorInfo) {
            Button("OK") {}
        } message: {
            Text([ad.sponsorInfo, ad.additionalInfo].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
    }

    @ViewBuilder private var content: some View {
        switch ad.body {
        case .text(let text):
            adText(text)
        case .photo(let photo, let caption):
            RemoteImage(source: photo.image, minithumbnail: photo.minithumbnail, files: files)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture { open(isMediaClick: true) }
            if !caption.isEmpty { adText(caption) }
        case .video(let video, let caption):
            RemoteImage(source: video.thumbnail, minithumbnail: video.minithumbnail, files: files)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture { open(isMediaClick: true) }
            if !caption.isEmpty { adText(caption) }
        default:
            EmptyView()
        }
    }

    /// Links inside the ad count as clicks on it too.
    private func adText(_ text: RichText) -> some View {
        Text(AttributedString(text, onAccent: false, revealsSpoilers: true))
            .environment(\.openURL, OpenURLAction { url in
                conversation.sponsoredAdClicked(isMediaClick: false)
                if SponsoredAd.isTrusted(url.absoluteString) { return .systemAction }
                linkToConfirm = url
                return .handled
            })
    }

    private func open(isMediaClick: Bool) {
        conversation.sponsoredAdClicked(isMediaClick: isMediaClick)
        guard let url = URL(string: ad.url) else { return }
        if ad.opensWithoutConfirmation {
            NSWorkspace.shared.open(url)
        } else {
            linkToConfirm = url
        }
    }
}

/// Where the composer would be, in channels you can only read.
struct ChannelFooter: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Label("Only this channel's admins can post. You can read and react.", systemImage: "megaphone")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(14)
        }
    }
}
