import AppKit
import SwiftUI

/// The Browser location field's AppKit half.
///
/// Command-L needs two operations to be one operation: make this exact field first responder and
/// select its contents. Driving a SwiftUI FocusState and selecting the window's field editor on a
/// later task can race another field, especially the Find bar in the same pane. NSTextField owns
/// both operations here, while the binding keeps the field's text and focus in SwiftUI's state.
struct BrowserAddressField: NSViewRepresentable {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var focusRequest: Int
    var isEditing: Bool
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
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "Address"
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.stringValue = text
        field.setAccessibilityLabel("Address")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let textColor = isEditing ? NSColor.labelColor : .clear
        field.textColor = textColor
        (field.currentEditor() as? NSTextView)?.textColor = textColor
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }

        if context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        } else if focus.wrappedValue,
                  field.window?.firstResponder !== field.currentEditor() {
            field.window?.makeFirstResponder(field)
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
