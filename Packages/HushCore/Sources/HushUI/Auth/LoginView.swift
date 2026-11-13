import HushCore
import SwiftUI

struct LoginView: View {
    let model: AppModel
    private var auth: AuthModel { model.auth }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Hushh")
                    .font(.largeTitle.weight(.semibold))
                Text("Your Telegram chats, without the noise.")
                    .foregroundStyle(.secondary)
            }
            step
                .frame(maxWidth: 340)
            if let message = auth.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 340)
            }
            // Offline, TDLib holds requests until it can send them: say so, or the screen looks hung.
            if let status = model.connectionStatus, auth.step != .ready {
                Label(status, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            // Telegram's API terms ask third-party apps to say this up front.
            Text("Unofficial client using the Telegram API.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        // Only the Continue buttons wait for a request (each step disables its own), so text
        // fields keep keyboard focus after a failed attempt and the other ways out stay usable.
    }

    @ViewBuilder private var step: some View {
        switch auth.step {
        case .starting, .ready:
            ProgressView()
        case .qrCode(let link):
            QRCodeStep(link: link, onUsePhoneNumber: model.logInWithPhoneNumber)
        case .phoneNumber:
            PhoneNumberStep(auth: auth)
        case .code(let prompt):
            CodeStep(auth: auth, prompt: prompt)
        case .password(let hint, let recoveryEmail):
            PasswordStep(auth: auth, hint: hint, recoveryEmail: recoveryEmail)
        case .passwordRecovery(let emailPattern):
            PasswordRecoveryStep(auth: auth, emailPattern: emailPattern)
        case .emailAddress:
            EmailAddressStep(auth: auth)
        case .emailCode(let pattern, let resetNote):
            EmailCodeStep(auth: auth, pattern: pattern, resetNote: resetNote)
        case .registrationUnsupported:
            MessageStep(
                message: "There's no Telegram account for this number yet. Sign up in the official Telegram app first, then log in here.",
                actionTitle: "Use a Different Number",
                action: auth.useDifferentNumber
            )
        case .premiumRequired:
            MessageStep(
                message: "Telegram won't text a login code to this number without Premium. Log in with a QR code from your phone instead.",
                actionTitle: "Use QR Code",
                action: auth.useQRCode,
                secondaryTitle: "Use a different number",
                secondaryAction: auth.useDifferentNumber
            )
        case .loggingOut:
            ProgressView("Logging out…")
        case .failed(let message):
            MessageStep(
                message: message,
                actionTitle: "Try Again",
                action: model.tryAgain,
                secondaryTitle: "Log in with phone number instead",
                secondaryAction: model.logInWithPhoneNumber
            )
        }
    }
}

struct MessageStep: View {
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .keyboardShortcut(.defaultAction)
            }
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.link)
            }
        }
    }
}
