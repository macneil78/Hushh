import Foundation
import Testing
@testable import HushAI

/// The session plumbing (requests in on standard input, the answer out as it's written), with a
/// stand-in for the bridge that answers without Codex.
@MainActor
struct CodexSessionTests {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hush-test-bridge-\(UUID().uuidString).sh")
        try ("#!/bin/zsh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func oneSessionAnswersRequestAfterRequestAsTheyAreWritten() async throws {
        let bridge = try script("""
        [[ $1 == --session && $2 == gpt-6-luna ]] || exit 2
        print '{"hushh":"ready"}'
        while read -r request; do
            answer=$(/usr/bin/jq -r .answer <<< "$request")
            words=$(/usr/bin/jq -r '.images | length' <<< "$request")
            print '{"method":"item/agentMessage/delta","params":{"delta":"Hel","itemId":"a","threadId":"t","turnId":"u"}}'
            print '{"method":"item/agentMessage/delta","params":{"delta":"lo","itemId":"a","threadId":"t","turnId":"u"}}'
            print -n "Hello $words" > "$answer"
            print '{"hushh":"done","status":"completed"}'
            print '{"hushh":"ready"}'
        done
        """)
        defer { try? FileManager.default.removeItem(at: bridge) }
        let session = try CodexSession(script: bridge, model: .luna)
        for images in [["/a.jpg"], []] {
            let answer = FileManager.default.temporaryDirectory.appending(path: "hush-test-answer-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: answer) }
            let request = try JSONSerialization.data(withJSONObject: ["prompt": "/p", "answer": answer.path, "errors": "/e", "effort": "low", "images": images])
            var pieces: [String] = []
            let failure = await session.run(request) { item, delta in
                #expect(item == "a")
                pieces.append(delta)
            }
            #expect(failure == nil)
            #expect(pieces == ["Hel", "lo"])
            #expect(try String(contentsOf: answer, encoding: .utf8) == "Hello \(images.count)")
            #expect(session.isIdle)
        }
        session.close()
    }

    @Test func aSessionThatCantStartSaysWhy() async throws {
        let bridge = try script("""
        print '{"hushh":"failed","message":"Codex isn'"'"'t installed."}'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: bridge) }
        let session = try CodexSession(script: bridge, model: .sol)
        let failure = await session.run(Data("{}".utf8)) { _, _ in }
        #expect(failure == "Codex isn't installed.")
        #expect(!session.isRunning)
        // Asking again doesn't wait on a session that's gone.
        #expect(await session.run(Data("{}".utf8)) { _, _ in } == "Codex isn't installed.")
    }

    @Test func bridgeLinesAreRead() {
        #expect(CodexSession.line(#"{"hushh":"ready"}"#) == nil)
        #expect(CodexSession.line(#"{"hushh":"done","status":"failed"}"#) == .done)
        #expect(CodexSession.line(#"{"hushh":"failed","message":"Codex took too long to answer. Try again."}"#) == .failed("Codex took too long to answer. Try again."))
        #expect(CodexSession.line(#"{"method":"item/agentMessage/delta","params":{"delta":"Hi","itemId":"x"}}"#) == .piece(item: "x", delta: "Hi"))
        #expect(CodexSession.line("garbage") == nil)
    }
}
