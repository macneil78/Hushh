import HushCore
import SwiftUI

/// A voice message: play/pause, its waveform filling in as it plays (click to jump), and its length.
struct VoiceNoteView: View {
    let messageId: Int64
    let note: VoiceNoteMedia
    /// Drawn for a blue bubble.
    let isOutgoing: Bool
    let files: FileStore
    let voice: VoicePlayback
    let onPlay: (URL) -> Void
    /// Whether you sent it, where that differs from how it's drawn (Chat Info lists every
    /// message without bubbles). Your own messages never show the "not played" dot.
    var isOwnMessage: Bool?
    @Environment(\.conversation) private var conversation

    private static let waveformWidth: CGFloat = 180

    /// Message ids repeat across chats, so playback is matched on both.
    private var key: VoicePlayback.Key {
        VoicePlayback.Key(chatId: conversation?.chatId ?? 0, messageId: messageId)
    }

    private var isUnplayed: Bool {
        !(isOwnMessage ?? isOutgoing) && !note.isListened
    }

    var body: some View {
        let handle = files.handle(for: note.fileId)
        let isCurrent = voice.current == key
        let shownTime = isCurrent ? voice.currentTime : Double(note.duration)
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
                    if handle.isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        // Not on this Mac and not on its way (a download failed): click to fetch it.
                        Image(systemName: handle.localURL == nil ? "arrow.down" : isCurrent && voice.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playLabel(handle: handle, isCurrent: isCurrent))
            .accessibilityValue(isUnplayed ? "Not played" : "")

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
                .accessibilityElement()
                .accessibilityLabel("Position")
                .accessibilityValue(isCurrent
                    ? "\(MediaDuration.spoken(voice.currentTime)) of \(MediaDuration.spoken(voice.duration))"
                    : MediaDuration.spoken(Double(note.duration)))
                .accessibilityAdjustableAction { direction in
                    guard isCurrent, voice.duration > 0 else { return }
                    let step = 5 / voice.duration
                    voice.seek(to: voice.progress + (direction == .increment ? step : -step))
                }
                .accessibilityHidden(!isCurrent)
                HStack(spacing: 5) {
                    Text(MediaDuration.text(shownTime))
                    if isUnplayed {
                        // Not played yet.
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
                .font(.caption.monospacedDigit())
                .opacity(0.75)
                .accessibilityHidden(true)  // the play button says it
            }
        }
        .task(id: note.fileId) { files.download(note.fileId, priority: 2) }
    }

    private func playLabel(handle: HushCore.FileHandle, isCurrent: Bool) -> String {
        let length = MediaDuration.spoken(Double(note.duration))
        if handle.isDownloading { return "Voice message, \(length), downloading" }
        if handle.localURL == nil { return "Download voice message, \(length)" }
        return isCurrent && voice.isPlaying ? "Pause voice message" : "Play voice message, \(length)"
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

/// Recording in progress: elapsed time, a live level meter, Cancel (Esc) and Send (the button or
/// ⌘R). Return is left to the message box below, so it never sends a recording by surprise.
/// While macOS asks for the microphone, it says so, and only Cancel works.
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
                .disabled(recorder.state != .recording && recorder.state != .waitingForPermission)
            if recorder.state == .waitingForPermission {
                Text("Waiting for microphone access…")
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.body.monospacedDigit())
                Capsule()
                    .fill(.red.opacity(0.6))
                    .frame(width: 8 + 140 * recorder.level, height: 6)
                    .animation(.linear(duration: 0.05), value: recorder.level)
            }
            Spacer()
            if recorder.state == .encoding {
                ProgressView().controlSize(.small)
            }
            Button("Send Voice Message", systemImage: "arrow.up.circle.fill", action: onSend)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 26))
                .disabled(recorder.state != .recording)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}
