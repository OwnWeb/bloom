import AppKit
import BloomCore
import SwiftTerm

extension SwiftTerm.TerminalView {
    /// The sixteen ANSI slots, the foreground, the background, the cursor and the selection, from
    /// the scheme this reader chose with their Ghostty configuration over it where they follow one.
    ///
    /// Read through `effectiveAppearance` rather than the app's, because a `theme = light:…,dark:…`
    /// has to follow the window the terminal is actually in.
    func applyBloomColours() {
        let theme = TerminalGhostty.colours(for: effectiveAppearance)
        installColors(theme.ansiColors().map(SwiftTerm.Color.init))
        nativeForegroundColor = theme.foreground.map(NSColor.init) ?? .labelColor
        nativeBackgroundColor = theme.background.map(NSColor.init) ?? .textBackgroundColor
        // **The view's own layer carries the ground as well, because SwiftTerm does not paint all
        // of its bounds.** Rows are drawn to the width left over after the scroller's lane, and
        // only the part-row gap at the bottom is filled across the full width, so the strip the
        // scroller sits in is never painted and shows whatever is behind the view. In a pane with
        // no inset that is the window: a cream terminal with a white channel down its right hand
        // side. One line here rather than a colour on each host, so the two terminals cannot end
        // up with two answers to it.
        wantsLayer = true
        layer?.backgroundColor = nativeBackgroundColor.cgColor
        let background = nativeBackgroundColor.usingColorSpace(.deviceRGB)
        for scroller in subviews.compactMap({ $0 as? NSScroller }) {
            scroller.knobStyle = (background?.brightnessComponent ?? 1) < 0.5 ? .light : .dark
        }
        // Ghostty falls back to the foreground for the cursor, and to the system for a selection it
        // was never told about.
        caretColor = theme.cursorColor.map(NSColor.init) ?? nativeForegroundColor
        caretTextColor = theme.cursorTextColor.map(NSColor.init)
        selectedTextBackgroundColor = theme.selectionBackground.map(NSColor.init) ?? .selectedTextBackgroundColor
        selectedTextForegroundColor = theme.selectionForeground.map(NSColor.init) ?? nativeForegroundColor
        needsDisplay = true
    }

    /// The font and the line spacing, which is Ghostty's `font-family` where there is one and it is
    /// installed, and the monospaced system font otherwise.
    func applyBloomFont(family: String?, size: CGFloat, lineHeight: Double?) {
        let desired = TerminalGhostty.font(family: family, size: size)
        if font != desired { font = desired }
        let spacing = CGFloat(lineHeight ?? 1)
        if lineSpacing != spacing { lineSpacing = spacing }
    }
}

/// The three preferences a terminal's look is made of, read once so a view can compare them and do
/// nothing when nothing has moved.
@MainActor
struct TerminalLook: Equatable {
    var scheme: TerminalScheme
    var typography: ThemeTypography
    var followsGhostty: Bool

    static var current: TerminalLook {
        let preference = ColourThemePreference.shared
        return TerminalLook(
            scheme: preference.terminalScheme,
            typography: preference.terminalTypography,
            followsGhostty: preference.followsGhostty
        )
    }

    /// The size a terminal draws at: the typography's, then Ghostty's for this appearance, then
    /// the size the rest of the app reads at.
    func fontSize(for appearance: NSAppearance) -> CGFloat {
        if let size = typography.fontSize { return CGFloat(size) }
        if followsGhostty, let ghostty = TerminalGhostty.theme(for: appearance)?.fontSize {
            return CGFloat(ghostty)
        }
        return CGFloat(TerminalTextSize.systemDefault)
    }

    /// The family, on the same precedence.
    func fontFamily(for appearance: NSAppearance) -> String? {
        if let family = typography.fontFamily { return family }
        return followsGhostty ? TerminalGhostty.theme(for: appearance)?.fontFamily : nil
    }
}
