import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Exercises the production glass container, text editor, drop handlers, and attachment
/// insertion in an unshown window. No mouse events, user pasteboard, or app database are used.
@MainActor
enum ComposerInputProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--composer-input-probe") }

    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { await run() }
        RunLoop.main.run()
        exit(1)
    }

    @MainActor
    @Observable
    final class Draft {
        var text = ""
        var caret = 0
        var height = ComposerTextEditor.lineHeight
        var heightLimit = CGFloat.greatestFiniteMagnitude
        var targeted = false
        var failures: [String] = []
        var attached: [String] = []
        let handle = ComposerEditorHandle()
        let root: String

        init(root: String) { self.root = root }

        func receive(_ sources: [AttachmentSource], at range: NSRange) -> Bool {
            do {
                let paths = try sources.map { try AttachmentFiles.attach($0, workspace: root).path }
                attached += paths
                return handle.insert(paths, replacing: range, into: text)
            } catch {
                failures.append(error.localizedDescription)
                return false
            }
        }
    }

    private struct Fixture: View {
        @Bindable var draft: Draft

        var body: some View {
            VStack(spacing: 8) {
                ComposerEditor(
                    text: $draft.text, caret: $draft.caret, isFocused: .constant(false),
                    height: min(draft.height, draft.heightLimit), onContentHeightChange: { draft.height = $0 },
                    onKey: { _ in false }, onAttach: { draft.receive($0, at: $1) },
                    onAttachmentFailure: { draft.failures.append($0) },
                    attachmentRoot: draft.root, handle: draft.handle
                )
                HStack {
                    Button("Model") {}
                    Spacer()
                    Button("Send") {}
                }
            }
            .composerBox(isFocused: .constant(false), isFloating: true)
            .composerDropDestination(
                isTargeted: $draft.targeted,
                onReceive: { draft.receive($0, at: NSRange(location: draft.text.utf16.count, length: 0)) },
                onFailure: { draft.failures.append($0) }
            )
            .padding(16)
            .environment(\.fontScale, ChatTextSize.defaultChoice.scale)
        }
    }

    private static func run() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bloom-input-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures: [String] = []
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let draft = Draft(root: directory.appending(path: "workspace").path)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            let host = NSHostingView(rootView: Fixture(draft: draft))
            window.contentView = host
            await settle(window)
            guard let text: ComposerTextView = find(in: host),
                  let surface: ComposerDropSurface = find(in: host),
                  let scroll = text.enclosingScrollView else {
                throw CocoaError(.coderValueNotFound)
            }
            var ancestor: NSView? = text
            while ancestor != nil, ancestor !== surface { ancestor = ancestor?.superview }
            check(ancestor === surface, "drop surface is not an ancestor of the native editor")

            let line = NSLayoutManager().defaultLineHeight(for: text.font!)
            check(text.frame.height <= scroll.contentSize.height,
                  "initial empty draft overflows: document \(text.frame.height), viewport \(scroll.contentSize.height)")
            draft.heightLimit = ComposerTextEditor.lineHeight
            await settle(window)
            check(text.frame.height <= scroll.contentSize.height,
                  "empty draft overflows a minimum-height composer: "
                  + "document \(text.frame.height), viewport \(scroll.contentSize.height)")
            draft.heightLimit = .greatestFiniteMagnitude
            await settle(window)
            for style: NSScroller.Style in [.legacy, .overlay] {
                scroll.scrollerStyle = style
                for value in ["", "Short draft", String(repeating: "Line\n", count: 25), ""] {
                    draft.text = value
                    await settle(window)
                    if value.isEmpty || value == "Short draft" {
                        check(text.frame.height <= scroll.contentSize.height,
                              "short draft overflows the editor with scroller style \(style.rawValue): "
                              + "document \(text.frame.height), viewport \(scroll.contentSize.height)")
                        if style == .legacy {
                            check(scroll.verticalScroller?.isHidden != false,
                                  "short draft shows an unnecessary scrollbar")
                        }
                    } else {
                        check(text.frame.height > scroll.contentSize.height, "long draft cannot scroll")
                    }
                }
            }
            // A draft whose last line fits beside no scroller and wraps beside a legacy one. The
            // editor flipped between the two heights for as long as it was left there.
            do {
                scroll.scrollerStyle = .legacy
                draft.text = ""
                await settle(window)
                let font = text.font!
                let full = scroll.frame.width - 2 * ComposerTextEditor.textInset
                let narrow = full - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                func lines(_ string: String, _ width: CGFloat) -> Int {
                    let storage = NSTextStorage(string: string, attributes: [.font: font])
                    let manager = NSLayoutManager()
                    let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
                    container.lineFragmentPadding = 0
                    manager.addTextContainer(container)
                    storage.addLayoutManager(manager)
                    manager.ensureLayout(for: container)
                    return Int((manager.usedRect(for: container).height / line).rounded())
                }
                var last = "Lorem"
                while lines(last, full) == lines(last, narrow) { last += " ipsum" }
                draft.text = "Title\n\nOne\n\nTwo\n\n" + last
                var heights: [CGFloat] = []
                for _ in 0..<40 {
                    window.layoutIfNeeded()
                    heights.append(scroll.contentSize.height)
                    try? await Task.sleep(for: .milliseconds(25))
                }
                let flips = zip(heights, heights.dropFirst()).filter { $0 != $1 }.count
                check(flips <= 2, "editor oscillates at a legacy scroller's wrap boundary: \(flips) flips")
                check(text.frame.height <= scroll.contentSize.height,
                      "draft at a legacy scroller's wrap boundary is left scrolled: "
                      + "document \(text.frame.height), viewport \(scroll.contentSize.height)")
                scroll.scrollerStyle = .overlay
            }
            for count in [1, 2, 10, 25, 1] {
                draft.text = Array(repeating: "Line", count: count).joined(separator: "\n")
                await settle(window)
                check(abs(scroll.contentSize.height - ceil(line * CGFloat(min(count, 10)))) <= 1,
                      "editor did not size to \(min(count, 10)) lines for a \(count)-line draft")
                if count > 10 {
                    check(text.frame.height > scroll.contentSize.height, "long draft cannot scroll internally")
                }
            }
            draft.text = "Line\n"
            await settle(window)
            check(abs(scroll.contentSize.height - ceil(line * 2)) <= 1, "trailing newline did not grow the editor")

            // Dictation tools may insert a long utterance as many small edits. Keep the native
            // editor and its binding in step throughout, including after SwiftUI updates it.
            draft.text = ""
            await settle(window)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            let spoken = Array(repeating: "A short dictated sentence. ", count: 80)
            for (index, phrase) in spoken.enumerated() {
                text.insertText(phrase, replacementRange: NSRange(location: NSNotFound, length: 0))
                if index.isMultiple(of: 8) {
                    await Task.yield()
                    window.layoutIfNeeded()
                }
            }
            await settle(window)
            let dictated = spoken.joined()
            check(draft.text == dictated, "dictated text did not reach the draft")
            check(text.string == dictated, "dictated text was replaced during a SwiftUI update")
            check(text.selectedRange().location == (dictated as NSString).length,
                  "dictation left the caret before the end of the draft")

            let file = directory.appending(path: "Finder file.txt")
            try Data("finder attachment".utf8).write(to: file)
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let drag = InputDrag(board: board, window: window)
            board.writeObjects([file as NSURL])
            check(!ComposerTextView.hasOnlyText(on: board), "file clipboard was mistaken for plain text")
            check(surface.draggingEntered(drag) == .copy, "outer surface rejected Finder file")
            check(surface.prepareForDragOperation(drag), "outer surface refused Finder drop at release")
            check(surface.performDragOperation(drag), "outer surface failed to insert Finder file")
            await settle(window)
            check(draft.text.contains("Finder file.txt"), "Finder drop was not written into the draft")

            draft.text = "Drop here"
            await settle(window)
            drag.draggingLocation = text.convert(NSPoint(x: 8, y: 8), to: nil)
            check(text.draggingEntered(drag) == .copy, "text editor rejected Finder file")
            check(text.prepareForDragOperation(drag), "text editor refused Finder drop at release")
            check(text.performDragOperation(drag), "text editor failed to attach Finder file")

            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            let png = image.representation(using: .png, properties: [:])!
            board.clearContents()
            board.setData(png, forType: .png)
            check(!ComposerTextView.hasOnlyText(on: board), "image clipboard was mistaken for plain text")
            check(surface.draggingEntered(drag) == .copy, "outer surface rejected screenshot bytes")
            check(surface.performDragOperation(drag), "outer surface failed to attach screenshot bytes")
            await settle(window)
            check(text.draggingEntered(drag) == .copy, "text editor rejected screenshot bytes")
            check(text.performDragOperation(drag), "text editor failed to attach screenshot bytes")
            await settle(window)
            check(draft.attached.count == 4, "drops were lost or delivered twice")
            check(draft.attached.allSatisfy {
                FileManager.default.fileExists(atPath: (draft.root as NSString).appendingPathComponent($0))
            }, "an inserted attachment has no file in the workspace")

            let writer = InputPromiseWriter(data: png)
            let promise = NSFilePromiseProvider(fileType: "public.png", delegate: writer)
            board.clearContents()
            board.writeObjects([promise])
            check(AttachmentDrop.canRead(board), "CleanShot-style file promise was not recognised")
            // AppKit requires a live window-server drag to request the promised bytes. Check
            // its advertised types above, then the delivered file's copy and lifetime here.
            let promisedDirectory: URL
            do {
                let storage = try PromisedAttachmentStorage()
                promisedDirectory = storage.directory
                let promised = storage.directory.appending(path: "Promised screenshot.png")
                try png.write(to: promised)
                check(draft.receive(
                    [.promisedFile(promised, storage)], at: NSRange(location: draft.text.utf16.count, length: 0)
                ), "delivered file promise could not be inserted")
            }
            check(draft.attached.count == 5, "delivered screenshot did not reach the draft")
            check(!FileManager.default.fileExists(atPath: promisedDirectory.path), "temporary promise files leaked")
            withExtendedLifetime((promise, writer)) {}

            // A French keyboard types a backtick as a dead key: the first press is marked text,
            // and Space commits it.
            draft.text = "Code "
            await settle(window)
            let notFound = NSRange(location: NSNotFound, length: 0)
            text.setSelectedRange(NSRange(location: 5, length: 0))
            text.setMarkedText("`", selectedRange: NSRange(location: 1, length: 0), replacementRange: notFound)
            await settle(window)
            check(text.hasMarkedText(), "dead key composition was cancelled before it was committed")
            check(text.string == "Code `", "dead key marked text was lost: \(text.string.debugDescription)")
            text.insertText("`", replacementRange: notFound)
            await settle(window)
            check(draft.text == "Code `", "dead key backtick did not reach the draft: \(draft.text.debugDescription)")
            check(text.string == "Code `", "dead key backtick did not stay in the editor: \(text.string.debugDescription)")

            board.clearContents()
            board.setString("ordinary text", forType: .string)
            check(ComposerTextView.hasOnlyText(on: board), "plain text paste took the attachment path")
            check(surface.draggingEntered(drag).isEmpty, "outer surface intercepted a plain text drag")
            check(!window.isVisible && !window.isKeyWindow, "probe displayed its window")
            failures += draft.failures
        } catch {
            failures.append(error.localizedDescription)
        }
        let result: JSONValue = .object([
            "checks": .integer(checks), "passed": .bool(failures.isEmpty), "failures": .strings(failures),
            "filePromiseTransfer": .string("Requires a live drag; advertisement, receipt and cleanup checked separately"),
        ])
        ProbeHarness(subject: "composer-input").write(result)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func settle(_ window: NSWindow) async {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func find<T: NSView>(in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(in: $0) as T? }.first
    }
}

@MainActor
private final class InputDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(board: NSPasteboard, window: NSWindow) {
        draggingPasteboard = board
        draggingDestinationWindow = window
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

@MainActor
private final class InputPromiseWriter: NSObject, @MainActor NSFilePromiseProviderDelegate {
    let data: Data
    init(data: Data) { self.data = data }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "Promised screenshot.png"
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }
}
#endif
