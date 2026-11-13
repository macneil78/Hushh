import Foundation
import HushCore

/// A short Markdown note per chat about what helps you write to that person: the language, how
/// you address each other, the tone, plans in progress, things worth remembering. Codex keeps it
/// up to date as part of Catch Up and Draft a Reply, which already send it the chat, so it costs
/// no requests of its own. Sealed in the account's vault like transcripts and search indexes;
/// you read, edit or clear it in Chat Info.
public struct ChatMemory: Sendable {
    /// Long enough for a handful of points, short enough to cost little in every request.
    public static let maxLength = 900

    private static let enabledKey = "HushhChatMemory"

    /// On unless you turn it off in Settings → AI.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    static func fileName(_ chatId: Int64) -> String { "memory-\(chatId).md" }

    public func read(_ chatId: Int64) -> String {
        vault.read(Self.fileName(chatId)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Saves the note, trimmed to `maxLength`; an empty one is removed.
    public func write(_ text: String, for chatId: Int64) {
        let text = Self.trimmed(text)
        if text.isEmpty {
            forget(chatId)
        } else {
            try? vault.write(Data(text.utf8), to: Self.fileName(chatId))
        }
    }

    public func forget(_ chatId: Int64) {
        vault.remove(Self.fileName(chatId))
    }

    public func forgetAll() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: vault.directory.path)) ?? []
        for name in names where name.hasPrefix("memory-") && name.hasSuffix(".md") {
            vault.remove(name)
        }
    }

    /// Whole lines up to `maxLength`, so a cut never leaves half a point.
    static func trimmed(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxLength else { return text }
        var kept: [Substring] = []
        var length = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard length + line.count + 1 <= maxLength else { break }
            kept.append(line)
            length += line.count + 1
        }
        return kept.isEmpty ? String(text.prefix(maxLength)) : kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
