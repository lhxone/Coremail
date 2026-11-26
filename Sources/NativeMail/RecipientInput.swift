import AppKit
import SwiftUI

enum RecipientKey { case up, down, accept, dismiss, removePrevious }

/// Handle completion commands in the field editor before AppKit submits the text.
struct RecipientInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let isFocused: Bool
    let focusChanged: (Bool) -> Void
    let key: (RecipientKey) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
        if isFocused, field.currentEditor() == nil {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard let field, coordinator?.parent.isFocused == true, field.currentEditor() == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RecipientInput
        init(_ parent: RecipientInput) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.focusChanged(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focusChanged(false) }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty, !textView.hasMarkedText() else { return false }
                return parent.key(.removePrevious)
            case #selector(NSResponder.moveDown(_:)): return parent.key(.down)
            case #selector(NSResponder.moveUp(_:)): return parent.key(.up)
            case #selector(NSResponder.insertNewline(_:)): return parent.key(.accept)
            case #selector(NSResponder.cancelOperation(_:)): return parent.key(.dismiss)
            default: return false
            }
        }
    }
}
