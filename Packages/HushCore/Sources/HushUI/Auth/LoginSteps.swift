import CoreImage.CIFilterBuiltins
import HushCore
import SwiftUI

struct QRCodeStep: View {
    let link: String
    let onUsePhoneNumber: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            QRCodeImage(text: link)
                .frame(width: 200, height: 200)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open Telegram on your phone.")
                Text("2. Go to Settings → Devices → Link Desktop Device.")
                Text("3. Point your phone at this code.")
            }
            .font(.callout)
            Button("Log in with phone number instead", action: onUsePhoneNumber)
                .buttonStyle(.link)
        }
    }
}

struct PhoneNumberStep: View {
    let auth: AuthModel
    @State private var phoneNumber = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Enter the phone number of your Telegram account, including the country code.")
                .multilineTextAlignment(.center)
            TextField("+44 7700 900123", text: $phoneNumber)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($isFocused)
                .onSubmit(submit)
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!AuthModel.isPlausiblePhoneNumber(AuthModel.normalizedPhoneNumber(phoneNumber)) || auth.isWorking)
            Button("Log in with QR code instead", action: auth.useQRCode)
                .buttonStyle(.link)
            if auth.canGoBack {
                Button("Back", action: auth.goBack)
                    .buttonStyle(.link)
            }
        }
        .onAppear { isFocused = true }
    }

    private func submit() {
        // Checks the same rule as the button: Return works even while the button is disabled.
        auth.submitPhoneNumber(phoneNumber)
    }
}

struct CodeStep: View {
    let auth: AuthModel
    let prompt: AuthModel.CodePrompt
    @State private var code = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text(prompt.destination)
                .multilineTextAlignment(.center)
            if let link = prompt.link {
                Link(link.absoluteString, destination: link)
                    .font(.callout)
            }
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .onSubmit(submit)
                .onChange(of: code) { _, newValue in
                    if let length = prompt.length, newValue.count == length { submit() }
                }
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || auth.isWorking)
            if let way = prompt.nextWay {
                ResendButton(title: "Send the code \(way)", availableAt: prompt.resendDate, action: auth.resendCode)
            }
            Button("Use a different number", action: auth.useDifferentNumber)
                .buttonStyle(.link)
        }
        .onAppear { isFocused = true }
    }

    private func submit() {
        auth.submitCode(code.trimmingCharacters(in: .whitespaces))
    }
}

/// "Send the code by SMS in 1:59", enabled once Telegram allows it.
struct ResendButton: View {
    let title: String
    let availableAt: Date
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int(availableAt.timeIntervalSince(context.date).rounded(.up))
            Button(remaining > 0 ? "\(title) in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : title, action: action)
                .buttonStyle(.link)
                .disabled(remaining > 0)
                .monospacedDigit()
        }
    }
}

struct PasswordStep: View {
    let auth: AuthModel
    let hint: String
    let recoveryEmail: String?
    @State private var password = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Your account is protected with a password.")
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($isFocused)
                .onSubmit(submit)
            if !hint.isEmpty {
                Text("Hint: \(hint)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || auth.isWorking)
            if recoveryEmail != nil {
                Button("Forgot password?", action: auth.forgotPassword)
                    .buttonStyle(.link)
            }
            Button("Use a different number", action: auth.useDifferentNumber)
                .buttonStyle(.link)
        }
        .onAppear { isFocused = true }
    }

    private func submit() {
        auth.submitPassword(password)
    }
}

struct PasswordRecoveryStep: View {
    let auth: AuthModel
    let emailPattern: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var hint = ""
    @FocusState private var isFocused: Bool

    private var canSubmit: Bool { !code.isEmpty && !newPassword.isEmpty && !auth.isWorking }

    var body: some View {
        VStack(spacing: 14) {
            Text("Telegram emailed a recovery code to \(emailPattern). Enter it and choose a new password.")
                .multilineTextAlignment(.center)
            TextField("Recovery code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .textContentType(.oneTimeCode)
                .focused($isFocused)
            SecureField("New password", text: $newPassword)
                .textFieldStyle(.roundedBorder)
                .textContentType(.newPassword)
            TextField("Hint for the new password (optional)", text: $hint)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            Button("Back", action: auth.goBack)
                .buttonStyle(.link)
        }
        .onAppear { isFocused = true }
    }

    private func submit() {
        auth.recoverPassword(code: code.trimmingCharacters(in: .whitespaces), newPassword: newPassword, hint: hint)
    }
}

struct EmailAddressStep: View {
    let auth: AuthModel
    @State private var email = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Telegram needs an email address for this login. It sends a code there.")
                .multilineTextAlignment(.center)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($isFocused)
                .onSubmit(submit)
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!email.contains("@") || auth.isWorking)
            Button("Use a different number", action: auth.useDifferentNumber)
                .buttonStyle(.link)
        }
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard email.contains("@") else { return }
        auth.submitEmailAddress(email.trimmingCharacters(in: .whitespaces))
    }
}

struct EmailCodeStep: View {
    let auth: AuthModel
    let pattern: String
    let resetNote: String?
    @State private var code = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Enter the code Telegram emailed to \(pattern).")
                .multilineTextAlignment(.center)
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .onSubmit(submit)
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || auth.isWorking)
            Button("Send a new code", action: auth.resendCode)
                .buttonStyle(.link)
            if let resetNote {
                Text(resetNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("I can't open this email", action: auth.resetEmailAddress)
                    .buttonStyle(.link)
            }
            Button("Use a different number", action: auth.useDifferentNumber)
                .buttonStyle(.link)
        }
        .onAppear { isFocused = true }
    }

    private func submit() {
        auth.submitEmailCode(code.trimmingCharacters(in: .whitespaces))
    }
}

/// A crisp QR code for TDLib's login link. TDLib replaces the link every 30 seconds or so.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
        } else {
            Text("Hushh couldn't draw this QR code. Log in with your phone number instead.")
                .font(.callout)
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
        }
    }

    private static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
