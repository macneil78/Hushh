import HushCore
import SwiftUI

/// The scrolling list of messages, day headings and the unread divider.
struct MessageTimeline: View {
    let conversation: ConversationModel
    let files: FileStore
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isNearBottom = true
    @State private var isNearTop = false
    @State private var isPaging = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if conversation.hasOlderMessages, !conversation.isLoadingInitial {
                    Color.clear
                        .frame(height: 36)
                        .overlay {
                            if conversation.isLoadingOlder { ProgressView().controlSize(.small) }
                        }
                }
                ForEach(conversation.timeline) { item in
                    row(for: item)
                }
                // Telegram places a channel's sponsored message below its last post.
                if let ad = conversation.sponsoredAd, !conversation.isLoadingInitial {
                    SponsoredAdRow(ad: ad, conversation: conversation, files: files)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 150
        } action: { _, isNearBottom in
            self.isNearBottom = isNearBottom
        }
        // The scroll position decides when older history loads: only within 200 points of the top.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height > 0 && geometry.contentOffset.y + geometry.contentInsets.top < 200
        } action: { _, isNearTop in
            self.isNearTop = isNearTop
            if isNearTop { loadOlderWhileNearTop() }
        }
        .overlay {
            if conversation.isLoadingInitial && conversation.messages.isEmpty {
                ProgressView()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom {
                Button("Scroll to Latest", systemImage: "arrow.down") {
                    withAnimation { position.scrollTo(edge: .bottom) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .padding(10)
                .background(.regularMaterial, in: Circle())
                .padding(16)
            }
        }
        .onChange(of: conversation.isLoadingInitial, initial: true) { _, isLoading in
            // Open at the first unread message rather than the very bottom.
            if !isLoading, conversation.firstUnreadMessageId != nil {
                position.scrollTo(id: TimelineItem.unreadDivider.id, anchor: .top)
            }
        }
        .onChange(of: conversation.messages.last?.id) { previousLastId, _ in
            // Follow new messages if you're already at the bottom, or if you just sent one.
            // Not on the first load, which opens at the unread divider instead.
            guard previousLastId != nil else { return }
            if isNearBottom || conversation.messages.last?.isOutgoing == true {
                withAnimation { position.scrollTo(edge: .bottom) }
            }
        }
    }

    /// One page at a time, while you're near the top. At the very top the scroll view sticks to its
    /// top edge, so a new page would appear right where you're looking and trigger the next one.
    /// So when a page arrives while you're still up there, the message that was oldest goes back
    /// to the top of the window, in the same step as the page is added: the new page sits above,
    /// out of view, until you scroll up into it. If you've scrolled away meanwhile, nothing moves.
    /// A very short page can leave you near the top (a chat with little history); then it keeps
    /// going, but only while that's true.
    private func loadOlderWhileNearTop() {
        guard !isPaging else { return }
        isPaging = true
        Task {
            while isNearTop {
                let oldestShown = conversation.timeline.first { item in
                    switch item {
                    case .message, .album: true
                    case .day, .unreadDivider: false
                    }
                }?.id
                let loaded = await conversation.loadOlder {
                    if isNearTop, let oldestShown { position.scrollTo(id: oldestShown, anchor: .top) }
                }
                guard loaded else { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            isPaging = false
        }
    }

    @ViewBuilder private func row(for item: TimelineItem) -> some View {
        switch item {
        case .day(let date):
            DayHeading(date: date)
        case .unreadDivider:
            UnreadDivider()
        case .message(let message, let isFirstInGroup, let isLastInGroup):
            MessageRow(
                message: message,
                isFirstInGroup: isFirstInGroup,
                isLastInGroup: isLastInGroup,
                isGroup: conversation.isGroup,
                isRead: message.id <= conversation.lastReadOutboxMessageId,
                conversation: conversation,
                files: files
            )
            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                if isVisible {
                    conversation.messageAppeared(message.id)
                } else {
                    conversation.messageDisappeared(message.id)
                }
            }
        case .album(let messages, let isFirstInGroup, let isLastInGroup):
            AlbumRow(
                messages: messages,
                isFirstInGroup: isFirstInGroup,
                isLastInGroup: isLastInGroup,
                isGroup: conversation.isGroup,
                isRead: (messages.last?.id ?? 0) <= conversation.lastReadOutboxMessageId,
                conversation: conversation,
                files: files
            )
            .onScrollVisibilityChange(threshold: 0.3) { isVisible in
                for message in messages {
                    if isVisible {
                        conversation.messageAppeared(message.id)
                    } else {
                        conversation.messageDisappeared(message.id)
                    }
                }
            }
        }
    }
}

struct DayHeading: View {
    let date: Date

    var body: some View {
        Text(Self.label(for: date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    static func label(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: calendar.startOfDay(for: .now)).day ?? .max
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(date: .long, time: .omitted)
    }
}

struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            Text("Unread Messages")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .padding(.vertical, 10)
    }
}
