import AppKit

extension Brand {
    /// Bloom's canonical blue mark, `Resources/BloomMark.svg`, which `Tools/build.sh` copies into
    /// the bundle.
    ///
    /// **Not `NSApp.applicationIconImage`**, which is what the Bloom Cloud hero and the sidebar
    /// card drew first. A dev build and a Bloom Cloud build tint their icons so the copies can be
    /// told apart in the Dock, so the hero came out green in the build the owner looked at. The
    /// brand is blue wherever it is the brand rather than the running copy's name tag. Falls back
    /// to the icon only in a bundle without the file, such as `swift run`.
    @MainActor static let mark: NSImage = Bundle.main.url(forResource: "BloomMark", withExtension: "svg")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage
}
