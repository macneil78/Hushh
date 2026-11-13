import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Whether to keep things still: no looping GIFs or video circles, no stickers that play on
    /// their own, no pulsing typing dots, no sliding panels. Follows System Settings →
    /// Accessibility → Display → Reduce Motion, kept up to date at the root of each window
    /// (`followsReduceMotion()`). Views read this one, not SwiftUI's own, so that a preview, the
    /// demo or a test can turn it on.
    @Entry var reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

extension View {
    /// Sets `reducesMotion` for everything inside from the system setting, and keeps it current
    /// when the setting changes. Put it at the root of each window.
    func followsReduceMotion() -> some View {
        modifier(FollowsReduceMotion())
    }
}

private struct FollowsReduceMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.environment(\.reducesMotion, reduceMotion)
    }
}
