@preconcurrency import TDLibKit
import Foundation
import Observation

/// Turns TDLib's authorization state machine into login screens.
@MainActor @Observable
public final class AuthModel {
    public enum Step: Equatable, Sendable {
        case starting
        case qrCode(link: String)
        case phoneNumber
        case code(CodePrompt)
        /// `recoveryEmail` is the masked address a recovery code can go to, nil if there's none.
        case password(hint: String, recoveryEmail: String?)
        /// You forgot your password: enter the code Telegram emailed and choose a new password.
        case passwordRecovery(emailPattern: String)
        case emailAddress
        /// `resetNote` says how to log in without the email, nil when Telegram doesn't allow it.
        case emailCode(pattern: String, resetNote: String?)
        case registrationUnsupported
        case premiumRequired
        case ready
        case loggingOut
        /// Login can't go on (the keychain is locked, a request at start failed). The screen
        /// offers Try Again.
        case failed(String)
    }

    public struct CodePrompt: Equatable, Sendable {
        public let phoneNumber: String
        /// Where Telegram sent the code, phrased for the login screen.
        public let destination: String
        /// Expected code length, when Telegram says.
        public let length: Int?
        /// How the next code would come ("by SMS"), or nil when Telegram can't send another.
        public let nextWay: String?
        /// When Telegram allows asking for the next code. Asking earlier fails.
        public let resendDate: Foundation.Date
        /// A page to open for the code (Fragment's anonymous numbers).
        public let link: URL?

        public var canResend: Bool { nextWay != nil }
    }

    public private(set) var step: Step = .starting
    public private(set) var isWorking = false
    public var errorMessage: String?

    /// Whether TDLib's "how do you want to log in?" state shows the QR code (default) or the
    /// phone-number form.
    @ObservationIgnored var prefersQRCode = true
    /// Called when the keychain key no longer opens the local database.
    @ObservationIgnored var onDatabaseKeyMismatch: (() -> Void)?

    @ObservationIgnored private let configuration: TDConfiguration?
    @ObservationIgnored private var client: TDLibClient?
    /// The state TDLib is in. `step` can differ while a detour is shown.
    @ObservationIgnored private(set) var tdlibState: AuthorizationState?
    /// A screen shown on top of TDLib's state: the phone form while TDLib still waits for a code,
    /// or password recovery. TDLib allows both; Back returns to TDLib's step.
    @ObservationIgnored private var detour: Detour?
    /// The code prompt and the info it was made from. Seeing the same info again (Back, or TDLib
    /// repeating itself) keeps the prompt, so the resend countdown doesn't start over.
    @ObservationIgnored private var codePrompt: (info: AuthenticationCodeInfo, prompt: CodePrompt)?
    @ObservationIgnored private var requestCount = 0 {
        didSet { isWorking = requestCount > 0 }
    }

    private enum Detour {
        case phoneNumber
        case passwordRecovery(emailPattern: String)
    }

    init(configuration: TDConfiguration?) {
        self.configuration = configuration
    }

    func attach(_ client: TDLibClient) {
        self.client = client
        step = .starting
        errorMessage = nil
        tdlibState = nil
        detour = nil
    }

    func apply(_ state: AuthorizationState) {
        if let tdlibState, Self.caseName(tdlibState) != Self.caseName(state) { detour = nil }
        tdlibState = state
        let oldStep = step
        switch detour {
        case .phoneNumber:
            step = .phoneNumber
        case .passwordRecovery(let pattern):
            step = .passwordRecovery(emailPattern: pattern)
        case nil:
            applyTDLibStep(state)
        }
        // An error belongs to the step it was made on.
        if step != oldStep { errorMessage = nil }
    }

    private func applyTDLibStep(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            sendParameters()
        case .authorizationStateWaitPhoneNumber:
            if prefersQRCode {
                run { _ = try await $0.requestQrCodeAuthentication(otherUserIds: []) }
            } else {
                step = .phoneNumber
            }
        case .authorizationStateWaitOtherDeviceConfirmation(let state):
            step = .qrCode(link: state.link)
        case .authorizationStateWaitCode(let state):
            if codePrompt?.info != state.codeInfo {
                codePrompt = (state.codeInfo, CodePrompt(state.codeInfo))
            }
            step = .code(codePrompt!.prompt)
        case .authorizationStateWaitPassword(let state):
            step = .password(
                hint: state.passwordHint,
                recoveryEmail: state.hasRecoveryEmailAddress ? state.recoveryEmailAddressPattern : nil
            )
        case .authorizationStateWaitEmailAddress:
            step = .emailAddress
        case .authorizationStateWaitEmailCode(let state):
            step = .emailCode(pattern: state.codeInfo.emailAddressPattern, resetNote: Self.resetNote(state.emailAddressResetState))
        case .authorizationStateWaitRegistration:
            step = .registrationUnsupported
        case .authorizationStateWaitPremiumPurchase:
            step = .premiumRequired
        case .authorizationStateReady:
            step = .ready
            // The next login (after logging out) starts with the QR code again.
            prefersQRCode = true
        case .authorizationStateLoggingOut:
            step = .loggingOut
        case .authorizationStateClosing, .authorizationStateClosed:
            step = .starting
        }
    }

    // MARK: Actions

    public func submitPhoneNumber(_ phoneNumber: String) {
        let number = Self.normalizedPhoneNumber(phoneNumber)
        guard !isWorking, Self.isPlausiblePhoneNumber(number) else { return }
        detour = nil
        run { _ = try await $0.setAuthenticationPhoneNumber(phoneNumber: number, settings: nil) }
    }

    public func submitCode(_ code: String) {
        guard !isWorking, !code.isEmpty else { return }
        run { _ = try await $0.checkAuthenticationCode(code: code) }
    }

    public func submitPassword(_ password: String) {
        guard !isWorking, !password.isEmpty else { return }
        run { _ = try await $0.checkAuthenticationPassword(password: password) }
    }

    public func submitEmailAddress(_ emailAddress: String) {
        guard !isWorking, !emailAddress.isEmpty else { return }
        run { _ = try await $0.setAuthenticationEmailAddress(emailAddress: emailAddress) }
    }

    public func submitEmailCode(_ code: String) {
        guard !isWorking, !code.isEmpty else { return }
        let authentication = EmailAddressAuthentication.emailAddressAuthenticationCode(.init(code: code))
        run { _ = try await $0.checkAuthenticationEmailCode(code: authentication) }
    }

    public func resendCode() {
        run { _ = try await $0.resendAuthenticationCode(reason: nil) }
    }

    public func useQRCode() {
        prefersQRCode = true
        detour = nil
        run { _ = try await $0.requestQrCodeAuthentication(otherUserIds: []) }
    }

    /// Whether TDLib takes a phone number in its current state, so the form can be shown without
    /// restarting the client. TDLib allows this from every step that waits for you.
    var acceptsPhoneNumber: Bool {
        switch tdlibState {
        case .authorizationStateWaitPhoneNumber, .authorizationStateWaitCode, .authorizationStateWaitPassword,
             .authorizationStateWaitEmailAddress, .authorizationStateWaitEmailCode,
             .authorizationStateWaitRegistration, .authorizationStateWaitPremiumPurchase:
            true
        default:
            false
        }
    }

    /// Shows the phone-number form again, for a mistyped or wrong number. Submitting it starts a
    /// new login and drops the one in progress.
    public func useDifferentNumber() {
        guard acceptsPhoneNumber else { return }
        prefersQRCode = false
        if case .authorizationStateWaitPhoneNumber = tdlibState {
            detour = nil
        } else {
            detour = .phoneNumber
        }
        step = .phoneNumber
        errorMessage = nil
    }

    /// Whether the screen is a detour that Back can leave.
    public var canGoBack: Bool {
        switch step {
        case .phoneNumber: detour != nil
        case .passwordRecovery: true
        default: false
        }
    }

    /// Returns from a detour to the step TDLib waits on.
    public func goBack() {
        guard canGoBack, let tdlibState else { return }
        detour = nil
        apply(tdlibState)
        errorMessage = nil
    }

    /// Asks Telegram to email a recovery code to the address on the password step.
    public func forgotPassword() {
        guard case .password(_, let pattern?) = step else { return }
        run { _ = try await $0.requestAuthenticationPasswordRecovery() } then: { [weak self] in
            guard let self, case .authorizationStateWaitPassword = self.tdlibState else { return }
            detour = .passwordRecovery(emailPattern: pattern)
            step = .passwordRecovery(emailPattern: pattern)
            errorMessage = nil
        }
    }

    /// Logs in with the emailed recovery code and sets a new password. The new password is
    /// required, so recovery never turns the account's password off by accident.
    public func recoverPassword(code: String, newPassword: String, hint: String) {
        guard !isWorking, !code.isEmpty, !newPassword.isEmpty else { return }
        run {
            _ = try await $0.recoverAuthenticationPassword(newHint: hint, newPassword: newPassword, recoveryCode: code)
        }
    }

    /// Asks Telegram to drop the login email, so the code comes to the phone instead.
    public func resetEmailAddress() {
        run { _ = try await $0.resetAuthenticationEmailAddress() }
    }

    public func logOut() {
        run { _ = try await $0.logOut() }
    }

    // MARK: Phone numbers

    /// The number as Telegram wants it: ASCII digits, a leading "+", "00" read as "+". Digits from
    /// any script count (Arabic-Indic, full-width); other characters are dropped.
    public static func normalizedPhoneNumber(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "+" || character == "＋" {
                if result.isEmpty { result = "+" }
            } else if character.unicodeScalars.count == 1,
                      character.unicodeScalars.first?.properties.numericType == .decimal,
                      let digit = character.wholeNumberValue {
                result += String(digit)
            }
        }
        if result.hasPrefix("00") { result = "+" + result.dropFirst(2) }
        return result
    }

    /// At least five digits: shorter can't be a phone number with a country code.
    public static func isPlausiblePhoneNumber(_ normalized: String) -> Bool {
        normalized.filter(\.isASCII).filter(\.isNumber).count >= 5
    }

    // MARK: Private

    private func sendParameters() {
        guard let configuration else { return }
        let key: Data
        do {
            key = try configuration.databaseKey.loadOrCreate()
            for directory in [configuration.databaseDirectory, configuration.filesDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            step = .failed("Hushh couldn't prepare its local database: \(error)")
            return
        }
        guard let client else { return }
        requestCount += 1
        Task {
            defer { requestCount -= 1 }
            do {
                _ = try await client.setTdlibParameters(
                    apiHash: configuration.apiHash,
                    apiId: configuration.apiId,
                    applicationVersion: configuration.applicationVersion,
                    databaseDirectory: configuration.databaseDirectory.path,
                    databaseEncryptionKey: key,
                    deviceModel: DeviceInfo.model,
                    filesDirectory: configuration.filesDirectory.path,
                    systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                    systemVersion: "",  // TDLib detects it
                    useChatInfoDatabase: true,
                    useFileDatabase: true,
                    useMessageDatabase: true,
                    useSecretChats: false,  // secret chats stay on the phone
                    useTestDc: configuration.useTestDc
                )
            } catch let error as TDLibKit.Error where error.code == 401 {
                // The keychain key doesn't open this database (e.g. the keychain was reset).
                // Starting over is safe: everything re-syncs from Telegram after logging in again.
                Log.auth.error("Database key mismatch; resetting local data")
                onDatabaseKeyMismatch?()
            } catch {
                show(error)
            }
        }
    }

    private func run(
        _ action: @escaping @Sendable (TDLibClient) async throws -> Void,
        then onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard let client else { return }
        requestCount += 1
        errorMessage = nil
        Task {
            defer { requestCount -= 1 }
            do {
                try await action(client)
                onSuccess?()
            } catch {
                guard self.client === client else { return }  // an old session's request
                show(error)
            }
        }
    }

    /// Shows a failed request's error. While the screen is still the start-up spinner there is
    /// nothing to retry on, so it turns into the failed step with Try Again.
    private func show(_ error: any Swift.Error) {
        Log.auth.error("Login request failed: \(String(describing: error), privacy: .public)")
        let message = Self.describe(error)
        if step == .starting {
            step = .failed(message ?? "Telegram couldn't start the login.")
        } else {
            errorMessage = message
        }
    }

    /// The error as a sentence for the screen, or nil when it must not be shown (TDLib's 406).
    static func describe(_ error: any Swift.Error) -> String? {
        guard let error = error as? TDLibKit.Error else {
            if let description = (error as? any LocalizedError)?.errorDescription { return description }
            let domain = (error as NSError).domain
            if [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(domain) {
                return error.localizedDescription
            }
            return "Something went wrong. Try again."
        }
        // TDLib: a 406 error "must not be displayed to the user".
        if error.code == 406 { return nil }
        if let seconds = floodWaitSeconds(error) {
            return "Too many attempts. Try again in \(waitText(seconds))."
        }
        switch error.message {
        case "PHONE_NUMBER_INVALID":
            return "That phone number doesn't look right. Include the country code, like +44 7700 900123."
        case "PHONE_CODE_INVALID":
            return "That code isn't right. Check it and try again."
        case "PHONE_CODE_EXPIRED":
            return "That code has expired. Ask for a new one."
        case "PHONE_CODE_EMPTY":
            return "Enter the code."
        case "PASSWORD_HASH_INVALID":
            return "Wrong password."
        case "PHONE_NUMBER_BANNED":
            return "Telegram has banned this phone number."
        case "PHONE_NUMBER_UNOCCUPIED":
            return "There's no Telegram account for this number."
        case "PHONE_NUMBER_FLOOD":
            return "Telegram has paused logins for this number after too many attempts. Try again later, or log in with a QR code."
        case "PHONE_PASSWORD_FLOOD":
            return "Too many password attempts. Try again later."
        case "SESSION_PASSWORD_NEEDED":
            return "This account has a password. Enter it to continue."
        case "UPDATE_APP_TO_LOGIN":
            return "Telegram needs a newer version of Hushh to log in. Update Hushh, then try again."
        case "API_ID_INVALID", "API_ID_PUBLISHED_FLOOD":
            return "Telegram didn't accept this build's API ID and hash. Check Config/Secrets.xcconfig, then build Hushh again."
        case "AUTH_RESTART":
            return "Telegram asked to start the login again. Try again."
        case "EMAIL_CODE_INVALID", "CODE_INVALID":
            return "That email code isn't right."
        case "EMAIL_INVALID", "EMAIL_ADDRESS_INVALID":
            return "That email address doesn't look right."
        case "PASSWORD_RECOVERY_NA":
            return "This account has no recovery email."
        case "PASSWORD_RECOVERY_EXPIRED":
            return "That recovery code has expired. Ask for a new one."
        case "TASK_ALREADY_EXISTS":
            return "Telegram is already resetting the login email."
        default:
            if error.message.hasPrefix("FLOOD_WAIT") || error.code == 429 {
                return "Too many attempts. Wait a while, then try again."
            }
            // Telegram's raw constants mean nothing to people; TDLib's own errors are sentences.
            if error.message.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) {
                return "Telegram couldn't do that. Try again later."
            }
            return error.message
        }
    }

    /// The wait in "Too Many Requests: retry after 86400" or "FLOOD_WAIT_86400".
    static func floodWaitSeconds(_ error: TDLibKit.Error) -> Int? {
        let message = error.message
        if message.hasPrefix("FLOOD_WAIT_") { return Int(message.dropFirst("FLOOD_WAIT_".count)) }
        if message.hasPrefix("Too Many Requests") { return message.split(separator: " ").last.flatMap { Int($0) } }
        return nil
    }

    /// "45 seconds", "12 min", "23 h 59 min".
    static func waitText(_ seconds: Int) -> String {
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(max(seconds, 1)) seconds" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    private static func resetNote(_ state: EmailAddressResetState?) -> String? {
        switch state {
        case .emailAddressResetStateAvailable(let available):
            available.waitPeriod > 0
                ? "Telegram can drop this email and send the code to your phone instead. That takes \(waitText(available.waitPeriod))."
                : "Telegram can drop this email and send the code to your phone instead."
        case .emailAddressResetStatePending(let pending):
            "Telegram will drop this email in \(waitText(pending.resetIn)). Ask again then."
        case nil:
            nil
        }
    }

    /// The case's name, so a state that only changed its details counts as the same state.
    private static func caseName(_ state: AuthorizationState) -> String {
        Mirror(reflecting: state).children.first?.label ?? String(describing: state)
    }
}

extension AuthModel.CodePrompt {
    init(_ info: AuthenticationCodeInfo, now: Foundation.Date = .now) {
        phoneNumber = info.phoneNumber
        nextWay = info.nextType.map(Self.way)
        resendDate = now.addingTimeInterval(TimeInterval(max(info.timeout, 0)))
        var link: URL?
        switch info.type {
        case .authenticationCodeTypeTelegramMessage(let type):
            destination = "Telegram sent the code for \(info.phoneNumber) to your other devices. Check the Telegram app on your phone."
            length = type.length
        case .authenticationCodeTypeSms(let type):
            destination = "Telegram sent the code by SMS to \(info.phoneNumber)."
            length = type.length
        case .authenticationCodeTypeSmsWord(let type):
            destination = "Telegram sent an SMS to \(info.phoneNumber). Type the word that starts with “\(type.firstLetter)”."
            length = nil
        case .authenticationCodeTypeSmsPhrase(let type):
            destination = "Telegram sent an SMS to \(info.phoneNumber). Type the phrase that starts with “\(type.firstWord)”."
            length = nil
        case .authenticationCodeTypeCall(let type):
            destination = "Telegram is calling \(info.phoneNumber) to read you the code."
            length = type.length
        case .authenticationCodeTypeFlashCall(let type):
            destination = "Telegram will call \(info.phoneNumber) and hang up. Type the number that called you (it matches \(type.pattern))."
            length = nil
        case .authenticationCodeTypeMissedCall(let type):
            destination = "Telegram will call \(info.phoneNumber). The code is the last \(type.length) digits of the calling number (it starts with \(type.phoneNumberPrefix))."
            length = type.length
        case .authenticationCodeTypeFragment(let type):
            destination = "Telegram sent the code for \(info.phoneNumber) to your anonymous number on Fragment."
            length = type.length
            link = URL(string: type.url).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
        case .authenticationCodeTypeFirebaseAndroid(let type):
            destination = "Telegram is checking this login for \(info.phoneNumber) through its own app. If no code arrives, send the code another way."
            length = type.length
        case .authenticationCodeTypeFirebaseIos(let type):
            destination = "Telegram is checking this login for \(info.phoneNumber) through its own app. If no code arrives, send the code another way."
            length = type.length
        }
        self.link = link
    }

    /// "by SMS", for "Send the code by SMS".
    private static func way(_ type: AuthenticationCodeType) -> String {
        switch type {
        case .authenticationCodeTypeTelegramMessage: "in Telegram"
        case .authenticationCodeTypeSms, .authenticationCodeTypeSmsWord, .authenticationCodeTypeSmsPhrase: "by SMS"
        case .authenticationCodeTypeCall, .authenticationCodeTypeFlashCall, .authenticationCodeTypeMissedCall: "by phone call"
        case .authenticationCodeTypeFragment: "on Fragment"
        case .authenticationCodeTypeFirebaseAndroid, .authenticationCodeTypeFirebaseIos: "another way"
        }
    }
}

enum DeviceInfo {
    /// The Mac's model identifier (e.g. "Mac15,6"), shown in Telegram's list of devices.
    static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let model = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return model.isEmpty ? "Mac" : model
    }()
}
