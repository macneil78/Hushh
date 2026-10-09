import HushCore
import SwiftUI

struct LoginView: View {
    let model: AppModel
    private var auth: AuthModel { model.auth }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Text("Hush")
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
                    .frame(maxWidth: 340)
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
        .disabled(auth.isWorking)
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
        case .password(let hint):
            PasswordStep(auth: auth, hint: hint)
        case .emailAddress:
            EmailAddressStep(auth: auth)
        case .emailCode(let pattern):
            EmailCodeStep(auth: auth, pattern: pattern)
        case .registrationUnsupported:
            MessageStep(
                message: "There's no Telegram account for this number yet. Sign up in the official Telegram app first, then log in here.",
                actionTitle: "Start Over",
                action: model.logInWithPhoneNumber
            )
        case .premiumRequired:
            MessageStep(
                message: "Telegram won't text a login code to this number without Premium. Log in with a QR code from your phone instead.",
                actionTitle: "Use QR Code",
                action: auth.useQRCode
            )
        case .loggingOut:
            ProgressView("Logging out…")
        case .failed(let message):
            MessageStep(message: message, actionTitle: nil, action: nil)
        }
    }
}

struct MessageStep: View {
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
