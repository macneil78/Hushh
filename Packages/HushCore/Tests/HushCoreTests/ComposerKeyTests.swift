import AppKit
import Carbon.HIToolbox
import Foundation
import HushAI
import SwiftUI
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

/// The real ComposerView in an invisible window, driven with key presses.
@MainActor
@Suite(.serialized)
struct ComposerKeyTests {
    /// A send clears the box and its undo stack: undoing the typing would reach past the now
    /// empty text and raise.
    @Test func undoAfterSendingDoesNotRaise() {
        let host = ComposerHost(Fixtures.conversation().0)
        defer { host.close() }
        host.type("hello there")
        host.textView.breakUndoCoalescing()
        host.pressReturn()
        #expect(host.conversation.composerText.isEmpty)
        #expect(host.textView.undoManager?.canUndo == false)
        host.textView.undoManager?.undo()
        #expect(host.textView.string.isEmpty)
    }

    @Test func escapeKeepsTheChatOpenWhileThereIsText() {
        let host = ComposerHost(Fixtures.conversation().0)
        defer { host.close() }
        host.type("half-written message")
        host.pressEscape()
        #expect(host.closed == 0)
        #expect(host.conversation.composerText == "half-written message")
        host.conversation.composerText = ""
        TestWindow.run(for: 0.05)
        host.pressEscape()
        #expect(host.closed == 1)  // an empty box still closes the chat
    }

    @Test func tabLeavesTheBoxAndOptionTabTypesATab() {
        let host = ComposerHost(Fixtures.conversation().0)
        defer { host.close() }
        host.type("a")
        host.pressTab()
        #expect(host.textView.string == "a")
        host.window.makeFirstResponder(host.textView)
        host.pressTab(.option)
        #expect(host.textView.string == "a\t")
    }

    @Test func controlReturnAddsAPlainNewLine() {
        let host = ComposerHost(Fixtures.conversation().0)
        defer { host.close() }
        host.type("one")
        host.pressReturn(.control)
        host.type("two")
        #expect(host.conversation.composerText == "one\ntwo")
    }

    /// While a recording waits for the microphone (or runs), the box stays, typing goes into
    /// it, and Return sends what you typed, never the recording. Esc cancels the recording.
    @Test func returnNeverSendsARecording() async {
        let conversation = Fixtures.conversation().0
        conversation.recorder.permission = { .undetermined }
        conversation.recorder.requestPermission = {
            try? await Task.sleep(for: .seconds(30))
            return true
        }
        let host = ComposerHost(conversation)
        defer {
            conversation.cancelRecording()
            host.close()
        }
        conversation.startRecording()
        await Fixtures.wait { conversation.recorder.state == .waitingForPermission }
        TestWindow.run(for: 0.1)
        #expect(conversation.recorder.state == .waitingForPermission)
        #expect(TestWindow.views(ComposerNSTextView.self, in: host.window.contentView!).first === host.textView)
        host.window.makeFirstResponder(host.textView)
        host.type("typed meanwhile")
        #expect(conversation.composerText == "typed meanwhile")
        host.pressReturn()
        #expect(conversation.composerText.isEmpty)  // the text went out (and will come back: the client is offline)
        #expect(conversation.recorder.state == .waitingForPermission)
        host.pressEscape()
        #expect(conversation.recorder.state == .idle)
        #expect(host.closed == 0)
    }

    @Test func theMessageBoxHasAName() {
        let host = ComposerHost(Fixtures.conversation().0)
        defer { host.close() }
        #expect(host.textView.accessibilityLabel() == "Message")
        #expect(host.textView.accessibilityPlaceholderValue() == "Message")
    }
}

/// ComposerView in an invisible window, with its text view first responder. Key presses go
/// through the window, as the app's event loop hands them on.
@MainActor
private final class ComposerHost {
    let window: NSWindow
    let conversation: ConversationModel
    var closed = 0
    var textView: ComposerNSTextView!

    init(_ conversation: ConversationModel) {
        self.conversation = conversation
        window = TestWindow.make(width: 520, height: 260)
        let view = ComposerView(conversation: conversation, stickers: StickerLibrary(), files: FileStore(), onClose: { [unowned self] in closed += 1 })
            .frame(width: 520)
        window.contentView = NSHostingView(rootView: view.environment(Codex()))
        TestWindow.run(for: 0.15)
        textView = TestWindow.views(ComposerNSTextView.self, in: window.contentView!).first
        window.makeFirstResponder(textView)
    }

    func close() {
        TestWindow.close(window)
    }

    func type(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
        TestWindow.run(for: 0.04)
    }

    func press(_ keyCode: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
        TestWindow.press(characters, keyCode: keyCode, modifiers: modifiers, in: window)
        TestWindow.run(for: 0.06)
    }

    func pressReturn(_ modifiers: NSEvent.ModifierFlags = []) { press(kVK_Return, "\r", modifiers: modifiers) }
    func pressEscape() { press(kVK_Escape, "\u{1b}") }
    func pressTab(_ modifiers: NSEvent.ModifierFlags = []) { press(kVK_Tab, "\t", modifiers: modifiers) }
}
