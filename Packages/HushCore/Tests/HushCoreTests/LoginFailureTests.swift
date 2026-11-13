import AppKit
import Foundation
import SwiftUI
import Testing
@preconcurrency import TDLibKit
@testable import HushCore
@testable import HushUI

/// Login against a real TDLib client that never gets setTdlibParameters: it has no API ID, so it
/// can't reach Telegram, and it fails auth requests locally.
@MainActor
struct LoginFailureTests {
    /// When the QR request fails while the start-up spinner shows, the screen offers Try Again.
    @Test func aFailedFirstRequestOffersTryAgain() async throws {
        let session = TDSession()
        let model = AppModel(configuration: nil)
        model.auth.attach(session.client)
        model.auth.apply(.authorizationStateWaitPhoneNumber)  // asks for a QR code
        try await Task.sleep(for: .milliseconds(300))
        _ = try? await session.client.close()  // TDLib now fails the held request
        // Under a loaded test run TDLib can take seconds to answer.
        await Fixtures.wait(upTo: 10) { if case .failed = model.auth.step { true } else { false } }
        guard case .failed(let message) = model.auth.step else {
            Issue.record("step is \(model.auth.step)")
            return
        }
        #expect(!message.isEmpty)
        #expect(!model.auth.isWorking)
    }

    /// The code field keeps keyboard focus through a failed request: the screen stays enabled
    /// while the request runs.
    @Test func focusSurvivesAFailedSubmit() async throws {
        let session = TDSession()
        let model = AppModel(configuration: nil)
        model.auth.attach(session.client)
        model.auth.apply(LoginTests.waitCode(LoginTests.sms, next: .authenticationCodeTypeCall(.init(length: 5))))
        let window = TestWindow.host(LoginView(model: model).frame(width: 760, height: 560), width: 760, height: 560)
        defer { TestWindow.close(window) }
        await TestWindow.settle()
        let fields = TestWindow.views(NSTextField.self, in: window.contentView!).filter(\.isEditable)
        let field = try #require(fields.first)
        window.makeFirstResponder(field)
        try await Task.sleep(for: .milliseconds(100))
        try #require(field.currentEditor() != nil, "precondition: field focused")
        model.auth.resendCode()  // TDLib refuses it: no parameters were sent
        #expect(model.auth.isWorking)
        try await Task.sleep(for: .milliseconds(300))
        _ = try? await session.client.close()
        await Fixtures.wait(upTo: 10) { !model.auth.isWorking }
        #expect(!model.auth.isWorking)
        #expect(field.isEnabled)
        #expect(model.auth.errorMessage != nil)
        #expect(field.currentEditor() != nil, "field lost focus after the failed request")
    }
}
