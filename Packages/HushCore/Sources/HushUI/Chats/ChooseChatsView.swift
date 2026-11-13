import HushCore
import SwiftUI

/// The "Choose Chats" sheet: groups, channels and bots, hidden until switched on one by one.
struct ChooseChatsView: View {
    let chats: ChatStore
    let files: FileStore
    /// In the sheet it has a Done button; in Settings it doesn't.
    var isSheet = true
    @State private var candidates: [ChatItem] = []
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [ChatItem] {
        guard let match = NameMatch(query) else { return candidates }
        return candidates.filter { match.matches($0.displayTitle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose Chats")
                    .font(.title2.weight(.semibold))
                Text("Hushh shows your one-on-one chats. Groups, channels and bots stay hidden unless you switch them on here. Large public channels include Telegram's sponsored messages.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isSheet {
                    Text("You can change this later in Settings → Chats.")
                        .foregroundStyle(.secondary)
                }
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 6)
            }
            .padding(20)

            if candidates.isEmpty {
                ContentUnavailableView("Nothing to Choose", systemImage: "person.3")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    section("Groups", kinds: [.group])
                    section("Channels", kinds: [.channel])
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
        // Rows don't reshuffle while you're choosing: chats that arrive later (a big first sync
        // is still coming in) join at the end of their section.
        .onAppear { candidates = chats.chatsToChoose() }
        .onChange(of: chats.choosableChatIds) {
            candidates = Self.adding(chats.chatsToChoose(), to: candidates)
        }
    }

    /// `shown` in its order, then whatever `latest` has that it doesn't. Nothing is taken away,
    /// so a person switched back on stays in the list until it closes.
    static func adding(_ latest: [ChatItem], to shown: [ChatItem]) -> [ChatItem] {
        let ids = Set(shown.map(\.id))
        return shown + latest.filter { !ids.contains($0.id) }
    }

    @ViewBuilder private func section(_ title: String, kinds: Set<ChatKind>) -> some View {
        let items = filtered.filter { kinds.contains($0.kind) }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        AvatarView(item: item, files: files, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.displayTitle)
                                .lineLimit(1)
                            if item.kind == .service {
                                // Hidden by default, like bots, but it's where they arrive.
                                Text("Login codes and alerts about new logins")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
