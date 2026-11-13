import AppKit
import SwiftUI

/// Tells whether the window around it is on screen, that is open and not minimized, and when it
/// closes. SwiftUI keeps a closed window's state, and a minimized window's views think they're
/// still showing, so the main window asks AppKit.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (_ isOnScreen: Bool) -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.onClose = onClose
    }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        var onClose: () -> Void = {}
        private var observers: [any NSObjectProtocol] = []
        private var isOnScreen: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                // Taken out of its window: gone from the screen as surely as a closed window.
                closed()
                return
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(false) }
                },
                center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(true) }
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closed() }
                },
            ]
            report(!window.isMiniaturized)
        }

        private func report(_ isOnScreen: Bool) {
            guard isOnScreen != self.isOnScreen else { return }
            self.isOnScreen = isOnScreen
            onChange(isOnScreen)
        }

        private func closed() {
            guard isOnScreen != nil else { return }
            report(false)
            isOnScreen = nil
            onClose()
        }
    }
}
