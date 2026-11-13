import CryptoKit
import Foundation
import Testing
@testable import HushAI
@testable import HushCore

struct ChatMemoryTests {
    private func vault() throws -> LocalVault {
        let folder = FileManager.default.temporaryDirectory.appending(path: "memory-test-\(UUID().uuidString)")
        return LocalVault(directory: folder, key: SymmetricKey(size: .bits256))
    }

    @Test func theAnswerAndTheMemoryAreSplitApart() {
        let answer = """
        да, смогу) скинь номер рейса

        === MEMORY ===
        - Пишем по-русски, коротко.
        - Lucas прилетает в субботу.
        """
        let (text, memory) = ChatAssistant.splitMemory(answer)
        #expect(text == "да, смогу) скинь номер рейса")
        #expect(memory == "- Пишем по-русски, коротко.\n- Lucas прилетает в субботу.")
        #expect(ChatAssistant.splitMemory("just a reply").memory == nil)
        #expect(ChatAssistant.splitMemory("reply\n===MEMORY===\n- note").memory == "- note")
    }

    @Test func promptsAskForMemoryOnlyWhenItsOn() {
        let on = ChatAssistant.draftPrompt(chatTitle: "Lucas", transcript: "", hint: nil, memory: "- Пишем по-русски")
        #expect(on.contains("=== MEMORY ==="))
        #expect(on.contains("Current memory (also background for your answer):\n- Пишем по-русски"))
        #expect(ChatAssistant.summaryPrompt(chatTitle: "Lucas", transcript: "", unreadCount: 0, memory: "").contains("(none yet)"))
        #expect(!ChatAssistant.draftPrompt(chatTitle: "Lucas", transcript: "", hint: nil).contains("MEMORY"))
    }

    @Test func memoryIsKeptSealedPerChat() throws {
        let vault = try vault()
        defer { try? FileManager.default.removeItem(at: vault.directory) }
        let memory = ChatMemory(vault: vault)
        memory.write("  - Calls me Sasha\n", for: 42)
        #expect(memory.read(42) == "- Calls me Sasha")
        #expect(memory.read(7) == "")
        let onDisk = try Data(contentsOf: vault.directory.appending(path: "memory-42.md"))
        #expect(String(data: onDisk, encoding: .utf8)?.contains("Sasha") != true)

        memory.write("", for: 42)
        #expect(!FileManager.default.fileExists(atPath: vault.directory.appending(path: "memory-42.md").path))

        memory.write("- a", for: 1)
        memory.write("- b", for: 2)
        try vault.write(Data("index".utf8), to: "search-1.index")
        memory.forgetAll()
        #expect(memory.read(1).isEmpty && memory.read(2).isEmpty)
        #expect(vault.read("search-1.index") != nil)
    }

    @Test func longMemoryIsCutAtAWholeLine() {
        let lines = (1...40).map { "- point number \($0) about this chat" }.joined(separator: "\n")
        let trimmed = ChatMemory.trimmed(lines)
        #expect(trimmed.count <= ChatMemory.maxLength)
        #expect(trimmed.hasSuffix("about this chat"))
    }
}
