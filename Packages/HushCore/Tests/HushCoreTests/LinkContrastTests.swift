import AppKit
import SwiftUI
import Testing
@testable import HushCore
@testable import HushUI

/// Links and mentions on the grey bubble need 4.5:1 contrast (WCAG AA for body text) in light and
/// dark mode; the system accent blue gives about 3:1.
@MainActor
struct LinkContrastTests {
    private func resolved(_ color: Color, dark: Bool) -> NSColor {
        var result = NSColor.clear
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)!
        }
        return result
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            func channel(_ c: CGFloat) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    @Test(arguments: [false, true])
    func linksAndMentionsOnTheGreyBubbleAreReadable(dark: Bool) throws {
        let text = HushCore.RichText(text: "see example.com @anna", spans: [
            .init(range: 4..<15, style: .link(URL(string: "https://example.com")!)),
            .init(range: 16..<21, style: .mention),
        ])
        let attributed = AttributedString(text, onAccent: false, revealsSpoilers: true)
        let bubble = resolved(MessagesStyle.incoming, dark: dark)
        for run in attributed.runs where run.link != nil || String(attributed[run.range].characters) == "@anna" {
            let color = try #require(run.foregroundColor, "\(String(attributed[run.range].characters)) has the default color")
            let ratio = contrast(resolved(color, dark: dark), bubble)
            #expect(ratio >= 4.5, "\(String(attributed[run.range].characters)): \(ratio):1")
            if run.link != nil { #expect(run.underlineStyle == .single) }
        }
    }
}
