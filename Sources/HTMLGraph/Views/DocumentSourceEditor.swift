import AppKit
import SwiftUI

/// A plain-text source editor for a document's raw HTML, wrapping `NSTextView` for real
/// undo, a native Find bar, and large-file performance. Deliberately NOT a `WKWebView`:
/// editing source needs no JavaScript and no Trusted mode, so it stays entirely within
/// Safe-mode rendering security (the preview re-applies the policy only when it rebuilds).
struct DocumentSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)

        // HTML source is literal: every "smart" substitution would silently corrupt the
        // bytes the user is editing (curly quotes, en-dashes, autocorrect).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        // Native Find bar (Cmd-F) without leaving the editor.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Don't wrap-track the view width; let long source lines scroll horizontally.
        scrollView.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        textView.string = text
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        textView.isEditable = isEditable

        // Only push the model into the view when they actually differ — e.g. a programmatic
        // baseline reload after Discard/conflict-Reload. Re-setting on every keystroke
        // echo would fight the user's cursor. A direct `.string` assignment does not post
        // textDidChange and does not register an undo action, so it can't pollute either.
        if textView.string != text {
            let previousSelection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let clampedLocation = min(previousSelection.location, length)
            textView.setSelectedRange(NSRange(location: clampedLocation, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // User-originated edit: write straight through. updateNSView will then see
            // equal strings and skip, so the cursor stays put.
            text.wrappedValue = textView.string
        }
    }
}
