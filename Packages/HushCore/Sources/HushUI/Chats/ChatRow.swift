import HushCore
import SwiftUI

struct ChatRow: View {
    let item: ChatItem
    let files: FileStore
    let list: ChatListKind
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(item: item, files: files, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.displayTitle)
                        .fontWeight(item.hasUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if item.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let date = item.lastActivity {
                        Text(ChatDate.short(date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .center, spacing: 4) {
                    preview
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    badges
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var preview: some View {
        if let draft = item.draft, !isSelected {
            Text("\(Text("Draft:").foregroundStyle(.red)) \(draft)")
        } else {
            Text(item.preview)
        }
    }

    @ViewBuilder private var badges: some View {
        if item.unreadMentionCount > 0 {
            badge("@")
        }
        if item.unreadBadge > 0 {
            badge(String(item.unreadBadge))
        } else if item.isPinned(in: list) {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(badgeColor, in: Capsule())
    }

    private var badgeColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white.opacity(0.3)) }
        return item.isMuted ? AnyShapeStyle(.gray) : AnyShapeStyle(.tint)
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
