import os

/// Log channels, visible in Console.app under the "Hush" subsystem. Never log message contents.
enum Log {
    static let session = Logger(subsystem: "Hush", category: "session")
    static let auth = Logger(subsystem: "Hush", category: "auth")
    static let chats = Logger(subsystem: "Hush", category: "chats")
    static let notifications = Logger(subsystem: "Hush", category: "notifications")
}
