import AppKit
import SwiftUI

// 使用原生输入控件，中文输入法的候选词和组合输入由系统处理。
struct PreviewSearchField: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    let onCommand: (Selector) -> Bool
    let onCompositionChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "筛选窗口"
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityLabel("筛选窗口标题")
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if view.stringValue != text { view.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PreviewSearchField
        init(_ parent: PreviewSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.onCompositionChange((field.currentEditor() as? NSTextView)?.hasMarkedText() == true)
            parent.onChange(field.stringValue)
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onCompositionChange(false) }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            return parent.onCommand(commandSelector)
        }
    }
}
