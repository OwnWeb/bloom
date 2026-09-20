import AppKit
import BloomClient
import SwiftUI

#if DEBUG
/// Exercises the destructive Cloud workspace confirmation in invisible windows.
///
/// This is layout and accessibility coverage rather than a second rendering implementation. It
/// hosts `CloudArchivePopoverBody` itself at the widths and accessibility settings that exposed
/// the fixed-height popover's clipping.
@MainActor
enum CloudArchiveProbe {
    private struct Variant {
        var name: String
        var workspace: String
        var confirmation: CloudArchiveConfirmation
        var status: CloudArchivePopoverBody.Status
        var width: CGFloat
        var appearance: NSAppearance.Name
        var contrast = ColorSchemeContrast.standard
        var reduceTransparency = false
    }

    static func run(directory: String, checksKeyboard: Bool, check: (Bool, String) -> Void) async {
        let summary = CloudArchiveConfirmation(summary: nil)
        var long = summary
        long.losses.append(
            "A deliberately long consequence sentence explains that an agent is still working and that its current edits, generated files and local commits have not reached GitHub."
        )
        long.losses.append("Seven commits and twenty-three generated files have not been pushed.")

        let variants = [
            Variant(
                name: "light", workspace: "Payments", confirmation: summary, status: .answered,
                width: 380, appearance: .aqua
            ),
            Variant(
                name: "dark", workspace: "Payments", confirmation: summary, status: .answered,
                width: 380, appearance: .darkAqua
            ),
            Variant(
                name: "increased-contrast", workspace: "Payments", confirmation: summary, status: .answered,
                width: 380, appearance: .accessibilityHighContrastAqua, contrast: .increased
            ),
            Variant(
                name: "reduce-transparency", workspace: "Payments", confirmation: summary, status: .answered,
                width: 380, appearance: .aqua, reduceTransparency: true
            ),
            Variant(
                name: "narrow-long",
                workspace: "A very long workspace name for the payments migration that must remain readable",
                confirmation: long,
                status: .unanswered,
                width: 300,
                appearance: .aqua
            ),
        ]

        var heights: [String: CGFloat] = [:]
        for variant in variants {
            let root = CloudArchivePopoverBody(
                name: variant.workspace,
                confirmation: variant.confirmation,
                status: variant.status,
                isArchiving: false,
                onConfirm: {},
                onCancel: {},
                width: variant.width
            )
            .background(Palette.surface)
            .environment(\.colorScheme, variant.appearance == NSAppearance.Name.darkAqua ? .dark : .light)
            .environment(\._colorSchemeContrast, variant.contrast)
            .environment(\._accessibilityReduceTransparency, variant.reduceTransparency)

            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: variant.appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            await settle(window)

            let size = host.fittingSize
            heights[variant.name] = size.height
            check(abs(size.width - variant.width) < 1, "\(variant.name) width was \(size.width), expected \(variant.width)")
            check(scrollViews(in: host).isEmpty, "\(variant.name) put the confirmation in a scroll view")
            save(host, in: directory, name: "cloud-delete-\(variant.name)")

            if variant.name == "narrow-long" {
                checkSemantics(of: variant, body: CloudArchivePopoverBody(
                    name: variant.workspace,
                    confirmation: variant.confirmation,
                    status: variant.status,
                    isArchiving: false,
                    onConfirm: {},
                    onCancel: {},
                    width: variant.width
                ), check: check)
            }
            check(!window.isVisible && !window.isKeyWindow, "\(variant.name) made its probe window visible")
        }

        if let regular = heights["light"], let constrained = heights["narrow-long"] {
            check(regular < 320, "the ordinary confirmation is not compact: \(regular) points high")
            check(constrained > regular + 100, "long wrapped content did not grow the confirmation: \(heights)")
        }
        if checksKeyboard { await checkKeyboard(check: check) }
    }

    private static func checkSemantics(
        of variant: Variant,
        body: CloudArchivePopoverBody,
        check: (Bool, String) -> Void
    ) {
        let order = body.semanticReadingOrder
        let expected = [CloudArchivePopoverBody.title, variant.workspace]
            + variant.confirmation.losses
            + [CloudArchiveConfirmation.unaskedSentence, CloudArchiveConfirmation.survivesSentence, "Cancel", "Delete"]
        check(order == expected, "VoiceOver reading order changed: \(order)")
        let spoken = order.joined(separator: " ")
        check(spoken.contains(variant.workspace), "the semantic order lost the complete workspace name")
        for consequence in variant.confirmation.losses {
            check(spoken.contains(consequence), "the semantic order lost consequence: \(consequence)")
        }
        check(spoken.contains(CloudArchiveConfirmation.unaskedSentence), "the semantic order lost freshness")
        check(spoken.contains(CloudArchiveConfirmation.survivesSentence), "the semantic order lost what survives")
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews(in:))
    }

    /// Key equivalents are driven only by the explicit probe flag. Local runs omit them because
    /// repository policy requires permission before sending synthetic input; CI passes the flag.
    private static func checkKeyboard(check: (Bool, String) -> Void) async {
        NSApp.activate()
        await mainQueueTurns(3)
        check(NSApp.isFullKeyboardAccessEnabled, "keyboard probe did not enable Full Keyboard Access")

        let returnAnswer = Answers()
        let returnWindow = keyboardWindow(answer: returnAnswer)
        await settle(returnWindow)
        guard let returnEvent = keyEvent(code: 36, characters: "\r", window: returnWindow) else {
            check(false, "keyboard events could not be made")
            return
        }
        let handledReturn = returnWindow.performKeyEquivalent(with: returnEvent)
        check(!handledReturn, "Return was accepted by the destructive confirmation")
        check(returnAnswer.cancelled == 0 && returnAnswer.confirmed == 0, "Return answered the confirmation")

        let escapeAnswer = Answers()
        let escapeWindow = keyboardWindow(answer: escapeAnswer)
        await settle(escapeWindow)
        guard let escapeEvent = keyEvent(code: 53, characters: "\u{1b}", window: escapeWindow) else {
            check(false, "Escape event could not be made")
            return
        }
        let handledEscape = escapeWindow.performKeyEquivalent(with: escapeEvent)
        check(handledEscape, "Escape was not accepted by the confirmation")
        check(escapeAnswer.cancelled == 1 && escapeAnswer.confirmed == 0, "Escape did not choose Cancel")

        let focusAnswer = Answers()
        let focusWindow = keyboardWindow(answer: focusAnswer, startsKey: true)
        await settle(focusWindow)
        check(focusWindow.isKeyWindow, "keyboard confirmation did not become key")
        check(focusAnswer.focus == "Cancel", "initial keyboard focus was not on Cancel")
        focusWindow.orderOut(nil)
    }

    private static func keyboardWindow(answer: Answers, startsKey: Bool = false) -> NSWindow {
        let body = CloudArchivePopoverBody(
            name: "Keyboard fixture",
            confirmation: CloudArchiveConfirmation(summary: nil),
            status: .answered,
            isArchiving: false,
            onConfirm: { answer.confirmed += 1 },
            onCancel: { answer.cancelled += 1 },
            onFocusChange: { answer.focus = $0 }
        )
        let host = NSHostingView(rootView: body)
        if startsKey {
            // `defaultFocus` is evaluated when the hierarchy first appears. Production attaches
            // the popover to an already-key window, so do the same instead of rendering a
            // detached host first and asking SwiftUI to retroactively choose an initial focus.
            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            window.contentView = host
            window.setContentSize(host.fittingSize)
            return window
        }
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        return window
    }

    private static func keyEvent(code: UInt16, characters: String, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )
    }

    @MainActor
    private final class Answers {
        var cancelled = 0
        var confirmed = 0
        var focus: String?
    }

    private static func settle(_ window: NSWindow) async {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            await mainQueueTurns(1)
        }
    }

    private static func mainQueueTurns(_ count: Int) async {
        for _ in 0..<count {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private static func save(_ host: NSView, in directory: String, name: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(filePath: directory).appending(path: name + ".png"))
    }
}
#endif
