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
        case password(hint: String)
        case emailAddress
        case emailCode(pattern: String)
        case registrationUnsupported
        case premiumRequired
        case ready
        case loggingOut
        case failed(String)
    }

    public struct CodePrompt: Equatable, Sendable {
        public let phoneNumber: String
        /// Where Telegram sent the code, phrased for the login screen.
        public let destination: String
        /// Expected code length, when Telegram says.
        public let length: Int?
        public let canResend: Bool
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

    init(configuration: TDConfiguration?) {
        self.configuration = configuration
    }

    func attach(_ client: TDLibClient) {
        self.client = client
        step = .starting
        errorMessage = nil
    }

    func apply(_ state: AuthorizationState) {
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
            step = .code(CodePrompt(state.codeInfo))
        case .authorizationStateWaitPassword(let state):
            step = .password(hint: state.passwordHint)
        case .authorizationStateWaitEmailAddress:
            step = .emailAddress
        case .authorizationStateWaitEmailCode(let state):
            step = .emailCode(pattern: state.codeInfo.emailAddressPattern)
        case .authorizationStateWaitRegistration:
            step = .registrationUnsupported
        case .authorizationStateWaitPremiumPurchase:
            step = .premiumRequired
        case .authorizationStateReady:
            step = .ready
        case .authorizationStateLoggingOut:
            step = .loggingOut
        case .authorizationStateClosing, .authorizationStateClosed:
            step = .starting
        }
    }

    // MARK: Actions

    public func submitPhoneNumber(_ phoneNumber: String) {
        let number = phoneNumber.filter { $0.isNumber || $0 == "+" }
        run { _ = try await $0.setAuthenticationPhoneNumber(phoneNumber: number, settings: nil) }
    }

    public func submitCode(_ code: String) {
        run { _ = try await $0.checkAuthenticationCode(code: code) }
    }

    public func submitPassword(_ password: String) {
        run { _ = try await $0.checkAuthenticationPassword(password: password) }
    }

    public func submitEmailAddress(_ emailAddress: String) {
        run { _ = try await $0.setAuthenticationEmailAddress(emailAddress: emailAddress) }
    }

    public func submitEmailCode(_ code: String) {
        let authentication = EmailAddressAuthentication.emailAddressAuthenticationCode(.init(code: code))
        run { _ = try await $0.checkAuthenticationEmailCode(code: authentication) }
    }

    public func resendCode() {
        run { _ = try await $0.resendAuthenticationCode(reason: nil) }
    }

    public func useQRCode() {
        prefersQRCode = true
        run { _ = try await $0.requestQrCodeAuthentication(otherUserIds: []) }
    }

    public func logOut() {
        run { _ = try await $0.logOut() }
    }

    // MARK: Private

    private func sendParameters() {
        guard let configuration else { return }
        let key: Data
        do {
            key = try DatabaseKey.loadOrCreate()
            for directory in [configuration.databaseDirectory, configuration.filesDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            step = .failed("Hushh couldn't prepare its local database: \(error)")
            return
        }
        guard let client else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
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
                errorMessage = Self.describe(error)
            }
        }
    }

    private func run(_ action: @escaping @Sendable (TDLibClient) async throws -> Void) {
        guard let client else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await action(client)
            } catch {
                errorMessage = Self.describe(error)
            }
        }
    }

    static func describe(_ error: any Swift.Error) -> String {
        guard let error = error as? TDLibKit.Error else { return error.localizedDescription }
        switch error.message {
        case "PHONE_NUMBER_INVALID":
            return "That phone number doesn't look right. Include the country code, like +44 7700 900123."
        case "PHONE_CODE_INVALID":
            return "That code isn't right. Check it and try again."
        case "PHONE_CODE_EXPIRED":
            return "That code has expired. Ask for a new one."
        case "PASSWORD_HASH_INVALID":
            return "Wrong password."
        case "PHONE_NUMBER_BANNED":
            return "Telegram has banned this phone number."
        case "EMAIL_CODE_INVALID":
            return "That email code isn't right."
        case "EMAIL_INVALID", "EMAIL_ADDRESS_INVALID":
            return "That email address doesn't look right."
        default:
            if error.code == 429 || error.message.hasPrefix("FLOOD_WAIT") || error.message.hasPrefix("Too Many Requests") {
                return "Too many attempts. Wait a while, then try again."
            }
            return error.message
        }
    }
}

extension AuthModel.CodePrompt {
    init(_ info: AuthenticationCodeInfo) {
        phoneNumber = info.phoneNumber
        canResend = info.nextType != nil
        switch info.type {
        case .authenticationCodeTypeTelegramMessage(let type):
            destination = "Telegram sent the code to your other devices. Check the Telegram app on your phone."
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
        case .authenticationCodeTypeMissedCall(let type):
            destination = "Telegram will call \(info.phoneNumber). The code is the last \(type.length) digits of the calling number (it starts with \(type.phoneNumberPrefix))."
            length = type.length
        case .authenticationCodeTypeFragment(let type):
            destination = "Telegram sent the code to your anonymous number on Fragment: \(type.url)"
            length = type.length
        default:
            destination = "Telegram sent you a login code. Check your phone."
            length = nil
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
