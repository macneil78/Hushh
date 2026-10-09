import HushCore
import SwiftUI

/// The "Choose Groups & Bots" sheet: everything hidden by default, opted in one by one.
struct ChooseChatsView: View {
    let chats: ChatStore
    let files: FileStore
    /// In the sheet it has a Done button; in Settings it doesn't.
    var isSheet = true
    @State private var candidates: [ChatItem] = []
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [ChatItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.displayTitle.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose Groups & Bots")
                    .font(.title2.weight(.semibold))
                Text("Hush shows your one-on-one chats. Groups and bots stay hidden unless you switch them on here. Channels never appear.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 6)
            }
            .padding(20)

            if candidates.isEmpty {
                ContentUnavailableView("No Groups or Bots", systemImage: "person.3")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    section("Groups", kinds: [.group])
                    section("Bots", kinds: [.bot, .service])
                    section("Hidden People", kinds: [.person, .savedMessages, .secret])
                }
            }

            if isSheet {
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
        .frame(width: isSheet ? 480 : nil, height: isSheet ? 620 : 480)
        // Computed once, so rows don't reshuffle while you're choosing.
        .onAppear { candidates = chats.chatsToChoose() }
    }

    @ViewBuilder private func section(_ title: String, kinds: Set<ChatKind>) -> some View {
        let items = filtered.filter { kinds.contains($0.kind) }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        AvatarView(item: item, files: files, size: 28)
                        Text(item.displayTitle)
                            .lineLimit(1)
                        Spacer()
                        Toggle("Show \(item.displayTitle)", isOn: Binding(
                            get: { chats.isShown(item) },
                            set: { chats.setShown($0, for: item) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
