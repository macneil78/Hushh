import HushCore
import SwiftUI

/// A voice message: play/pause, its waveform filling in as it plays (click to jump), and its length.
struct VoiceNoteView: View {
    let messageId: Int64
    let note: VoiceNoteMedia
    let isOutgoing: Bool
    let files: FileStore
    let voice: VoicePlayback
    let onPlay: (URL) -> Void

    private static let waveformWidth: CGFloat = 180

    var body: some View {
        let handle = files.handle(for: note.fileId)
        let isCurrent = voice.messageId == messageId
        HStack(spacing: 10) {
            Button {
                if let url = handle.localURL {
                    onPlay(url)
                } else {
                    files.download(note.fileId, priority: 32)
                }
            } label: {
                ZStack {
                    Circle().fill(isOutgoing ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(Color.accentColor))
                    if handle.localURL == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isCurrent && voice.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                WaveformBars(
                    levels: note.waveform,
                    progress: isCurrent ? voice.progress : 0,
                    tint: isOutgoing ? .white : .accentColor
                )
                .frame(width: Self.waveformWidth, height: 26)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if isCurrent { voice.seek(to: location.x / Self.waveformWidth) }
                }
                HStack(spacing: 5) {
                    Text(Duration.seconds(isCurrent ? voice.currentTime : Double(note.duration)).formatted(.time(pattern: .minuteSecond)))
                    if !isOutgoing, !note.isListened {
                        // Not played yet.
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
                .font(.caption.monospacedDigit())
                .opacity(0.75)
            }
        }
        .task(id: note.fileId) { files.download(note.fileId, priority: 2) }
    }
}

/// Bars from Telegram's waveform, the played part in full colour.
struct WaveformBars: View {
    let levels: [UInt8]
    let progress: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 2.5
            let gap: CGFloat = 1.5
            let count = max(1, Int((size.width + gap) / (barWidth + gap)))
            for index in 0 ..< count {
                let level = levels.isEmpty ? 0 : levels[index * levels.count / count]
                let height = max(2, CGFloat(level) / 31 * size.height)
                let bar = CGRect(x: CGFloat(index) * (barWidth + gap), y: (size.height - height) / 2, width: barWidth, height: height)
                let isPlayed = Double(index) / Double(count) < progress
                context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .color(tint.opacity(isPlayed ? 1 : 0.45)))
            }
        }
    }
}

/// Recording in progress: elapsed time, a live level meter, and Cancel (Esc) or Send (Enter).
struct RecordingBar: View {
    let recorder: VoiceRecorder
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Cancel Recording", systemImage: "trash", action: onCancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .keyboardShortcut(.cancelAction)
                .disabled(recorder.state != .recording)
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                .font(.body.monospacedDigit())
            Capsule()
                .fill(.red.opacity(0.6))
                .frame(width: 8 + 140 * recorder.level, height: 6)
                .animation(.linear(duration: 0.05), value: recorder.level)
            Spacer()
            if recorder.state == .encoding {
                ProgressView().controlSize(.small)
            }
            Button("Send Voice Message", systemImage: "arrow.up.circle.fill", action: onSend)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 26))
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.state != .recording)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Reactions under a message. Click one to add yours or take it back.
struct ReactionChips: View {
    let reactions: [Reaction]
    let onToggle: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    if case .emoji(let emoji) = reaction.kind { onToggle(emoji) }
                } label: {
                    HStack(spacing: 3) {
                        switch reaction.kind {
                        case .emoji(let emoji): Text(emoji)
                        case .customEmoji: Image(systemName: "face.smiling")
                        case .paid: Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        Text("\(reaction.count)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(reaction.isChosen ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.quaternary.opacity(0.7)), in: Capsule())
                    .overlay(Capsule().strokeBorder(reaction.isChosen ? Color.accentColor : .clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled({ if case .emoji = reaction.kind { false } else { true } }())
            }
        }
    }
}

/// The reactions a chat allows, to pick from.
struct ReactionPicker: View {
    let choices: [String]
    let chosen: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        if choices.isEmpty {
            Text("Reactions are off in this chat.")
                .foregroundStyle(.secondary)
                .padding(14)
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8), spacing: 4) {
                    ForEach(choices, id: \.self) { emoji in
                        Button { onPick(emoji) } label: {
                            Text(emoji)
                                .font(.title2)
                                .frame(width: 34, height: 34)
                                .background(chosen.contains(emoji) ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(width: 320, height: min(CGFloat((choices.count + 7) / 8) * 38 + 16, 240))
        }
    }
}
