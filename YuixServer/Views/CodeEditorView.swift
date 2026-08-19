import SwiftUI
import UIKit

/// 带语法高亮的代码编辑器。用 UITextView 承载，输入时实时重新着色，
/// 并保留光标/选区位置，避免高亮重绘导致光标跳动。
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var language: Language

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.backgroundColor = .clear
        tv.textColor = .label
        tv.text = text
        applyHighlighting(to: tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text {
            tv.text = text
            applyHighlighting(to: tv)
        }
    }

    /// 保存光标 -> 重着色 -> 恢复光标
    private func applyHighlighting(to tv: UITextView) {
        let selected = tv.selectedRange
        tv.textStorage.setAttributedString(SyntaxHighlighter.highlight(tv.text, language: language))
        tv.selectedRange = selected
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        init(_ parent: CodeEditorView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            parent.applyHighlighting(to: tv)
        }
    }
}