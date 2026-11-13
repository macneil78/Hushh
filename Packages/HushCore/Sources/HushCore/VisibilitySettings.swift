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

    /// What a saved file holds, read one entry at a time: a value this build doesn't know (from
    /// a newer build, or a hand edit) costs that entry only, never the whole file.
    private struct Tolerant: Decodable {
        var choices: [String: Entry] = [:]
        var hasChosenGroupsAndBots: Bool?
        /// Whether something present couldn't be read at all.
        var isDamaged = false

        struct Entry: Decodable {
            var choice: VisibilityChoice?
            init(from decoder: Decoder) throws {
                choice = try? decoder.singleValueContainer().decode(VisibilityChoice.self)
            }
        }

        enum CodingKeys: CodingKey {
            case choices, hasChosenGroupsAndBots
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                choices = try container.decodeIfPresent([String: Entry].self, forKey: .choices) ?? [:]
            } catch {
                isDamaged = true
            }
            do {
                hasChosenGroupsAndBots = try container.decodeIfPresent(Bool.self, forKey: .hasChosenGroupsAndBots)
            } catch {
                isDamaged = true
            }
        }
    }

    func load(from url: URL) {
        fileURL = url
        choices = [:]
        hasChosenGroupsAndBots = false
        isLoaded = true
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            // Saving now would replace choices that are still in the file: keep them for this
            // session only.
            fileURL = nil
            Log.chats.error("Couldn't read visibility choices, so they won't be saved this session: \(String(describing: error), privacy: .public)")
            return
        }
        guard !data.isEmpty else { return }
        guard let stored = try? JSONDecoder().decode(Tolerant.self, from: data) else {
            keepCopy(of: data, at: url, reason: "it isn't a settings file")
            return
        }
        var skipped = 0
        for (key, entry) in stored.choices {
            guard let chatId = Int64(key), let choice = entry.choice else {
                skipped += 1
                continue
            }
            // "1" and "01" are one chat. If they disagree, hiding wins: it's the calmer choice.
            choices[chatId] = choices[chatId] == .hide ? .hide : choice
        }
        hasChosenGroupsAndBots = stored.hasChosenGroupsAndBots ?? false
        if skipped > 0 || stored.isDamaged {
            keepCopy(of: data, at: url, reason: "\(skipped) choices couldn't be read")
        }
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

    /// The next save writes only what could be read, so the file as it was is kept beside it
    /// (`visibility.json.unreadable`) for you or a later build to recover.
    private func keepCopy(of data: Data, at url: URL, reason: String) {
        let copy = url.appendingPathExtension("unreadable")
        do {
            try data.write(to: copy, options: .atomic)
            Log.chats.error("Visibility choices only partly read (\(reason, privacy: .public)); the file is kept at \(copy.lastPathComponent, privacy: .public)")
        } catch {
            Log.chats.error("Visibility choices only partly read (\(reason, privacy: .public)), and keeping a copy failed: \(String(describing: error), privacy: .public)")
        }
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
