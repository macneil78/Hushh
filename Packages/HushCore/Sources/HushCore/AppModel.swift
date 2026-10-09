@preconcurrency import TDLibKit
import AppKit
import Observation

/// The logged-in user, as the app displays them.
public struct CurrentUser: Equatable, Sendable {
    public let id: Int64
    public let displayName: String
    public let phoneNumber: String
}

/// Owns the TDLib session and routes its updates to the models the UI observes.
@MainActor @Observable
public final class AppModel {
    public enum State: Equatable, Sendable {
        /// `Config/Secrets.xcconfig` is missing or incomplete.
        case needsCredentials
        case running
    }

    public let state: State
    public let auth: AuthModel
    public let chats: ChatStore
    public let files = FileStore()
    public let stickers = StickerLibrary()
    /// The voice message playing, in whichever chat.
    public let voice = VoicePlayback()
    public let notificationPreferences = NotificationPreferences()
    public private(set) var currentUser: CurrentUser?
    /// The chat open in the window, if any.
    public private(set) var conversation: ConversationModel?
    /// Set by the UI: shows a chat in the window, reopening the window if it was closed.
    @ObservationIgnored public var onShowChat: ((Int64) -> Void)?
    public private(set) var tdlibVersion: String?

    @ObservationIgnored private let configuration: TDConfiguration?
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private var session: TDSession?
    @ObservationIgnored private var updateLoop: Task<Void, Never>?
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var wipeDatabaseOnClose = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    public init(configuration: TDConfiguration?) {
        self.configuration = configuration
        state = configuration == nil ? .needsCredentials : .running
        auth = AuthModel(configuration: configuration)
        chats = ChatStore(files: files)
        notifications = NotificationService(chats: chats, preferences: notificationPreferences)
        auth.onDatabaseKeyMismatch = { [weak self] in self?.resetLocalData() }
        notifications.onOpenChat = { [weak self] chatId in self?.onShowChat?(chatId) }
        notifications.openChatId = { [weak self] in self?.conversation?.chatId }
        chats.onBadgeCountChange = { count in
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
    }

    /// Starts TDLib. Safe to call more than once.
    public func start() {
        guard session == nil, configuration != nil, !isTerminating else { return }
        observeApplication()
        openSession()
    }

    /// Leaves QR login for the phone-number form. TDLib can't switch directly, so restart the client.
    public func logInWithPhoneNumber() {
        auth.prefersQRCode = false
        restartSession()
    }

    /// Opens a chat in the window, closing the previous one (which saves its draft).
    public func openConversation(_ chatId: Int64?) {
        guard conversation?.chatId != chatId else { return }
        conversation?.close()
        conversation = nil
        guard let chatId, let client = session?.client, let item = chats.item(chatId) else { return }
        let conversation = ConversationModel(chat: item, client: client, chats: chats, voice: voice)
        self.conversation = conversation
        Task { await conversation.open() }
    }

    /// Tells Telegram whether you're online. Follows whether Hush is the active app.
    public func setOnline(_ isOnline: Bool) {
        guard auth.step == .ready, let session else { return }
        // Not awaited, so it still goes out while the app is quitting.
        session.sendIgnoringReply(SetOption(name: "online", value: .optionValueBoolean(.init(value: isOnline))))
    }

    // MARK: Session lifecycle

    private func openSession() {
        let session = TDSession(logFile: configuration?.logFile)
        self.session = session
        auth.attach(session.client)
        files.attach(session.client)
        stickers.attach(session.client)
        updateLoop = Task { [weak self] in
            for await update in session.updates {
                self?.handle(update)
            }
        }
    }

    private func restartSession() {
        guard let client = session?.client else { return }
        Task { _ = try? await client.close() }
    }

    private func resetLocalData() {
        wipeDatabaseOnClose = true
        restartSession()
    }

    private func handle(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let change):
            auth.apply(change.authorizationState)
            switch change.authorizationState {
            case .authorizationStateReady:
                Task { await sessionDidBecomeReady() }
            case .authorizationStateClosed:
                sessionDidClose()
            default:
                break
            }
        case .updateOption(let option):
            if option.name == "version", case .optionValueString(let version) = option.value {
                tdlibVersion = version.value
                Log.session.info("TDLib \(version.value, privacy: .public)")
            } else if option.name == "telegram_service_notifications_chat_id",
                      case .optionValueInteger(let chatId) = option.value {
                chats.serviceChatId = chatId.value.rawValue
            }
        case .updateFile(let update):
            files.apply(update.file)
        default:
            chats.handle(update)
            conversation?.handle(update)
            notifications.handle(update)
        }
    }

    private func sessionDidBecomeReady() async {
        guard let client = session?.client, let configuration else { return }
        let me: User
        do {
            me = try await client.getMe()
        } catch {
            Log.session.error("Couldn't load the current user: \(String(describing: error), privacy: .public)")
            return
        }
        currentUser = CurrentUser(
            id: me.id,
            displayName: [me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " "),
            phoneNumber: me.phoneNumber
        )
        setOnline(NSApp.isActive)
        Task { await keepCallsAndSecretChatsOnPhone(client) }
        let settingsFile = configuration.accountDirectory(for: me.id).appending(path: "visibility.json")
        chats.attach(client: client, myUserId: me.id, settingsFile: settingsFile)
        // After your visibility choices are loaded, so hidden chats are filtered from the start.
        if let session { notifications.start(session: session) }
        await chats.loadLists()
    }

    /// Calls and secret chats stay on the phone: this session tells Telegram it can't take them,
    /// so they never ring or land here.
    private func keepCallsAndSecretChatsOnPhone(_ client: TDLibClient) async {
        do {
            let sessions = try await client.getActiveSessions()
            guard let current = sessions.sessions.first(where: \.isCurrent) else { return }
            if current.canAcceptCalls {
                _ = try await client.toggleSessionCanAcceptCalls(canAcceptCalls: false, sessionId: current.id)
            }
            if current.canAcceptSecretChats {
                _ = try await client.toggleSessionCanAcceptSecretChats(canAcceptSecretChats: false, sessionId: current.id)
            }
        } catch {
            Log.session.error("Couldn't turn off calls and secret chats for this session: \(String(describing: error), privacy: .public)")
        }
    }

    private func sessionDidClose() {
        session = nil
        currentUser = nil
        conversation = nil
        notifications.reset()
        voice.stop()
        stickers.reset()
        chats.reset()
        files.reset()
        guard !isTerminating else { return }
        if wipeDatabaseOnClose, let configuration {
            wipeDatabaseOnClose = false
            try? FileManager.default.removeItem(at: configuration.databaseDirectory)
        }
        // After logging out or a restart, TDLib needs a fresh client to log in again.
        openSession()
    }

    // MARK: App lifecycle

    private func observeApplication() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setOnline(true)
                    self?.conversation?.appBecameActive()
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setOnline(false) }
            },
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.prepareForTermination() }
            },
        ]
    }

    /// Flushes TDLib's databases before the app quits.
    private func prepareForTermination() {
        setOnline(false)
        isTerminating = true
        TDSession.closeAll()
    }
}
