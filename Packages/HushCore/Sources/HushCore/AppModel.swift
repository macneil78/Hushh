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
    /// Which credential the build lacks or got wrong, when `state` is `.needsCredentials` and the
    /// model was made with `init(loadingFrom:)`.
    public let credentialsProblem: TDConfiguration.LoadError?
    public let auth: AuthModel
    public let chats: ChatStore
    public let files = FileStore()
    public let stickers = StickerLibrary()
    /// The voice message playing, in whichever chat.
    public let voice = VoicePlayback()
    public let notificationPreferences = NotificationPreferences()
    public private(set) var currentUser: CurrentUser?
    /// Where this account's transcripts and search indexes are kept, encrypted. Nil until logged in.
    public private(set) var vault: LocalVault?
    /// The chat open in the window, if any.
    public private(set) var conversation: ConversationModel?
    /// Set by the UI: whether the window showing `conversation` is open and not minimized. The
    /// chat stays open while the window is closed, but only counts as seen while this is true.
    public var isWindowOnScreen = false
    /// Set by the UI: shows a chat in the window, reopening the window if it was closed.
    @ObservationIgnored public var onShowChat: ((Int64) -> Void)?
    /// Set by the UI: whether the main window is the one in front (open, not minimized, Hush
    /// active). Only then does the open chat count as read on screen, and stay quiet.
    @ObservationIgnored public var isMainWindowActive = false
    public private(set) var tdlibVersion: String?
    /// TDLib's link to Telegram as a short status ("Waiting for network…"). Nil while it works.
    public private(set) var connectionStatus: String?

    @ObservationIgnored private let configuration: TDConfiguration?
    @ObservationIgnored private let notifications: NotificationService
    @ObservationIgnored private var session: TDSession?
    @ObservationIgnored private var updateLoop: Task<Void, Never>?
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var wipeDatabaseOnClose = false
    /// TDLib reported a logout on this session: its account's data goes once the session closes.
    @ObservationIgnored private var isLoggingOut = false
    @ObservationIgnored private var logOutCleanups: [@MainActor () -> Void] = []
    /// Whether this session has told Telegram it takes no calls or secret chats.
    @ObservationIgnored private var callsStayOnPhone = false
    @ObservationIgnored private var isTurningOffCalls = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// Reads the API credentials from the app's Info.plist. If they're missing or wrong, the
    /// model starts in `.needsCredentials` and `credentialsProblem` says why.
    public convenience init(loadingFrom bundle: Bundle = .main) {
        let configuration: TDConfiguration?
        let problem: TDConfiguration.LoadError?
        do {
            configuration = try TDConfiguration.load(from: bundle)
            problem = nil
        } catch {
            configuration = nil
            problem = error
        }
        self.init(configuration: configuration, credentialsProblem: problem)
    }

    public convenience init(configuration: TDConfiguration?) {
        self.init(configuration: configuration, credentialsProblem: nil)
    }

    init(configuration: TDConfiguration?, credentialsProblem: TDConfiguration.LoadError?) {
        self.configuration = configuration
        self.credentialsProblem = credentialsProblem
        state = configuration == nil ? .needsCredentials : .running
        auth = AuthModel(configuration: configuration)
        chats = ChatStore(files: files)
        notifications = NotificationService(chats: chats, preferences: notificationPreferences)
        auth.onDatabaseKeyMismatch = { [weak self] in self?.resetLocalData() }
        notifications.onOpenChat = { [weak self] chatId in
            NSApp.activate()
            self?.onShowChat?(chatId)
        }
        notifications.openChatId = { [weak self] in
            // Both signals: the window can be key yet minimized for a moment, and on screen yet behind.
            guard let self, isMainWindowActive, isWindowOnScreen else { return nil }
            return conversation?.chatId
        }
        // Before launch finishes, so a click or reply that launches Hush reaches it. Without
        // credentials there is no session to act on; becomeDelegate also skips test processes.
        if configuration != nil { notifications.becomeDelegate() }
        chats.onBadgeCountChange = { count in
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
    }

    /// Starts TDLib. Safe to call more than once.
    public func start() {
        guard session == nil, configuration != nil, !isTerminating else { return }
        isStarted = true
        observeApplication()
        openSession()
    }

    /// Shows the phone-number form. From the QR code TDLib can't switch directly, so then the
    /// client restarts.
    public func logInWithPhoneNumber() {
        if auth.acceptsPhoneNumber {
            auth.useDifferentNumber()
        } else {
            auth.prefersQRCode = false
            restartSession()
        }
    }

    /// Starts login over with a new TDLib client, for the Try Again button of a failed step.
    public func tryAgain() {
        if session == nil {
            start()
        } else {
            restartSession()
        }
    }

    /// Registers work to run after each logout, once Hushh has deleted the account's files (see
    /// `AccountData`). For private data kept elsewhere: caches in memory, window state, files
    /// outside the folders `AccountData` deletes.
    public func onLogOut(_ cleanup: @escaping @MainActor () -> Void) {
        logOutCleanups.append(cleanup)
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

    func handle(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let change):
            auth.apply(change.authorizationState)
            switch change.authorizationState {
            case .authorizationStateReady:
                Task { await sessionDidBecomeReady() }
            case .authorizationStateLoggingOut:
                isLoggingOut = true
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
        case .updateConnectionState(let change):
            connectionStatus = switch change.state {
            case .connectionStateWaitingForNetwork: "Waiting for network…"
            case .connectionStateConnectingToProxy: "Connecting to proxy…"
            case .connectionStateConnecting: "Connecting…"
            case .connectionStateUpdating: "Updating…"
            case .connectionStateReady: nil
            }
            if change.state == .connectionStateReady, currentUser != nil { turnOffCallsAndSecretChats() }
        default:
            chats.handle(update)
            conversation?.handle(update)
            notifications.handle(update)
        }
    }

    private func sessionDidBecomeReady() async {
        guard let session, let configuration else { return }
        let client = session.client
        let me: User
        do {
            me = try await client.getMe()
        } catch {
            Log.session.error("Couldn't load the current user: \(String(describing: error), privacy: .public)")
            return
        }
        // The session may have closed (or logged out) while getMe was on its way.
        guard self.session === session, auth.step == .ready else { return }
        currentUser = CurrentUser(
            id: me.id,
            displayName: [me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " "),
            phoneNumber: me.phoneNumber
        )
        setOnline(NSApp.isActive)
        turnOffCallsAndSecretChats()
        if let key = try? configuration.databaseKey.loadOrCreate() {
            vault = LocalVault(directory: configuration.accountDirectory(for: me.id).appending(path: "ai", directoryHint: .isDirectory), databaseKey: key)
        }
        let settingsFile = configuration.accountDirectory(for: me.id).appending(path: "visibility.json")
        chats.attach(client: client, myUserId: me.id, settingsFile: settingsFile)
        // After your visibility choices are loaded, so hidden chats are filtered from the start.
        notifications.start(session: session)
        await chats.loadLists()
        // Now a click can open its chat: act on those that launched Hush.
        notifications.sessionIsReady()
    }

    /// Calls and secret chats stay on the phone: this session tells Telegram it can't take them,
    /// so they never ring or land here. If that fails, it tries again each time the connection
    /// comes back.
    private func turnOffCallsAndSecretChats() {
        guard !callsStayOnPhone, !isTurningOffCalls, let session else { return }
        isTurningOffCalls = true
        Task {
            let done = await keepCallsAndSecretChatsOnPhone(session.client)
            isTurningOffCalls = false
            if done, self.session === session { callsStayOnPhone = true }
        }
    }

    private func keepCallsAndSecretChatsOnPhone(_ client: TDLibClient) async -> Bool {
        do {
            let sessions = try await client.getActiveSessions()
            guard let current = sessions.sessions.first(where: \.isCurrent) else { return false }
            if current.canAcceptCalls {
                _ = try await client.toggleSessionCanAcceptCalls(canAcceptCalls: false, sessionId: current.id)
            }
            if current.canAcceptSecretChats {
                _ = try await client.toggleSessionCanAcceptSecretChats(canAcceptSecretChats: false, sessionId: current.id)
            }
            return true
        } catch {
            Log.session.error("Couldn't turn off calls and secret chats for this session: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func sessionDidClose() {
        session = nil
        currentUser = nil
        vault = nil
        connectionStatus = nil
        callsStayOnPhone = false
        // Cancels a voice recording and deletes its file.
        conversation?.close()
        conversation = nil
        notifications.reset()
        voice.reset()  // also deletes the decoded voice messages
        stickers.reset()
        chats.reset()
        files.reset()
        if isLoggingOut {
            isLoggingOut = false
            wipeDatabaseOnClose = false
            if let configuration { AccountData.removeAfterLogOut(configuration) }
            for cleanup in logOutCleanups { cleanup() }
        } else if wipeDatabaseOnClose, let configuration {
            wipeDatabaseOnClose = false
            AccountData.removeAfterKeyMismatch(configuration)
        }
        guard isStarted, !isTerminating else { return }
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

    /// Saves the open chat's draft and flushes TDLib's databases before the app quits.
    private func prepareForTermination() {
        setOnline(false)
        isTerminating = true
        // TDLib takes requests in order, so it saves the draft before it closes.
        if let session { conversation?.closeBeforeQuitting { session.sendIgnoringReply($0) } }
        TDSession.closeAll()
    }
}
