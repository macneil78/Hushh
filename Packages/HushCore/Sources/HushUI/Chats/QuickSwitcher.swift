import AppKit
import HushCore
import SwiftUI

/// ⌘K: type part of a name, ↑/↓ to choose, Enter to open, Esc to close.
struct QuickSwitcher: View {
    let chats: ChatStore
    let files: FileStore
    let onPick: (ChatItem) -> Void
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0

    /// Visible chats only, in Telegram's order. Names that start with what you typed come first,
    /// then names with a word that starts with it.
    private var results: [ChatItem] {
        let all = chats.mainList + chats.archiveList
        guard let match = NameMatch(query) else { return Array(all.prefix(Self.maxResults)) }
        return Array(match.ranked(all, name: \.displayTitle).prefix(Self.maxResults))
    }

    /// Room for the most results the switcher shows, so the sheet keeps its size (and the
    /// search field its place) while results come and go as you type.
    private static let maxResults = 10
    private static let rowHeight: CGFloat = 38
    private static let listHeight = CGFloat(maxResults) * rowHeight + CGFloat(maxResults - 1) * 2 + 16

    var body: some View {
        let results = results
        let details = ChatItem.details(tellingApart: results)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                SwitcherField(
                    text: $query,
                    onMove: { step in
                        guard !results.isEmpty else { return }
                        selection = min(max(selection + step, 0), results.count - 1)
                        // VoiceOver stays in the field, so say which chat is now chosen.
                        AccessibilityNotification.Announcement(results[selection].displayTitle).post()
                    },
                    onSubmit: {
                        if results.indices.contains(selection) { onPick(results[selection]) }
                    },
                    onCancel: onDismiss
                )
                .frame(height: 24)
            }
            .padding(12)
            Divider()
            Group {
                if results.isEmpty {
                    Text("No chats match.")
                        .foregroundStyle(.secondary)
                        .padding(24)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            row(item, detail: details[item.id], isSelected: index == selection)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.listHeight, maxHeight: Self.listHeight, alignment: .top)
        }
        .frame(width: 440)
        .onChange(of: query) { selection = 0 }
    }

    private func row(_ item: ChatItem, detail: String?, isSelected: Bool) -> some View {
        Button {
            onPick(item)
        } label: {
            HStack(spacing: 10) {
                AvatarView(item: item, files: files, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.displayTitle)
                        .lineLimit(1)
                    // Two chats with one name: say which is which.
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !item.isIn(.main) {
                    Text("Archived")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The switcher's search field. A plain NSTextField so ↑, ↓, Enter and Esc reach the switcher
/// instead of moving the text cursor.
struct SwitcherField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Switch to chat…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title3)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SwitcherField

        init(_ parent: SwitcherField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}
