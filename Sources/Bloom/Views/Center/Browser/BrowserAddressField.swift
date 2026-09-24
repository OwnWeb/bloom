import AppKit
import BloomCore
import SwiftUI

/// The Browser location field's AppKit half.
///
/// Command-L needs two operations to be one operation: make this exact field first responder and
/// select its contents. Driving a SwiftUI FocusState and selecting the window's field editor on a
/// later task can race another field, especially the Find bar in the same pane. NSTextField owns
/// both operations here, while the binding keeps the field's text and focus in SwiftUI's state.
struct BrowserAddressField: NSViewRepresentable {
    /// Matches the 12 point `Typo.label` used by the read-only browser address.
    private static let addressFont = NSFont.systemFont(ofSize: 12)

    @Binding var text: String
    var focus: Binding<Bool>
    var focusRequest: Int
    var submit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.addressFont
        field.placeholderString = "Address"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.stringValue = text
        field.setAccessibilityLabel("Address")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil {
            let display = BrowserAddressDisplay.of(text)
            let attributed = NSMutableAttributedString(string: display.leading + display.host + display.trailing)
            if attributed.length > 0 {
                attributed.addAttributes([
                    .font: Self.addressFont,
                    .foregroundColor: NSColor(Palette.textTertiaryOnGlass),
                ], range: NSRange(location: 0, length: attributed.length))
            }
            if !display.host.isEmpty {
                let hostRange = NSRange(location: (display.leading as NSString).length, length: (display.host as NSString).length)
                attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: hostRange)
            }
            if !field.attributedStringValue.isEqual(to: attributed) {
                field.attributedStringValue = attributed
            }
        }

        if context.coordinator.handledFocusRequest != focusRequest, field.window != nil {
            context.coordinator.handledFocusRequest = focusRequest
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        } else if focus.wrappedValue,
                  field.window?.firstResponder !== field.currentEditor() {
            field.window?.makeFirstResponder(field)
        } else if !focus.wrappedValue,
                  let editor = field.currentEditor(),
                  field.window?.firstResponder === editor {
            field.window?.makeFirstResponder(nil)
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil
        field.target = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BrowserAddressField
        var handledFocusRequest: Int

        init(_ parent: BrowserAddressField) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView {
                if editor.string != parent.text {
                    editor.string = parent.text
                }
                if !editor.string.isEmpty {
                    editor.textStorage?.addAttributes([
                        .font: BrowserAddressField.addressFont,
                        .foregroundColor: NSColor.labelColor,
                    ], range: NSRange(location: 0, length: (editor.string as NSString).length))
                }
                editor.isAutomaticSpellingCorrectionEnabled = false
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false
            }
            parent.focus.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.focus.wrappedValue = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSTextField) {
            parent.text = sender.stringValue
            parent.submit()
        }
    }
}
