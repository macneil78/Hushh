import AppKit
import HushCore
import SwiftUI
import UniformTypeIdentifiers

/// Where you write, as in Messages: a + button for photos, files, stickers and voice, and a
/// glass message field floating over the conversation. Replies, edits and attachments show inside
/// the field. Enter sends, Shift+Enter starts a new line, ↑ edits your last message, Tab moves
/// to the next control (⌥Tab types a tab). Esc closes the sticker picker, drops a recording,
/// an edit, a reply or attachments, and closes the chat only when the box is empty. ⌘R records
/// a voice message; the recording shows above the box, which keeps what you type. Files can
/// also be pasted or dropped onto the conversation.
struct ComposerView: View {
    @Bindable var conversation: ConversationModel
    let stickers: StickerLibrary
    let files: FileStore
    /// Esc with nothing to cancel and nothing typed closes the chat.
    var onClose: () -> Void = {}
    @State private var editorHeight: CGFloat = 30
    @State private var isPickingFiles = false
    @State private var isPickingSticker = false

    private var isEditing: Bool { conversation.editing != nil }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if conversation.recorder.state == .idle {
                plusButton
            }
            VStack(alignment: .leading, spacing: 0) {
                if let editing = conversation.editing {
                    ComposerContextBar(title: "Editing message", text: editing.previewText, onCancel: conversation.cancelEditing)
                } else if let reply = conversation.replyingTo {
                    ComposerContextBar(
                        title: "Replying to \(reply.isOutgoing ? "yourself" : reply.sender.name)",
                        text: reply.previewText,
                        onCancel: conversation.cancelReply
                    )
                }
                if !conversation.attachments.isEmpty {
                    AttachmentStrip(attachments: conversation.attachments, onRemove: conversation.removeAttachment)
                }
                if conversation.recorder.state != .idle {
                    RecordingBar(recorder: conversation.recorder, onCancel: conversation.cancelRecording, onSend: conversation.finishRecording)
                }
                textRow
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// Photos and files, stickers and GIFs, a voice message.
    private var plusButton: some View {
        Menu {
            Button("Photos and Files…", systemImage: "photo.on.rectangle") { isPickingFiles = true }
            Button("Stickers and GIFs", systemImage: "face.smiling") { isPickingSticker = true }
            Button("Voice Message", systemImage: "waveform", action: conversation.startRecording)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Add photos, files, stickers or a voice message")
        .disabled(isEditing)
        .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { conversation.attach(urls) }
        }
    }

    private var stickerButton: some View {
        Button("Stickers and GIFs", systemImage: "face.smiling") { isPickingSticker.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .help("Stickers and GIFs")
            .disabled(isEditing)
            .popover(isPresented: $isPickingSticker, arrowEdge: .top) {
            StickerPicker(
                library: stickers,
                files: files,
                onSticker: { sticker in
                    isPickingSticker = false
                    conversation.sendSticker(sticker)
                },
                onGIF: { gif in
                    isPickingSticker = false
                    conversation.sendGIF(gif)
                }
            )
        }
    }

    private var textRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ComposerTextView(
                text: $conversation.composerText,
                height: $editorHeight,
                focusRequest: conversation.focusRequest,
                onSubmit: conversation.send,
                onUpArrowInEmptyComposer: conversation.editLastMessage,
                onEscape: {
                    if isPickingSticker {
                        isPickingSticker = false
                    } else if !conversation.cancelComposerMode(),
                              conversation.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onClose()
                    }
                    return true
                },
                onTextChange: conversation.composerChanged,
                onPasteFiles: { conversation.attach($0) },
                placeholder: placeholder
            )
            .frame(height: min(max(editorHeight, 30), 180))
            .overlay(alignment: .topLeading) {
                if conversation.composerText.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 9)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            stickerButton
                .padding(.bottom, 3)
            trailingButton
                .padding(.bottom, 3)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 1)
    }

    private var placeholder: String {
        conversation.attachments.isEmpty ? "Message" : "Add a caption"
    }

    /// Send once there's something to send; until then, record a voice message.
    @ViewBuilder private var trailingButton: some View {
        if conversation.canSend || isEditing {
            Button(isEditing ? "Save" : "Send", systemImage: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill") {
                conversation.send()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 22))
            .foregroundStyle(MessagesStyle.outgoing)
            .disabled(!conversation.canSend)
        } else if conversation.recorder.state == .idle {
            Button("Record Voice Message", systemImage: "waveform", action: conversation.startRecording)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }
}

/// Files waiting to be sent, each removable.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    let onRemove: (Attachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        preview(of: attachment)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(attachment.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                        Button("Remove \(attachment.name)", systemImage: "xmark.circle.fill") { onRemove(attachment) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func preview(of attachment: Attachment) -> some View {
        if attachment.kind == .photo {
            LocalImage(url: attachment.url, maxPixelSize: 72) {
                Rectangle().fill(.quaternary)
            }
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                .resizable()
        }
    }
}

struct ComposerContextBar: View {
    let title: String
    let text: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel", systemImage: "xmark", action: onCancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

/// A plain-text NSTextView. SwiftUI's TextEditor can't reliably tell Enter from Shift+Enter or
/// hand over ↑ and Esc, which a chat composer needs.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    /// Takes keyboard focus whenever this changes.
    let focusRequest: Int
    let onSubmit: () -> Void
    let onUpArrowInEmptyComposer: () -> Bool
    let onEscape: () -> Bool
    let onTextChange: () -> Void
    /// Pasting files or an image attaches them instead of inserting text.
    let onPasteFiles: ([URL]) -> Void
    /// What VoiceOver reads for the empty box.
    var placeholder = "Message"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.setAccessibilityLabel("Message")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        textView.onPasteFiles = onPasteFiles
        textView.setAccessibilityPlaceholderValue(placeholder)
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            // The typing on the undo stack refers to text that's gone now (sent, or swapped for an
            // edit or a draft); undoing it would raise an exception.
            context.coordinator.undoManager.removeAllActions()
        }
        // Measure after SwiftUI finishes this update; changing state during it isn't allowed.
        DispatchQueue.main.async { context.coordinator.measure(textView) }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusRequest = Int.min
        /// The box's own undo history, separate from the window's, so it can be cleared.
        let undoManager = UndoManager()

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            measure(textView)
            parent.onTextChange()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)):
                // ⌃↩: a plain new line, not a Unicode line separator.
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab moves on, as in every other field; ⌥Tab still types a tab.
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                return textView.string.isEmpty && parent.onUpArrowInEmptyComposer()
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            default:
                return false
            }
        }

        func measure(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let height = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
            if abs(parent.height - height) > 0.5 { parent.height = height }
        }
    }
}

/// The composer's text view: pasting files (copied in Finder) or a picture (a screenshot, an image
/// copied from a browser or Photos) attaches them; everything else pastes as plain text.
final class ComposerNSTextView: NSTextView {
    var onPasteFiles: (([URL]) -> Void)?
    /// Replaceable so tests don't touch your clipboard.
    var pasteboard: NSPasteboard = .general

    private static let imageTypes: [(type: NSPasteboard.PasteboardType, fileExtension: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("public.heic"), "heic"),
        (.tiff, "tiff"),
    ]

    // A plain-text view normally greys out Paste when the clipboard holds only a picture or a
    // file, so paste(_:) would never run. Accept those too.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL] + Self.imageTypes.map(\.type)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), fileURLs() != nil || prefersImage() {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if let urls = fileURLs() {
            onPasteFiles?(urls)
        } else if prefersImage(), let url = writeImage() {
            onPasteFiles?([url])
        } else {
            // Plain text, from this view's pasteboard (pasteAsPlainText would read the system one).
            readSelection(from: pasteboard)
        }
    }

    private func fileURLs() -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    /// Whether the app that copied put a picture before any text, as Safari's Copy Image and
    /// screenshots do. Text copied from a web page lists its text first and still pastes as text.
    private func prefersImage() -> Bool {
        let imageTypes = Set(Self.imageTypes.map(\.type))
        let first = pasteboard.types?.first { imageTypes.contains($0) || $0 == .string }
        return first.map(imageTypes.contains) ?? false
    }

    /// Saves the picture as a temporary file to attach, in its original format.
    private func writeImage() -> URL? {
        guard let (data, fileExtension) = Self.imageTypes.lazy
            .compactMap({ entry in self.pasteboard.data(forType: entry.type).map { ($0, entry.fileExtension) } })
            .first
        else { return nil }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        // Each paste in its own folder: two pictures pasted within a second keep their own files.
        let url = OutgoingFiles.url(named: "Pasted Image \(stamp).\(fileExtension)")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
