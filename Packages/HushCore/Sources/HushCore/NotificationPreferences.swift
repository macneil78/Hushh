import Foundation
import Observation

/// How notifications behave on this Mac. Telegram's own mute settings still apply on top.
@MainActor @Observable
public final class NotificationPreferences {
    public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    public var playsSound: Bool {
        didSet { defaults.set(playsSound, forKey: Keys.playsSound) }
    }

    /// Off: banners say "New message" without the text, for when others can see your screen.
    public var showsPreview: Bool {
        didSet { defaults.set(showsPreview, forKey: Keys.showsPreview) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let isEnabled = "notifications.enabled"
        static let playsSound = "notifications.sound"
        static let showsPreview = "notifications.preview"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.isEnabled: true, Keys.playsSound: true, Keys.showsPreview: true])
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        playsSound = defaults.bool(forKey: Keys.playsSound)
        showsPreview = defaults.bool(forKey: Keys.showsPreview)
    }
}
