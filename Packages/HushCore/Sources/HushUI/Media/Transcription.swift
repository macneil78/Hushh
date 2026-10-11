import HushAI
import HushCore
import SwiftUI

extension EnvironmentValues {
    /// The open chat, for controls deep inside its messages (transcription).
    @Entry var conversation: ConversationModel?
    /// The signed-in account's encrypted store for search indexes.
    @Entry var vault: LocalVault?
}

/// Asks Telegram to transcribe a voice message or circle, as its own apps do. Gone once there's
/// text.
struct TranscribeButton: View {
    let message: MessageModel
    /// On a blue bubble.
    var onAccent = false
    @Environment(\.conversation) private var conversation

    private var isWorking: Bool {
        if case .pending = message.transcription { return true }
        return conversation?.requestedTranscriptions.contains(message.id) == true
    }

    private var hasText: Bool {
        if case .done = message.transcription { return true }
        return false
    }

    var body: some View {
        if let conversation, !hasText {
            Button { conversation.transcribe(message) } label: {
                ZStack {
                    if isWorking {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 26, height: 26)
                .background(onAccent ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.quaternary), in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Transcribe")
            .disabled(isWorking)
        }
    }
}

/// A voice message's or circle's transcript from Telegram: the text so far while it works, then
/// the whole of it, or why it couldn't.
struct TranscriptText: View {
    let message: MessageModel
    /// Circles have no bubble of their own, so their transcript gets one.
    var inBubble = false
    @Environment(\.conversation) private var conversation

    var body: some View {
        if let text = text {
            text
                .frame(maxWidth: 260, alignment: .leading)
                .padding(inBubble ? 10 : 0)
                .background(inBubble ? AnyShapeStyle(MessagesStyle.incoming) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var text: AnyView? {
        switch message.transcription {
        case .pending(let partial):
            AnyView(Text(partial.isEmpty ? "Transcribing…" : "\(partial)…")
                .font(.callout)
                .opacity(0.7)
                .fixedSize(horizontal: false, vertical: true))
        case .done(let transcript):
            AnyView(Text(transcript.isEmpty ? "No speech" : transcript)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true))
        case .failed(let reason):
            AnyView(Text(reason).font(.caption).opacity(0.7).fixedSize(horizontal: false, vertical: true))
        case nil:
            conversation?.transcriptionErrors[message.id].map {
                AnyView(Text($0).font(.caption).opacity(0.7).fixedSize(horizontal: false, vertical: true))
            }
        }
    }
}
