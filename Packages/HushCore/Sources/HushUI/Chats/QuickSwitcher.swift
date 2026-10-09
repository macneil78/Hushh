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

    /// Visible chats only, in Telegram's order. Names that start with what you typed come first.
    private var results: [ChatItem] {
        let all = chats.mainList + chats.archiveList
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(all.prefix(10)) }
        let matches = all.filter { $0.displayTitle.localizedStandardContains(query) }
        let starts = matches.filter { $0.displayTitle.lowercased().hasPrefix(query.lowercased()) }
        let others = matches.filter { !$0.displayTitle.lowercased().hasPrefix(query.lowercased()) }
        return Array((starts + others).prefix(10))
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                SwitcherField(
                    text: $query,
                    onMove: { step in
                        guard !results.isEmpty else { return }
                        selection = min(max(selection + step, 0), results.count - 1)
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
            if results.isEmpty {
                Text("No chats match.")
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            AvatarView(item: item, files: files, size: 26)
                            Text(item.displayTitle)
                                .lineLimit(1)
                            Spacer()
                            if !item.isIn(.main) {
                                Text("Archived")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            index == selection ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(item) }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 440)
        .onChange(of: query) { selection = 0 }
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
