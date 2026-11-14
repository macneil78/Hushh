import AppKit
import HushAI
import HushCore
import SwiftUI

extension EnvironmentValues {
    /// Codex's help in the open chat; nil when Codex isn't set up.
    @Entry var assistant: ChatAssistant?
}

/// Catch Up's summary, at the top of the chat until you close it.
struct SummaryCard: View {
    let work: ChatAssistant.Work
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Catch Up", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if case .writing = work {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Codex is writing…")
                }
                Spacer()
                if case .done(let text) = work {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .help("Copy the summary")
                }
                Button("Close", systemImage: "xmark", action: onClose)
                    .help("Close")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            switch work {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Codex is reading the chat…")
                        .foregroundStyle(.secondary)
                }
            case .writing(let text), .done(let text):
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                HStack {
                    Text(reason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try Again", action: onRetry)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

/// A message's translation, under its text, until you hide it.
struct TranslationText: View {
    let messageId: Int64
    let onAccent: Bool
    @Environment(\.assistant) private var assistant

    var body: some View {
        if let work = assistant?.translations[messageId] {
            VStack(alignment: .leading, spacing: 3) {
                Divider()
                    .overlay(onAccent ? Color.white.opacity(0.35) : Color.clear)
                switch work {
                case .working:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Translating…")
                    }
                    .font(.callout)
                    .opacity(0.7)
                case .writing(let text), .done(let text):
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed(let reason):
                    Text(reason)
                        .font(.caption)
                        .opacity(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// ✨ in the message box: Draft a Reply, or rewrite what you've typed.
struct AssistantMenu: View {
    let assistant: ChatAssistant
    let hasText: Bool

    var body: some View {
        if assistant.isWriting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
                .help("Codex is writing…")
        } else {
            Menu {
                Button(hasText ? "Draft a Reply From My Notes" : "Draft a Reply", systemImage: "text.bubble") { assistant.draftReply() }
                Divider()
                Group {
                    Button("Fix Spelling and Grammar") { assistant.polish(.fix) }
                    Button("Make Shorter") { assistant.polish(.shorter) }
                    Button("Make Friendlier") { assistant.polish(.friendlier) }
                    Button("Make More Formal") { assistant.polish(.formal) }
                    Menu("Translate To") {
                        ForEach(ChatAssistant.languages) { language in
                            Button(language.name) { assistant.polish(.translate(language)) }
                        }
                    }
                }
                .disabled(!hasText)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Codex: draft a reply, or polish what you've typed")
        }
    }
}

/// Over the message box after Codex wrote in it, until you change the text: a way back.
struct WrittenByCodexBar: View {
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("Written by Codex", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Undo", action: onUndo)
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }
}

/// Settings → AI: setting up Codex, and what it sends where.
struct CodexSettingsSection: View {
    let vault: LocalVault?
    @Environment(Codex.self) private var codex
    @State private var error: String?
    @State private var remembers = ChatMemory.isEnabled
    @State private var isConfirmingForget = false

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex")
                        .font(.headline)
                    Text("Catch up on a chat, draft a reply, polish or translate what you write, and translate messages, with OpenAI's Codex signed in to your ChatGPT account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status
                        .font(.caption)
                        .padding(.top, 2)
                }
                Spacer(minLength: 8)
                if codex.setup != .ready {
                    Button(codex.setup == .missing ? "Set Up…" : "Update…", action: install)
                }
            }
            .padding(.vertical, 4)
            if codex.isAvailable {
                @Bindable var codex = codex
                Picker("Model", selection: $codex.model) {
                    ForEach(Codex.Model.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                Toggle(isOn: $remembers) {
                    Text("Remember each chat")
                    Text("A short note per chat (language, tone, names, plans) that Codex keeps up to date while it catches you up or drafts, so it knows who you're talking to. Kept encrypted on this Mac; see it in Chat Info.")
                }
                .onChange(of: remembers) { _, isOn in ChatMemory.isEnabled = isOn }
                if let vault {
                    Button("Forget All Chats…", role: .destructive) { isConfirmingForget = true }
                        .confirmationDialog("Forget what Codex remembers about every chat?", isPresented: $isConfirmingForget) {
                            Button("Forget All", role: .destructive) { ChatMemory(vault: vault).forgetAll() }
                        }
                }
            }
        } footer: {
            Text("\(codex.model.title): \(codex.model.detail) Only when you use one of these does Hushh send Codex the messages it needs (the unread ones, the recent conversation, or the message to translate), with the chat's note. Codex sends them to OpenAI. Nothing else leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { codex.refresh() }
    }

    @ViewBuilder private var status: some View {
        if let error {
            Text(error).foregroundStyle(.red)
        } else {
            switch codex.setup {
            case .ready:
                Label("Ready. Needs the Codex app or CLI, signed in.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .outdated:
                Text("Set up by an older Hushh; update it to the current version.")
                    .foregroundStyle(.secondary)
            case .missing:
                Text("Needs Codex installed and signed in (“codex login” in Terminal).")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// macOS only lets Hushh run scripts you put in its Application Scripts folder yourself, so
    /// this asks you to save it there.
    private func install() {
        error = nil
        let panel = NSSavePanel()
        panel.title = "Set Up Codex"
        panel.message = "Save Hushh's Codex script here. macOS lets Hushh run only the scripts you put in this folder."
        panel.prompt = "Save"
        panel.nameFieldStringValue = Codex.scriptName
        panel.directoryURL = Codex.scriptsFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.deletingLastPathComponent().standardizedFileURL == Codex.scriptsFolder?.standardizedFileURL,
              url.lastPathComponent == Codex.scriptName else {
            error = "Save it as \(Codex.scriptName) in the folder the panel opened in."
            return
        }
        do {
            try codex.install(to: url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Chat Info: what Codex remembers about this chat, to read, correct or clear.
struct MemoryCard: View {
    let chatId: Int64
    let vault: LocalVault
    @State private var text = ""
    @State private var draft = ""
    @State private var isEditing = false

    private var memory: ChatMemory { ChatMemory(vault: vault) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Memory", systemImage: "note.text")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isEditing {
                    Button("Cancel") { isEditing = false }
                    Button("Save") {
                        memory.write(draft, for: chatId)
                        text = memory.read(chatId)
                        isEditing = false
                    }
                    .disabled(draft.count > ChatMemory.maxLength)
                } else {
                    if !text.isEmpty {
                        Button("Forget", role: .destructive) {
                            memory.forget(chatId)
                            text = ""
                        }
                    }
                    Button("Edit") {
                        draft = text
                        isEditing = true
                    }
                }
            }
            .buttonStyle(.borderless)
            if isEditing {
                TextEditor(text: $draft)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 130)
                    .padding(6)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("\(draft.count) of \(ChatMemory.maxLength) characters")
                    .font(.caption2)
                    .foregroundStyle(draft.count > ChatMemory.maxLength ? .red : .secondary)
            } else if text.isEmpty {
                Text("Nothing yet. Codex writes a short note here when it catches you up or drafts a reply in this chat, and keeps it current.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: 520)
        .onAppear { text = memory.read(chatId) }
    }
}
