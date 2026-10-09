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

    var body: some View {
        VStack(spacing: 14) {
            Text("Enter the phone number of your Telegram account, including the country code.")
                .multilineTextAlignment(.center)
            TextField("+44 7700 900123", text: $phoneNumber)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit(submit)
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(phoneNumber.filter(\.isNumber).count < 5)
            Button("Log in with QR code instead", action: auth.useQRCode)
                .buttonStyle(.link)
        }
    }

    private func submit() {
        auth.submitPhoneNumber(phoneNumber)
    }
}

struct CodeStep: View {
    let auth: AuthModel
    let prompt: AuthModel.CodePrompt
    @State private var code = ""

    var body: some View {
        VStack(spacing: 14) {
            Text(prompt.destination)
                .multilineTextAlignment(.center)
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .textContentType(.oneTimeCode)
                .onSubmit(submit)
                .onChange(of: code) { _, newValue in
                    if let length = prompt.length, newValue.count == length { submit() }
                }
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty)
            if prompt.canResend {
                Button("Send the code another way", action: auth.resendCode)
                    .buttonStyle(.link)
            }
        }
    }

    private func submit() {
        auth.submitCode(code.trimmingCharacters(in: .whitespaces))
    }
}

struct PasswordStep: View {
    let auth: AuthModel
    let hint: String
    @State private var password = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Your account is protected with a password.")
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit(submit)
            if !hint.isEmpty {
                Text("Hint: \(hint)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        }
    }

    private func submit() {
        auth.submitPassword(password)
    }
}

struct EmailAddressStep: View {
    let auth: AuthModel
    @State private var email = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Telegram needs an email address for this login. It sends a code there.")
                .multilineTextAlignment(.center)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit(submit)
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!email.contains("@"))
        }
    }

    private func submit() {
        auth.submitEmailAddress(email.trimmingCharacters(in: .whitespaces))
    }
}

struct EmailCodeStep: View {
    let auth: AuthModel
    let pattern: String
    @State private var code = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Enter the code Telegram emailed to \(pattern).")
                .multilineTextAlignment(.center)
            TextField("Code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .textContentType(.oneTimeCode)
                .onSubmit(submit)
            Button("Continue", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty)
            Button("Send a new code", action: auth.resendCode)
                .buttonStyle(.link)
        }
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
            Color.clear
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
