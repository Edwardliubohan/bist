import AppKit
import SwiftUI

struct NotePane: View {
    @ObservedObject var note: NoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if note.text.isEmpty {
                    Text("Write a note…")
                        .foregroundColor(muted)
                        .padding(.horizontal, 5).padding(.top, 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                NoteEditor(text: Binding(get: { note.text }, set: { note.update($0) }))
                    .foregroundColor(ink)
                    .bistTextEntry()
                    .accessibilityLabel("Note")
                    .accessibilityHint("One plain-text note. Changes save automatically on this Mac.")
            }
            .font(.system(size: 13)).lineSpacing(5)
            if let error = note.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    if note.canRetrySave {
                        BistButton("Retry save") { note.save() }
                            .buttonStyle(.plain).foregroundColor(accent)
                    }
                }.font(.system(size: 11)).foregroundColor(ink)
            } else {
                Text("Saved on this Mac").font(.system(size: 10)).foregroundColor(muted)
            }
        }
        .padding(.horizontal, 17).padding(.top, 14).padding(.bottom, 16)
    }
}

/// Own the native text container so its final empty line participates in sizing
/// and scrolling. SwiftUI's lazily laid out TextEditor can miss that fragment.
private struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = true
        let editor = NoteTextView(frame: .zero, textContainer: container)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = .zero
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Note")
        editor.setAccessibilityHelp("One plain-text note. Changes save automatically on this Mac.")
        let scroll = NoteScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        styleGlassScrollViews(in: scroll)
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NoteTextView else { return }
        let wasSuppressed = editor.suppressesReveal
        editor.suppressesReveal = true
        defer { editor.suppressesReveal = wasSuppressed }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(ink), .paragraphStyle: paragraph
        ]
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = NSColor(ink)
        editor.insertionPointColor = NSColor(accent)
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = attributes
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            let length = (text as NSString).length
            let start = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        }
        editor.sizeToFit()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        init(parent: NoteEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NoteTextView else { return }
            parent.text = editor.string
            editor.revealSoon()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NoteTextView)?.revealSoon(ensureClearance: false)
        }
    }
    final class NoteScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let editor = documentView as? NoteTextView else { return }
            editor.minSize = CGSize(width: 0, height: contentSize.height)
            editor.sizeToFit()
        }
    }
    final class NoteTextView: NSTextView {
        private var revealing = false
        private var fitting = false
        private var revealPending = false
        private var needsCaretClearance = false
        var suppressesReveal = false
        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            guard !fitting, changed else { return }
            sizeToFit()
            revealSoon()
        }
        func revealSoon(ensureClearance: Bool = true) {
            guard !suppressesReveal else { return }
            needsCaretClearance = needsCaretClearance || ensureClearance
            guard !revealPending else { return }
            revealPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ensureClearance = self.needsCaretClearance
                self.revealPending = false
                self.needsCaretClearance = false
                self.revealInsertionPoint(ensureClearance: ensureClearance)
            }
        }
        override func sizeToFit() {
            guard !fitting, let layout = layoutManager, let container = textContainer else { return }
            fitting = true
            defer { fitting = false }
            layout.ensureLayout(for: container)
            let bottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            let height = max(minSize.height, bottom + textContainerOrigin.y + 24)
            if frame.height != height { super.setFrameSize(CGSize(width: frame.width, height: height)) }
        }
        func revealInsertionPoint(ensureClearance: Bool) {
            guard !suppressesReveal, !revealing, window?.firstResponder === self, selectedRange().length == 0,
                  !hasMarkedText(), let layout = layoutManager, let container = textContainer else { return }
            revealing = true
            defer { revealing = false }
            layout.ensureLayout(for: container)
            sizeToFit()
            let location = selectedRange().location
            var caret: CGRect
            if location == (string as NSString).length && (string.isEmpty || string.hasSuffix("\n")) {
                caret = layout.extraLineFragmentRect
            } else {
                let glyph = layout.glyphIndexForCharacter(at: min(location, max(0, (string as NSString).length - 1)))
                caret = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            guard caret.height > 0 else { return }
            caret = caret.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            // Plain clicks and drag-selection must leave visible text still.
            // Edits and resizing request clearance even when the caret fits.
            if !ensureClearance, caret.minY >= visibleRect.minY, caret.maxY <= visibleRect.maxY { return }
            scrollToVisible(caret.insetBy(dx: 0, dy: -24))
        }
    }
}
