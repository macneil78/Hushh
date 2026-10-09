import Testing
@preconcurrency import TDLibKit
@testable import HushCore

@MainActor
struct TDSessionTests {
    /// TDLibKit delivers replies on a background queue. Sending from main-actor code, as the app
    /// does, must not trap Swift 6's isolation check when the reply arrives.
    @Test func replyToARequestSentFromTheMainActorArrivesSafely() async {
        let session = TDSession()
        await withCheckedContinuation { continuation in
            session.sendIgnoringReply(GetOption(name: "version"), onReply: { continuation.resume() })
        }
        _ = try? await session.client.close()
    }
}
