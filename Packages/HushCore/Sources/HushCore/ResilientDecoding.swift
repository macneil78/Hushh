@preconcurrency import TDLibKit
import Foundation

/// TDLibKit's generated models sometimes require a field TDLib leaves out (a gift's
/// `background`, for one), or meet a type a newer TDLib added, and then a whole update or reply
/// fails to decode: a chat whose last message is a gift never reaches the list, and its history
/// won't load. When that happens, repair only the part that can't be read, and try again, so one
/// odd field never hides a chat or a page of history:
/// - a message content TDLibKit can't read becomes a stand-in ("🎁 Gift" or "unsupported");
/// - an unreadable optional part is left out (TDLib may leave it null anyway);
/// - an unreadable item of a list is dropped (one reaction, one chat position, one message of a page);
/// - a required field of a kind TDLibKit doesn't know gets TDLib's "unknown" value where there is
///   one (a user's status becomes "empty");
/// - a required field that is missing or null, with nothing around it that may be left out, gets
///   an empty value (0, "", false, an empty list or object).
/// Each repair is logged, by path only. A field with no "unknown" value that can't be left out (a
/// chat's type, a message's sender) still fails: Hushh can't show what it doesn't know.
enum ResilientDecoding {
    /// Past this many repairs, or this many decoding attempts, the reply is too broken to trust.
    private static let maxRepairs = 64
    private static let maxAttempts = 256

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let originalError {
            guard var json = try? JSONSerialization.jsonObject(with: data) else { throw originalError }
            let kind = (json as? [String: Any])?["@type"] as? String ?? "\(T.self)"
            var repairs: [String] = []
            json = replaceUnreadableContents(json, path: [], decoder: decoder, repairs: &repairs)
            var attempts = 0
            while repairs.count <= maxRepairs, attempts < maxAttempts {
                attempts += 1
                let error: DecodingError
                switch attempt(type, json, decoder) {
                case .decoded(let value):
                    Log.session.notice("Repaired \(kind, privacy: .public), which TDLibKit can't decode: \(repairs.joined(separator: "; "), privacy: .public)")
                    return value
                case .failed(let failure):
                    error = failure
                case .unreadable:
                    throw originalError
                }
                guard let (repaired, note) = repair(json, failingWith: error, type: type, decoder: decoder, attempts: &attempts) else { break }
                json = repaired
                repairs.append(note)
            }
            Log.session.error("Couldn't repair \(kind, privacy: .public), which TDLibKit can't decode, after: \(repairs.joined(separator: "; "), privacy: .public)")
            throw originalError
        }
    }

    // MARK: Message contents

    /// Walks the JSON once, testing every message content on its own. The common case (gifts),
    /// and much cheaper than finding them one decoding error at a time.
    private static func replaceUnreadableContents(_ value: Any, path: [Step], decoder: JSONDecoder, repairs: inout [String]) -> Any {
        if var object = value as? [String: Any] {
            for (key, child) in object {
                if key == "content", let content = child as? [String: Any],
                   let type = content["@type"] as? String, type.hasPrefix("message"),
                   !decodes(content, decoder: decoder) {
                    object[key] = standIn(for: type)
                    repairs.append("replaced \(describe(path + [.key(key)]))")
                } else {
                    object[key] = replaceUnreadableContents(child, path: path + [.key(key)], decoder: decoder, repairs: &repairs)
                }
            }
            return object
        }
        if let array = value as? [Any] {
            return array.enumerated().map { replaceUnreadableContents($1, path: path + [.index($0)], decoder: decoder, repairs: &repairs) }
        }
        return value
    }

    private static func decodes(_ content: [String: Any], decoder: JSONDecoder) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: content) else { return false }
        return (try? decoder.decode(MessageContent.self, from: data)) != nil
    }

    /// Gifts become a grey "🎁 Gift" line, as Hushh shows them anyway; anything else an
    /// "unsupported message" placeholder.
    private static func standIn(for type: String) -> [String: Any] {
        type.localizedCaseInsensitiveContains("gift")
            ? ["@type": "messageCustomServiceAction", "text": "🎁 Gift"]
            : ["@type": "messageUnsupported"]
    }

    // MARK: Any other part

    /// One step into the JSON: a key of an object, or an item of a list.
    private enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    /// Finds the smallest change that gets past `error`: first leaving out the innermost part
    /// around the failure that may be left out, then filling in a missing required field.
    private static func repair<T: Decodable>(
        _ json: Any, failingWith error: DecodingError, type: T.Type, decoder: JSONDecoder, attempts: inout Int
    ) -> (Any, String)? {
        guard let failure = location(of: error, in: json) else { return nil }
        let isMissing: Bool = switch error {
        case .keyNotFound, .valueNotFound: true
        default: false
        }
        // From the failing field outwards.
        for length in stride(from: failure.count, through: 1, by: -1) {
            let place = Array(failure.prefix(length))
            switch place.last {
            case .index:
                // Leaving an item out of a list never breaks the list.
                return (setting(json, at: place, to: nil), "dropped \(describe(place))")
            case .key("@type"):
                continue
            case .key("content") where messageType(at: place, in: json) != nil:
                let candidate = setting(json, at: place, to: standIn(for: messageType(at: place, in: json) ?? ""))
                if gotPast(place, candidate, type, decoder, attempts: &attempts) {
                    return (candidate, "replaced \(describe(place))")
                }
            case .key:
                // A missing field is already left out; a null one may not be.
                if place == failure, isMissing, value(in: json, at: place) == nil { continue }
                let candidate = setting(json, at: place, to: nil)
                if gotPast(place, candidate, type, decoder, attempts: &attempts) {
                    return (candidate, "left out \(describe(place))")
                }
            case nil:
                return nil
            }
        }
        // Nothing around it may be left out. A required field of a kind TDLibKit doesn't know (or
        // none) gets TDLib's own "no information" value, where there is one.
        let field = failure.last == .key("@type") ? Array(failure.dropLast()) : failure
        if case .key(let key) = field.last,
           let parentType = (value(in: json, at: Array(field.dropLast())) as? [String: Any])?["@type"] as? String,
           let neutral = neutralValues["\(parentType).\(key)"] {
            let candidate = setting(json, at: field, to: neutral)
            if gotPast(field, candidate, type, decoder, attempts: &attempts) {
                return (candidate, "replaced \(describe(field))")
            }
        }
        // Otherwise give a missing required field an empty value. An empty object fails again on
        // its own first field, which the next round fills in.
        guard isMissing else { return nil }
        for empty in [0, "", false, [Any](), [String: Any](), "0"] as [Any] {
            let candidate = setting(json, at: failure, to: empty)
            attempts += 1
            switch attempt(type, candidate, decoder) {
            case .decoded:
                return (candidate, "filled \(describe(failure))")
            case .failed(let next):
                if let place = location(of: next, in: candidate), place != failure {
                    return (candidate, "filled \(describe(failure))")
                }
            case .unreadable:
                return nil
            }
        }
        return nil
    }

    /// For required fields Hushh reads, keyed "parent @type.field": the value that means "unknown".
    /// A chat's type or a message's sender has none, so those still fail.
    private static var neutralValues: [String: [String: Any]] {
        [
            "message.content": ["@type": "messageUnsupported"],
            "user.status": ["@type": "userStatusEmpty"],
            "updateUserStatus.status": ["@type": "userStatusEmpty"],
            "user.type": ["@type": "userTypeUnknown"],
            // No reactions offered, rather than guessing which.
            "chat.available_reactions": ["@type": "chatAvailableReactionsSome", "reactions": [Any](), "max_reaction_count": 0],
        ]
    }

    /// Whether, after changing `place`, decoding fails somewhere else, or not at all.
    private static func gotPast<T: Decodable>(_ place: [Step], _ json: Any, _ type: T.Type, _ decoder: JSONDecoder, attempts: inout Int) -> Bool {
        attempts += 1
        switch attempt(type, json, decoder) {
        case .decoded: return true
        case .failed(let error): return location(of: error, in: json).map { !$0.starts(with: place) } ?? false
        case .unreadable: return false
        }
    }

    private enum Attempt<T> {
        case decoded(T)
        case failed(DecodingError)
        /// Not JSON, or an error that says nothing about where it failed.
        case unreadable
    }

    private static func attempt<T: Decodable>(_ type: T.Type, _ json: Any, _ decoder: JSONDecoder) -> Attempt<T> {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return .unreadable }
        do {
            return .decoded(try decoder.decode(type, from: data))
        } catch let error as DecodingError {
            return .failed(error)
        } catch {
            return .unreadable
        }
    }

    /// The "@type" of a message content at `path`, if that's what is there.
    private static func messageType(at path: [Step], in json: Any) -> String? {
        guard let type = (value(in: json, at: path) as? [String: Any])?["@type"] as? String, type.hasPrefix("message") else { return nil }
        return type
    }

    /// Where in the JSON the decoder gave up: for a missing key, the key itself.
    private static func location(of error: DecodingError, in json: Any) -> [Step]? {
        var codingPath: [any CodingKey]
        switch error {
        case .keyNotFound(let key, let context): codingPath = context.codingPath + [key]
        case .valueNotFound(_, let context), .typeMismatch(_, let context), .dataCorrupted(let context): codingPath = context.codingPath
        @unknown default: return nil
        }
        var node: Any? = json
        var steps: [Step] = []
        for key in codingPath {
            if let index = key.intValue, let array = node as? [Any] {
                steps.append(.index(index))
                node = array.indices.contains(index) ? array[index] : nil
            } else if let object = node as? [String: Any] {
                // The decoder converts TDLib's snake_case keys; find the key as TDLib wrote it.
                let name = object.keys.first { comparable($0) == comparable(key.stringValue) } ?? snakeCase(key.stringValue)
                steps.append(.key(name))
                node = object[name]
            } else {
                return nil
            }
        }
        return steps.isEmpty ? nil : steps
    }

    private static func comparable(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: "").lowercased()
    }

    private static func snakeCase(_ key: String) -> String {
        key.reduce(into: "") { result, character in
            if character.isUppercase { result += "_" + character.lowercased() } else { result.append(character) }
        }
    }

    /// The value at `path`; nil when it's absent or null.
    private static func value(in json: Any, at path: [Step]) -> Any? {
        var node: Any? = json
        for step in path {
            switch step {
            case .key(let key): node = (node as? [String: Any])?[key]
            case .index(let index): node = (node as? [Any]).flatMap { $0.indices.contains(index) ? $0[index] : nil }
            }
        }
        return node is NSNull ? nil : node
    }

    /// The JSON with the value at `path` replaced; nil removes the key or the list item.
    private static func setting(_ json: Any, at path: [Step], to newValue: Any?) -> Any {
        guard let step = path.first else { return newValue ?? NSNull() }
        let rest = Array(path.dropFirst())
        switch step {
        case .key(let key):
            guard var object = json as? [String: Any] else { return json }
            if rest.isEmpty {
                object[key] = newValue
            } else if let child = object[key] {
                object[key] = setting(child, at: rest, to: newValue)
            }
            return object
        case .index(let index):
            guard var array = json as? [Any], array.indices.contains(index) else { return json }
            if rest.isEmpty {
                if let newValue { array[index] = newValue } else { array.remove(at: index) }
            } else {
                array[index] = setting(array[index], at: rest, to: newValue)
            }
            return array
        }
    }

    /// A path for the log, like `messages[42].interaction_info`. Names only, never values.
    private static func describe(_ path: [Step]) -> String {
        path.reduce(into: "") { result, step in
            switch step {
            case .key(let key): result += result.isEmpty ? key : "." + key
            case .index(let index): result += "[\(index)]"
            }
        }
    }
}

extension TDLibClient {
    /// `getChatHistory`, tolerant of messages TDLibKit can't decode.
    func resilientChatHistory(chatId: Int64, fromMessageId: Int64, limit: Int, offset: Int = 0) async throws -> Messages {
        let query = GetChatHistory(chatId: chatId, fromMessageId: fromMessageId, limit: limit, offset: offset, onlyLocal: false)
        return try await resilientRun(query) { try ResilientDecoding.decode(Messages.self, from: $0, decoder: $1) }
    }

    /// `getMessage`, tolerant of messages TDLibKit can't decode.
    func resilientMessage(chatId: Int64, messageId: Int64) async throws -> Message {
        try await resilientRun(GetMessage(chatId: chatId, messageId: messageId)) {
            try ResilientDecoding.decode(Message.self, from: $0, decoder: $1)
        }
    }

    /// `getRepliedMessage`, tolerant of messages TDLibKit can't decode.
    func resilientRepliedMessage(chatId: Int64, messageId: Int64) async throws -> Message {
        try await resilientRun(GetRepliedMessage(chatId: chatId, messageId: messageId)) {
            try ResilientDecoding.decode(Message.self, from: $0, decoder: $1)
        }
    }

    /// Runs a TDLib query like TDLibKit's generated methods do, but reads the reply with the
    /// given (resilient) decoding.
    func resilientRun<Query: Codable, Response>(
        _ query: Query,
        decode: @escaping @Sendable (Data, JSONDecoder) throws -> Response
    ) async throws -> Response {
        let decoder = decoder
        return try await withCheckedThrowingContinuation { continuation in
            do {
                // @Sendable: TDLibKit calls this on its own queue.
                try send(query: DTO(query, encoder: encoder), completion: { @Sendable data in
                    if (try? JSONDecoder().decode(TypeTag.self, from: data))?.type == "error",
                       let error = try? decoder.decode(TDLibKit.Error.self, from: data) {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(with: Result { try decode(data, decoder) })
                    }
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Just the "@type" of a TDLib object.
private struct TypeTag: Decodable {
    let type: String

    enum CodingKeys: String, CodingKey {
        case type = "@type"
    }
}
