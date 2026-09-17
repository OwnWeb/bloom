import AppKit
import BloomCore

// Both halves of the pasteboard: `Clipboard` writes text to it, and the `NSPasteboard` extension
// below reads what is on it into the values `PastedAttachment` and `TerminalPaste` decide from.
// The reading used to be the composer's own, and moved here the day a terminal pane needed it.

/// Putting text on the pasteboard, in one place.
///
/// Two lines, written out nine times: a branch name, a file path in three different rows, a pull
/// request link, a code block, a raw event, a workspace name in a menu. Two lines are not much,
/// but `clearContents()` is easy to leave out and a pasteboard that was not cleared keeps whatever
/// richer flavour was on it before, so a paste can land as the thing copied three actions ago.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// How long a "Copied" label stays up.
    ///
    /// One number, because three buttons show that label and two of them used to hold it for 1.2
    /// seconds while the third held it for 1.5.
    static let flashDuration: Duration = .seconds(1.5)
}

extension NSPasteboard {
    /// What this board is offering, reduced to the facts `PastedAttachment.plan` decides from.
    ///
    /// Read here rather than in the composer because the terminal asks after the same board: a
    /// screenshot that the composer attaches is the one a terminal pane has to hand its CLI, and
    /// two readings of the board would be two answers to what a clipboard holds. Nothing here
    /// touches the bytes of a picture; the plan says which item to read and the caller pays for it.
    var attachmentPlan: PastedAttachment.Plan {
        attachmentPlan(for: pasteboardItems ?? [])
    }

    /// The plan for items already read off this board. A caller that goes on to read bytes out of
    /// `items` uses this form, so the indices in the plan are indices into that same array.
    func attachmentPlan(for items: [NSPasteboardItem]) -> PastedAttachment.Plan {
        PastedAttachment.plan(items: attachmentOffers(for: items), hasText: hasPlainText)
    }

    /// Every item on the board, reduced to the file it points at and the types it carries. Types
    /// only: no picture is read here, and the composer and a terminal pane both decide from this.
    var attachmentOffers: [PastedAttachment.Offer] {
        attachmentOffers(for: pasteboardItems ?? [])
    }

    func attachmentOffers(for items: [NSPasteboardItem]) -> [PastedAttachment.Offer] {
        items.map { item in
            PastedAttachment.Offer(filePath: item.fileURL()?.path, types: item.types.map(\.rawValue))
        }
    }

    /// Whether there is text, never the text itself. A clipboard is the user's own business and
    /// nothing here has any reason to read what is on it.
    var hasPlainText: Bool {
        string(forType: .string)?.isEmpty == false
    }
}

private extension NSPasteboardItem {
    /// The file this item points at, if it points at one.
    ///
    /// A file URL is read off the item rather than off the whole board, because a board is a list
    /// of items and reading it whole loses which picture belonged to which file. Anything that is
    /// not a file, an `https` link most of all, is not a file: pasting a URL types the URL, which
    /// is what it has always done.
    func fileURL() -> URL? {
        guard let string = string(forType: .fileURL),
              let url = URL(string: string), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }
}
