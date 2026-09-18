import AppKit
import BloomCore
import SwiftTerm

/// What a terminal in Bloom looks like, for every terminal in Bloom.
///
/// **One source of settings, both panes, at the owner's asking.** A Cloud workspace's terminal came
/// up black with SwiftTerm's own palette and a twelve point default while the local one beside it
/// was drawing his scheme, his font and his Ghostty configuration. His question was whether the
/// Cloud one could simply use those settings, and the answer turned out to be yes for nothing: none
/// of this describes a worktree or a process on this Mac. `ColourThemePreference` is a shared
/// singleton and `TerminalGhostty` reads the appearance it is handed, so the whole of a terminal's
/// look is already a value both views can ask for.
///
/// It is an extension on SwiftTerm's own view rather than a shared superclass because the two
/// terminals differ in what feeds them, a local process against a socket, and not at all in what
/// they look like. A subclass would have made them share the half that genuinely differs.
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
