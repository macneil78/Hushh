import HushCore
import SwiftUI

/// A chat in the sidebar, as Messages lists conversations: picture, bold name, date, and two lines
/// of the latest message; a blue dot when there's something unread.
struct ChatRow: View {
    let item: ChatItem
    let files: FileStore
    let list: ChatListKind
    let isSelected: Bool

    var body: some View {
        ChatRowLayout(
            title: item.displayTitle,
            preview: preview,
            date: item.lastActivity.map { ChatDate.short($0) },
            unread: unread,
            isMuted: item.isMuted,
            isPinned: item.isPinned(in: list),
            isChannel: item.kind == .channel
        ) {
            AvatarView(item: item, files: files, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if item.presence?.isOnline() == true { OnlineDot() }
                }
        }
    }

    private var preview: Text {
        if let draft = item.draft, !isSelected {
            return Text("\(Text("Draft:").foregroundStyle(.red)) \(draft)")
        }
        return Text(item.preview)
    }

    private var unread: ChatUnread? {
        if item.unreadMentionCount > 0 { return .mention }
        guard item.hasUnread else { return nil }
        return item.isMuted ? .muted : .unread
    }
}

/// What a chat's unread dot says.
enum ChatUnread {
    case unread
    /// Unread, but in a muted chat.
    case muted
    /// Someone mentioned or replied to you.
    case mention
}

/// A chat row's look, from plain values (the design preview draws it with made-up chats).
struct ChatRowLayout<Picture: View>: View {
    let title: String
    let preview: Text
    let date: String?
    let unread: ChatUnread?
    let isMuted: Bool
    let isPinned: Bool
    let isChannel: Bool
    @ViewBuilder let picture: Picture

    var body: some View {
        HStack(spacing: 7) {
            UnreadDot(unread: unread)
            picture
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if isChannel {
                        Image(systemName: "megaphone.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let date {
                        Text(date)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                preview
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .padding(.vertical, 5)
    }
}

/// Messages marks unread conversations with a blue dot beside the picture.
struct UnreadDot: View {
    let unread: ChatUnread?

    var body: some View {
        Group {
            switch unread {
            case .unread:
                Circle().fill(MessagesStyle.outgoing).frame(width: 10, height: 10)
            case .muted:
                Circle().fill(.secondary).frame(width: 10, height: 10)
            case .mention:
                Text("@")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(MessagesStyle.outgoing, in: Circle())
            case nil:
                Color.clear.frame(width: 10, height: 10)
            }
        }
        .frame(width: 14)
    }
}

struct OnlineDot: View {
    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            .offset(x: 1, y: 1)
    }
}

enum ChatDate {
    /// Time for today, weekday within the last week, otherwise the date.
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
        if days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
