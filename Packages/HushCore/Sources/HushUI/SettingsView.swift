import AppKit
import HushAI
import HushCore
import SwiftUI

/// Hush → Settings… (⌘,).
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("Account", systemImage: "person.crop.circle") {
                AccountSettings(model: model)
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right") {
                if model.auth.step == .ready {
                    ChooseChatsView(chats: model.chats, files: model.files, isSheet: false)
                } else {
                    notLoggedIn
                }
            }
            Tab("Notifications", systemImage: "bell") {
                NotificationSettings(preferences: model.notificationPreferences)
            }
            Tab("AI", systemImage: "sparkles") {
                AISettings()
            }
            Tab("About", systemImage: "info.circle") {
                AboutSettings(model: model)
            }
        }
        .frame(width: 500)
    }

    private var notLoggedIn: some View {
        Text("Log in to choose which chats Hushh shows.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(40)
    }
}

struct AccountSettings: View {
    let model: AppModel
    @State private var isConfirmingLogOut = false

    var body: some View {
        VStack(spacing: 14) {
            if let user = model.currentUser, model.auth.step == .ready {
                let person = model.chats.person(user.id)
                Avatar(
                    title: user.displayName,
                    accentColorId: person?.accentColorId ?? 0,
                    photoFileId: person?.photoFileId,
                    files: model.files,
                    size: 64
                )
                VStack(spacing: 2) {
                    Text(user.displayName)
                        .font(.title3.weight(.semibold))
                    Text("+\(user.phoneNumber)")
                        .foregroundStyle(.secondary)
                }
                Button("Log Out…") { isConfirmingLogOut = true }
                    .padding(.top, 6)
            } else {
                Text("Not logged in.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .confirmationDialog("Log out of Telegram on this Mac?", isPresented: $isConfirmingLogOut) {
            Button("Log Out", role: .destructive) { model.auth.logOut() }
        } message: {
            Text("Your chats stay on your other devices.")
        }
    }
}

struct NotificationSettings: View {
    @Bindable var preferences: NotificationPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $preferences.isEnabled)
                Toggle("Play a sound", isOn: $preferences.playsSound)
                    .disabled(!preferences.isEnabled)
                Toggle("Show message text", isOn: $preferences.showsPreview)
                    .disabled(!preferences.isEnabled)
            } footer: {
                Text("Only chats you can see in Hushh notify. Chats muted in Telegram, here or on your phone, stay silent.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Open System Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 280)
    }
}

/// The on-device models: what each does, how big it is, and getting or removing it.
struct AISettings: View {
    @Environment(ModelStore.self) private var models

    var body: some View {
        Form {
            Section {
                ForEach(AIModel.allCases) { model in
                    row(model)
                }
            } footer: {
                Text("Everything runs on this Mac. Only the models are downloaded, once, from Hugging Face; your messages and recordings never leave it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
    }

    private func row(_ model: AIModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.headline)
                Text(model.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status(model)
                    .font(.caption)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            action(model)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func status(_ model: AIModel) -> some View {
        switch models.state(of: model) {
        case .missing:
            Text(model.downloadSize.formatted(.byteCount(style: .file)))
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading… \(Int(fraction * 100))%")
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 220)
        case .preparing:
            Text("Preparing it for this Mac… the first time takes a couple of minutes.")
                .foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Text(reason)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private func action(_ model: AIModel) -> some View {
        switch models.state(of: model) {
        case .missing:
            Button("Download") { models.download(model) }
        case .failed:
            Button("Try Again") { models.download(model) }
        case .downloading:
            Button("Cancel") { models.cancelDownload(model) }
        case .preparing:
            ProgressView().controlSize(.small)
        case .ready:
            Button("Delete", role: .destructive) {
                Task { await models.delete(model) }
            }
        }
    }
}

struct AboutSettings: View {
    let model: AppModel
    @State private var report: ChatListReport?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Hushh \(version)")
                .font(.title3.weight(.semibold))
            Text("Your Telegram chats, without the noise.")
                .foregroundStyle(.secondary)
            Text("Unofficial client using the Telegram API. Not affiliated with Telegram.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if let tdlib = model.tdlibVersion {
                Text("TDLib \(tdlib)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if model.auth.step == .ready {
                chatListReport
            }
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .onAppear { report = model.chats.report() }
    }

    /// Where your chats went, for when one seems to be missing.
    private var chatListReport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your chat list")
                .font(.headline)
            Text(report?.summary ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Archived chats are under View → Show Archived Chats (⇧⌘A).")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Refresh") { report = model.chats.report() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report?.summary ?? "", forType: .string)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 16)
    }
}
