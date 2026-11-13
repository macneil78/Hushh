import AppKit
import HushAI
import SwiftUI

/// Windows for view tests that nobody sees: borderless, far off screen, transparent, never key
/// and never in front. The test process never becomes a regular app.
@MainActor
enum TestWindow {
    private static let prepared: Void = {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }()

    /// Keeps the test process from becoming a regular app. Making a window does this too.
    static func prepare() {
        _ = prepared
    }

    /// An empty window, not yet on the window list. Close it with `close(_:)` in a defer.
    static func make(width: CGFloat, height: CGFloat) -> NSWindow {
        prepare()
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.hasShadow = false
        return window
    }

    /// `view` in a window behind every other one. Let it settle before reading it, and close it
    /// with `close(_:)` in a defer. Like the app, it provides the Codex helper to the views.
    static func host(_ view: some View, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = make(width: width, height: height)
        window.contentView = NSHostingView(rootView: view.environment(Codex()))
        window.setContentSize(NSSize(width: width, height: height))
        window.orderBack(nil)
        return window
    }

    static func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    // MARK: Run loop

    /// Runs the main run loop, which AppKit and SwiftUI need to draw and commit updates.
    static func run(for seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: min(end, Date(timeIntervalSinceNow: 0.02)))
        }
        layOut()
    }

    /// Lets main-actor tasks and the run loop take turns, then lays out every window.
    static func settle(_ seconds: TimeInterval = 0.3) async {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(15))
            pump()
        }
        layOut()
    }

    private static func pump() {
        CFRunLoopRunInMode(.defaultMode, 0.005, false)
    }

    private static func layOut() {
        for window in NSApplication.shared.windows { window.contentView?.layoutSubtreeIfNeeded() }
    }

    // MARK: Input

    /// A key press and release sent to the window, which hands them to its first responder.
    static func press(_ characters: String, keyCode: Int = 0, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
            ) else { continue }
            window.sendEvent(event)
        }
    }

    /// Every view of a type in `view`'s tree, `view` included, parents before children.
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        [view as? T].compactMap { $0 } + view.subviews.flatMap { views(type, in: $0) }
    }

    // MARK: Accessibility

    struct Element {
        /// The role without its "AX" prefix: "Button", "StaticText".
        let role: String
        /// The label, title and value that are there, in that order.
        let texts: [String]
        let isSelected: Bool
        /// Where it is, in the window's coordinates (origin at the bottom left).
        let frame: CGRect

        /// "Role "label" "value"", as VoiceOver names it, and "selected" when it is.
        var line: String {
            ([role] + texts.map { "\"\($0)\"" } + (isSelected ? ["selected"] : [])).joined(separator: " ")
        }
    }

    /// The elements under `view` that VoiceOver can land on (those with text, and buttons), in
    /// the order it moves through them.
    static func accessibilityElements(in view: NSView) -> [Element] {
        let origin = view.window?.frame.origin ?? .zero
        var elements: [Element] = []
        // SwiftUI's elements answer the accessibility messages without declaring the protocol.
        func get(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func walk(_ object: Any, depth: Int) {
            guard depth < 40, let element = object as? NSObject else { return }
            let role = ((get(element, "accessibilityRole") as? String) ?? "?").replacingOccurrences(of: "AX", with: "")
            let texts = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { name -> String? in
                switch get(element, name) {
                case let text as String: text
                case let text as NSAttributedString: text.string
                default: nil
                }
            }.filter { !$0.isEmpty }
            if !texts.isEmpty || role == "Button" {
                let selected = element.responds(to: NSSelectorFromString("isAccessibilitySelected"))
                    && (element.value(forKey: "accessibilitySelected") as? Bool) == true
                let screen = (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                elements.append(Element(role: role, texts: texts, isSelected: selected, frame: screen.offsetBy(dx: -origin.x, dy: -origin.y)))
            }
            if let table = object as? NSTableView {
                // A List makes its rows only when asked for them.
                for row in 0..<table.numberOfRows {
                    if let rowView = table.rowView(atRow: row, makeIfNecessary: true) { walk(rowView, depth: depth + 1) }
                }
                return
            }
            let children = get(element, "accessibilityChildrenInNavigationOrder") as? [Any]
                ?? get(element, "accessibilityChildren") as? [Any] ?? []
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return elements
    }

    /// `accessibilityElements(in:)` as lines.
    static func accessibilityTree(of view: NSView) -> String {
        accessibilityElements(in: view).map(\.line).joined(separator: "\n")
    }

    private static let accessibility: Void = {
        if let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) {
            for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled", "_AXSSetApplicationAccessibilityEnabled"] {
                guard let symbol = dlsym(library, name) else { continue }
                typealias SetEnabled = @convention(c) (Bool) -> Void
                unsafeBitCast(symbol, to: SetEnabled.self)(true)
            }
        }
        UserDefaults.standard.register(defaults: ["NSAccessibilityEnabled": true])
        // AXEnhancedUserInterface, as an assistive app sets it; only the old setter can say it.
        _ = NSApplication.shared.perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"),
            with: true as NSNumber, with: "AXEnhancedUserInterface" as NSString
        )
    }()

    /// Makes AppKit build SwiftUI's accessibility tree, which it does only for an assistive app
    /// such as VoiceOver. Call it before hosting a view whose tree a test reads; it stays on for
    /// the rest of the process.
    static func enableAccessibility() {
        _ = accessibility
    }
}
