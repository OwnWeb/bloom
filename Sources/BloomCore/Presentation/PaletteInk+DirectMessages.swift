import Foundation

/// The fill of a message you addressed to a person rather than to Bloom.
///
/// An extension in a file of its own for `PaletteInk+WorkspaceMessages`' reason: `PaletteInk.swift`
/// is being moved into a package on the server runtime branch, and every line added to it here is
/// a conflict there resolved by hand.
///
/// **The hue means "a person", not "which person".** A fourth teammate needs no fourth colour;
/// which person it went to is in the caption. That is the decision that keeps this to one value:
/// colouring by addressee would need a fill per audience, all mutually distinguishable and all
/// carrying white text, and a search of sRGB seeded with the two fills already in use found five
/// survivors at deltaE 30, one of them the red this app uses for an error. A fourth teammate would
/// have been assigned the colour of a failure.
///
/// **Chosen from twelve candidates shown as runs beside the teal, and then measured.** White on it
/// is 5.24 to 1, clear of the text floor at thirteen points, and it is 77 CIE76 from `accentFill`,
/// which is the furthest apart of anything that also carries white text. `PaletteContrastTests`
/// holds both.
///
/// One value in both appearances, for `accentFill` and `teammateFill`'s reason: a fill exists to
/// carry light text, which is a different question from whether the hue works as ink on a page.
extension PaletteInk {
    public static let directFill = Pair(light: 0xA8543F, dark: 0xA8543F)
}
