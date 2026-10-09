import AppKit
import HushCore
import SwiftUI
import UniformTypeIdentifiers

/// Where you write. Enter sends, Shift+Enter starts a new line, ↑ edits your last message,
/// Esc cancels a reply or edit. Files can be attached, pasted or dropped onto the conversation.
struct ComposerView: View {
    @Bindable var conversation: ConversationModel
    let stickers: StickerLibrary
    let files: FileStore
    @State private var editorHeight: CGFloat = 30
    @State private var isPickingFiles = false
    @State private var isPickingSticker = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
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
            } else {
                inputRow
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button("Attach Files", systemImage: "paperclip") { isPickingFiles = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .padding(.bottom, 6)
                .disabled(conversation.editing != nil)
                .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { conversation.attach(urls) }
                }

            ComposerTextView(
                text: $conversation.composerText,
                height: $editorHeight,
                focusRequest: conversation.focusRequest,
                onSubmit: conversation.send,
                onUpArrowInEmptyComposer: conversation.editLastMessage,
                onEscape: conversation.cancelComposerMode,
                onTextChange: conversation.composerChanged,
                onPasteFiles: conversation.attach
            )
            .frame(height: min(max(editorHeight, 30), 180))
            .overlay(alignment: .topLeading) {
                if conversation.composerText.isEmpty {
                    Text(conversation.attachments.isEmpty ? "Message" : "Add a caption")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 9)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button("Stickers and GIFs", systemImage: "face.smiling") { isPickingSticker.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .padding(.bottom, 6)
                .disabled(conversation.editing != nil)
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

            if conversation.canSend || conversation.editing != nil {
                Button(conversation.editing == nil ? "Send" : "Save", systemImage: conversation.editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill") {
                    conversation.send()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 26))
                .disabled(!conversation.canSend)
                .padding(.bottom, 2)
            } else {
                // Nothing typed: the button records a voice message instead.
                Button("Record Voice Message", systemImage: "mic.fill", action: conversation.startRecording)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.system(size: 19))
                    .frame(width: 30, height: 30)
                    .padding(.bottom, 1)
            }
        }
        .padding(10)
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
                        Button("Remove", systemImage: "xmark.circle.fill") { onRemove(attachment) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func preview(of attachment: Attachment) -> some View {
        if attachment.kind == .photo, let image = ImageCache.image(at: attachment.url) {
            Image(nsImage: image).resizable().scaledToFill()
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
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
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

        init(_ parent: ComposerTextView) {
            self.parent = parent
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
            pasteAsPlainText(sender)
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
        let url = FileManager.default.temporaryDirectory.appending(path: "Pasted Image \(stamp).\(fileExtension)")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
