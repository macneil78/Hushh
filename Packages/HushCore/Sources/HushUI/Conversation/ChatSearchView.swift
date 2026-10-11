import HushAI
import HushCore
import SwiftUI

/// ⌘F in a chat: finds messages by their words (Telegram's search, the whole history) and by
/// their meaning (on this Mac), in a panel over the top of the conversation. ↑/↓ choose, Enter
/// jumps to the message, Esc closes.
struct ChatSearchView: View {
    @Bindable var search: ChatSearch
    let conversation: ConversationModel
    let onClose: () -> Void
    @Environment(ModelStore.self) private var models
    @State private var selection = 0
    /// A result too far back to jump to, shown with the messages around it.
    @State private var context: Context?
    @FocusState private var isFocused: Bool

    private struct Context: Equatable {
        let messageId: Int64
        let messages: [MessageModel]
    }

    private var hasQuery: Bool {
        search.query.trimmingCharacters(in: .whitespaces).count >= 2
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if hasQuery {
                Divider()
                results
            }
            Divider()
            status
        }
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .onAppear { isFocused = true }
        .onChange(of: search.results) { selection = 0 }
        .onChange(of: models.state(of: .search)) { _, state in
            if state == .ready { search.start() }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search this chat", text: $search.query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { open(at: selection) }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(search.results.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }
            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if hasQuery {
                Text(search.results.isEmpty ? "No results" : "\(search.results.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Close Search", systemImage: "xmark.circle.fill", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var results: some View {
        if !search.results.isEmpty {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(search.results.enumerated()), id: \.element.id) { index, result in
                            row(result, isSelected: index == selection)
                                .id(result.id)
                                .onTapGesture {
                                    selection = index
                                    open(at: index)
                                }
                                .popover(isPresented: Binding(
                                    get: { context?.messageId == result.id },
                                    set: { if !$0 { context = nil } }
                                )) {
                                    if let context { ContextView(context: context.messages, highlighted: context.messageId) }
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) { _, index in
                    if search.results.indices.contains(index) { scroller.scrollTo(search.results[index].id) }
                }
            }
        }
    }

    private func row(_ result: ChatSearch.Result, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(result.message.isOutgoing ? "You" : result.message.sender.name)
                    .font(.caption.weight(.semibold))
                if result.matchesMeaning && !result.matchesWords {
                    Text("Similar meaning")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(MessagesStyle.outgoing)
                }
                Spacer()
                Text(result.message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(Self.snippet(for: result, query: search.query))
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch search.indexState {
            case .needsModel:
                switch models.state(of: .search) {
                case .missing, .failed:
                    Text("Also find messages by what they mean, on this Mac.")
                    Spacer()
                    Button("Download Search Model (\(AIModel.search.downloadSize.formatted(.byteCount(style: .file))))") {
                        models.download(.search)
                    }
                    .controlSize(.small)
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 80)
                    Text("Downloading the search model… \(Int(fraction * 100))%")
                case .preparing:
                    ProgressView().controlSize(.mini)
                    Text("Preparing the search model…")
                case .ready:
                    Text("Search by meaning is ready.")
                }
            case .indexing(let count):
                ProgressView().controlSize(.mini)
                Text("Reading this chat for search by meaning… \(count) messages so far")
            case .ready(let count):
                Image(systemName: "sparkles")
                Text("Words and meaning · \(count) messages")
            case .failed:
                Text("Search by meaning isn't available for this chat right now.")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func open(at index: Int) {
        guard search.results.indices.contains(index) else { return }
        let id = search.results[index].id
        Task {
            if !(await conversation.reveal(id)) {
                context = Context(messageId: id, messages: await conversation.context(around: id))
            }
        }
    }

    /// The message's text (or its transcript) with the searched words in bold.
    static func snippet(for result: ChatSearch.Result, query: String) -> AttributedString {
        var text: String
        switch result.message.body {
        case .voiceNote, .videoNote:
            text = result.message.transcript.map { "🎤 \($0)" } ?? result.message.previewText
        default:
            text = result.message.plainText.isEmpty ? result.message.previewText : result.message.plainText
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        var attributed = AttributedString(text)
        for word in query.split(whereSeparator: \.isWhitespace) where word.count >= 2 {
            var searchStart = attributed.startIndex
            while let range = attributed[searchStart...].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[range].inlinePresentationIntent = .stronglyEmphasized
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

/// A message too far back to jump to, with a few around it.
private struct ContextView: View {
    let context: [MessageModel]
    let highlighted: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Too far back to show in the chat")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(context) { message in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(message.isOutgoing ? "You" : message.sender.name) · \(message.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(message.previewText)
                        .font(.callout)
                        .fontWeight(message.id == highlighted ? .semibold : .regular)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}
