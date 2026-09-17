import Foundation

/// The colour of an agent waiting on an answer, beside `PaletteInk` rather than inside it.
///
/// A file of its own for the reason `PaletteInk+WorkspaceMessages.swift` gives: `PaletteInk.swift`
/// is being moved into a package on the server runtime branch. See `Palette.waiting` for why the
/// hue is magenta, and `PaletteContrastTests` for what holds it.
extension PaletteInk {
    public static let waiting = Pair(light: 0xB8337E, dark: 0xF27CC0)
}
