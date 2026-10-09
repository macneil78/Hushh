@preconcurrency import TDLibKit
import Foundation

/// TDLibKit's generated models sometimes require a field TDLib leaves out (a gift's
/// `background`, for one), and then a whole update or reply fails to decode: a chat whose last
/// message is a gift never reaches the list, and its history won't load. When that happens,
/// replace each message content TDLibKit can't read with one it can, and try again, so one odd
/// message never hides a chat.
enum ResilientDecoding {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            guard let json = try? JSONSerialization.jsonObject(with: data) else { throw error }
            var replacements = 0
            let patched = sanitize(json, decoder: decoder, replacements: &replacements)
            guard replacements > 0, let patchedData = try? JSONSerialization.data(withJSONObject: patched) else { throw error }
            Log.session.notice("Replaced \(replacements) message content(s) TDLibKit can't decode")
            return try decoder.decode(type, from: patchedData)
        }
    }

    /// Walks the JSON, testing every message content on its own.
    private static func sanitize(_ value: Any, decoder: JSONDecoder, replacements: inout Int) -> Any {
        if var object = value as? [String: Any] {
            for (key, child) in object {
                if key == "content", let content = child as? [String: Any],
                   let type = content["@type"] as? String, type.hasPrefix("message"),
                   !decodes(content, decoder: decoder) {
                    object[key] = standIn(for: type)
                    replacements += 1
                } else {
                    object[key] = sanitize(child, decoder: decoder, replacements: &replacements)
                }
            }
            return object
        }
        if let array = value as? [Any] {
            return array.map { sanitize($0, decoder: decoder, replacements: &replacements) }
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
}

extension TDLibClient {
    /// `getChatHistory`, tolerant of messages TDLibKit can't decode.
    func resilientChatHistory(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> Messages {
        let query = GetChatHistory(chatId: chatId, fromMessageId: fromMessageId, limit: limit, offset: 0, onlyLocal: false)
        return try await resilientRun(query) { try ResilientDecoding.decode(Messages.self, from: $0, decoder: $1) }
    }

    /// `getChat`, tolerant of a last message TDLibKit can't decode.
    func resilientChat(id: Int64) async throws -> Chat {
        try await resilientRun(GetChat(chatId: id)) { try ResilientDecoding.decode(Chat.self, from: $0, decoder: $1) }
    }

    /// `getRepliedMessage`, tolerant of messages TDLibKit can't decode.
    func resilientRepliedMessage(chatId: Int64, messageId: Int64) async throws -> Message {
        try await resilientRun(GetRepliedMessage(chatId: chatId, messageId: messageId)) {
            try ResilientDecoding.decode(Message.self, from: $0, decoder: $1)
        }
    }

    /// Runs a TDLib query like TDLibKit's generated methods do, but reads the reply with the
    /// given (resilient) decoding.
    private func resilientRun<Query: Codable, Response>(
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
