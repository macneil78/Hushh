import Foundation
import Testing
@preconcurrency import TDLibKit
@testable import HushCore

/// Login states and texts. States are synthetic; no client is attached, so nothing reaches TDLib.
@MainActor
struct LoginTests {
    static func waitCode(_ type: AuthenticationCodeType, next: AuthenticationCodeType? = nil, timeout: Int = 0) -> AuthorizationState {
        .authorizationStateWaitCode(.init(codeInfo: .init(nextType: next, phoneNumber: "+44 7700 900123", timeout: timeout, type: type)))
    }

    static func waitPassword(recovery: Bool) -> AuthorizationState {
        .authorizationStateWaitPassword(.init(
            hasPassportData: false, hasRecoveryEmailAddress: recovery, passwordHint: "dog", recoveryEmailAddressPattern: recovery ? "a***@e*****.com" : ""
        ))
    }

    static let sms = AuthenticationCodeType.authenticationCodeTypeSms(.init(length: 5))

    @Test func anErrorFromTheLastStepIsClearedOnTheNextStep() {
        let auth = AuthModel(configuration: nil)
        auth.prefersQRCode = false
        auth.apply(.authorizationStateWaitPhoneNumber)
        auth.errorMessage = "That phone number doesn't look right."
        auth.apply(Self.waitPassword(recovery: false))
        #expect(auth.errorMessage == nil)
    }

    // MARK: A way back

    @Test func aWrongNumberCanBeChangedFromTheCodeStep() {
        let auth = AuthModel(configuration: nil)
        let state = Self.waitCode(Self.sms)
        auth.apply(state)
        guard case .code(let prompt) = auth.step else { Issue.record("not on the code step"); return }
        #expect(prompt.phoneNumber == "+44 7700 900123")
        auth.useDifferentNumber()
        #expect(auth.step == .phoneNumber)
        #expect(auth.canGoBack)
        // TDLib may send the same state again; the form stays.
        auth.apply(state)
        #expect(auth.step == .phoneNumber)
        auth.goBack()
        #expect(auth.step == .code(prompt))
    }

    @Test func everyWaitingStepCanGoBackToThePhoneForm() {
        let states: [AuthorizationState] = [
            Self.waitPassword(recovery: true),
            .authorizationStateWaitEmailAddress(.init(allowAppleId: false, allowGoogleId: false)),
            .authorizationStateWaitEmailCode(.init(allowAppleId: false, allowGoogleId: false, codeInfo: .init(emailAddressPattern: "j***@g.com", length: 6), emailAddressResetState: nil)),
            .authorizationStateWaitRegistration(.init(termsOfService: .init(minUserAge: 0, showPopup: false, text: .init(entities: [], text: "")))),
            .authorizationStateWaitPremiumPurchase(.init(premiumDayCount: 30, storeProductId: "x", supportEmailAddress: "", supportEmailSubject: "")),
        ]
        for state in states {
            let auth = AuthModel(configuration: nil)
            auth.apply(state)
            #expect(auth.acceptsPhoneNumber)
            auth.useDifferentNumber()
            #expect(auth.step == .phoneNumber, "\(state)")
        }
    }

    @Test func aNewStateFromTDLibEndsTheDetour() {
        let auth = AuthModel(configuration: nil)
        auth.apply(Self.waitCode(Self.sms))
        auth.useDifferentNumber()
        auth.apply(Self.waitPassword(recovery: false))
        #expect(auth.step == .password(hint: "dog", recoveryEmail: nil))
    }

    @Test func passwordStepOffersRecoveryOnlyWithARecoveryEmail() {
        let auth = AuthModel(configuration: nil)
        auth.apply(Self.waitPassword(recovery: true))
        #expect(auth.step == .password(hint: "dog", recoveryEmail: "a***@e*****.com"))
        auth.apply(Self.waitPassword(recovery: false))
        #expect(auth.step == .password(hint: "dog", recoveryEmail: nil))
    }

    @Test func theNextLoginStartsWithTheQRCodeAgain() {
        let auth = AuthModel(configuration: nil)
        auth.apply(Self.waitCode(Self.sms))
        auth.useDifferentNumber()
        #expect(!auth.prefersQRCode)
        auth.apply(.authorizationStateReady)
        #expect(auth.prefersQRCode)
    }

    // MARK: Code prompts

    @Test func resendWaitsForTelegramsTimeoutAndSaysHow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let prompt = AuthModel.CodePrompt(
            .init(nextType: Self.sms, phoneNumber: "+44 7700 900123", timeout: 120,
                  type: .authenticationCodeTypeTelegramMessage(.init(length: 5))),
            now: now
        )
        #expect(prompt.nextWay == "by SMS")
        #expect(prompt.resendDate == now.addingTimeInterval(120))
        #expect(prompt.destination.contains("+44 7700 900123"))
        let last = AuthModel.CodePrompt(.init(nextType: nil, phoneNumber: "+1", timeout: 0, type: Self.sms))
        #expect(!last.canResend)
    }

    @Test func everyCodeTypeSaysWhereTheCodeWent() {
        let types: [AuthenticationCodeType] = [
            .authenticationCodeTypeFlashCall(.init(pattern: "+0 000 000 ****")),
            .authenticationCodeTypeFirebaseIos(.init(length: 6, pushTimeout: 10, receipt: "r")),
            .authenticationCodeTypeFirebaseAndroid(.init(deviceVerificationParameters: .firebaseDeviceVerificationParametersSafetyNet(.init(nonce: Data())), length: 6)),
            .authenticationCodeTypeTelegramMessage(.init(length: 5)),
        ]
        for type in types {
            let prompt = AuthModel.CodePrompt(.init(nextType: nil, phoneNumber: "+44 7700 900123", timeout: 0, type: type))
            #expect(prompt.destination.contains("+44 7700 900123"), "\(type)")
        }
    }

    @Test func fragmentCodeComesWithItsLink() {
        let url = "https://fragment.com/login/abc"
        let prompt = AuthModel.CodePrompt(.init(nextType: nil, phoneNumber: "+888", timeout: 0, type: .authenticationCodeTypeFragment(.init(length: 5, url: url))))
        #expect(prompt.link == URL(string: url))
        let bad = AuthModel.CodePrompt(.init(nextType: nil, phoneNumber: "+888", timeout: 0, type: .authenticationCodeTypeFragment(.init(length: 5, url: "file:///etc/passwd"))))
        #expect(bad.link == nil)
    }

    // MARK: Error texts

    @Test(arguments: [
        ("Too Many Requests: retry after 86400", "24 h"),
        ("Too Many Requests: retry after 86340", "23 h 59 min"),
        ("FLOOD_WAIT_90", "2 min"),
        ("Too Many Requests: retry after 30", "30 seconds"),
    ])
    func floodWaitSaysHowLongToWait(message: String, wait: String) throws {
        let text = try #require(AuthModel.describe(TDLibKit.Error(code: 429, message: message)))
        #expect(text == "Too many attempts. Try again in \(wait).")
    }

    @Test(arguments: [
        "UPDATE_APP_TO_LOGIN", "PHONE_NUMBER_FLOOD", "PHONE_PASSWORD_FLOOD", "PHONE_NUMBER_UNOCCUPIED",
        "PHONE_CODE_EMPTY", "SESSION_PASSWORD_NEEDED", "API_ID_INVALID", "AUTH_RESTART", "SOME_NEW_CONSTANT_42",
    ])
    func noRawTelegramConstantsReachTheUser(raw: String) throws {
        let text = try #require(AuthModel.describe(TDLibKit.Error(code: 400, message: raw)))
        #expect(!text.contains(raw))
        #expect(!text.contains("_"))
    }

    /// TDLib: a 406 error "must not be displayed to the user".
    @Test func code406IsNotShown() {
        #expect(AuthModel.describe(TDLibKit.Error(code: 406, message: "UPDATE_APP_TO_LOGIN")) == nil)
    }

    @Test func aNonTDLibErrorShowsNoTypeNames() throws {
        struct Boom: Swift.Error {}
        let text = try #require(AuthModel.describe(Boom()))
        #expect(!text.contains("Boom") && !text.contains("HushCoreTests"))
        // Errors with a real description keep it.
        #expect(AuthModel.describe(CocoaError(.fileNoSuchFile))?.isEmpty == false)
    }

    // MARK: Phone numbers

    @Test(arguments: [
        ("+44 7700 900123", "+447700900123"),
        ("+44-7700-900-123", "+447700900123"),
        ("0044 7700 900123", "+447700900123"),
        ("+٤٤ ٧٧٠٠ ٩٠٠١٢٣", "+447700900123"),
        ("+۴۴ ۷۷۰۰ ۹۰۰۱۲۳", "+447700900123"),
        ("＋４４ ７７００ ９００１２３", "+447700900123"),
        ("+44 ½ 7700 900123", "+447700900123"),
        ("44 (7700) 900+123", "447700900123"),
    ])
    func phoneNumbersAreSentAsASCIIDigits(input: String, expected: String) {
        #expect(AuthModel.normalizedPhoneNumber(input) == expected)
    }

    @Test func fractionsAndRomanNumeralsAreNotDigits() {
        #expect(!AuthModel.isPlausiblePhoneNumber(AuthModel.normalizedPhoneNumber("½½½½½")))
        #expect(!AuthModel.isPlausiblePhoneNumber(AuthModel.normalizedPhoneNumber("ⅠⅡⅢⅣⅤ")))
        #expect(!AuthModel.isPlausiblePhoneNumber(AuthModel.normalizedPhoneNumber("")))
    }

    // MARK: Credentials

    @Test func credentialsSayWhichValueIsWrong() {
        let hash = String(repeating: "a", count: 32)
        #expect(throws: TDConfiguration.LoadError.missingId) { try TDConfiguration.parse(id: "", hash: hash) }
        #expect(throws: TDConfiguration.LoadError.invalidId) { try TDConfiguration.parse(id: "\"12345\"", hash: hash) }
        #expect(throws: TDConfiguration.LoadError.invalidId) { try TDConfiguration.parse(id: "-5", hash: hash) }
        #expect(throws: TDConfiguration.LoadError.missingHash) { try TDConfiguration.parse(id: "12345", hash: "") }
        #expect(throws: TDConfiguration.LoadError.invalidHash(length: 33)) { try TDConfiguration.parse(id: "12345", hash: hash + " ") }
        #expect(throws: TDConfiguration.LoadError.invalidHash(length: 32)) { try TDConfiguration.parse(id: "12345", hash: String(repeating: "g", count: 32)) }
        #expect((try? TDConfiguration.parse(id: "12345", hash: hash)) == 12345)
        // The text names the setting and never repeats the secret.
        #expect(!TDConfiguration.LoadError.invalidHash(length: 33).description.contains(hash))
    }

    @Test func anAppWithoutCredentialsSaysWhatIsMissing() {
        // The test bundle has no HushTelegramAPIId key.
        let model = AppModel(loadingFrom: Bundle(for: BundleMarker.self))
        #expect(model.state == .needsCredentials)
        #expect(model.credentialsProblem == .missingId)
    }
}

private final class BundleMarker {}
