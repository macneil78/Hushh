import Foundation
import Observation

/// Your per-chat show/hide choices, saved per account as JSON. They live only on this Mac.
@MainActor @Observable
final class VisibilitySettings {
    private(set) var choices: [Int64: VisibilityChoice] = [:]
    /// Whether you've been through the "Choose Chats" sheet once.
    private(set) var hasChosenGroupsAndBots = false
    private(set) var isLoaded = false

    @ObservationIgnored private var fileURL: URL?

    private struct Stored: Codable {
        // JSON object keys must be strings.
        var choices: [String: VisibilityChoice]
        var hasChosenGroupsAndBots: Bool
    }

    func load(from url: URL) {
        fileURL = url
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            choices = Dictionary(uniqueKeysWithValues: stored.choices.compactMap { key, value in
                Int64(key).map { ($0, value) }
            })
            hasChosenGroupsAndBots = stored.hasChosenGroupsAndBots
        } else {
            choices = [:]
            hasChosenGroupsAndBots = false
        }
        isLoaded = true
    }

    func setChoice(_ choice: VisibilityChoice?, for chatId: Int64) {
        guard choices[chatId] != choice else { return }
        choices[chatId] = choice
        save()
    }

    func markChosen() {
        guard !hasChosenGroupsAndBots else { return }
        hasChosenGroupsAndBots = true
        save()
    }

    func reset() {
        fileURL = nil
        choices = [:]
        hasChosenGroupsAndBots = false
        isLoaded = false
    }

    private func save() {
        guard let fileURL else { return }
        let stored = Stored(
            choices: Dictionary(uniqueKeysWithValues: choices.map { (String($0.key), $0.value) }),
            hasChosenGroupsAndBots: hasChosenGroupsAndBots
        )
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            Log.chats.error("Couldn't save visibility choices: \(String(describing: error), privacy: .public)")
        }
    }
}
