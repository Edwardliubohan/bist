import AppKit
import SwiftUI

/// Exercise the shipping NotePane and its native editor in isolated storage.
@MainActor private final class NoteScrollRunner: NSObject, NSApplicationDelegate {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-note-scroll-\(UUID())")
    var note: NoteStore!
    var panel: FloatingPanel!
    var host: GlassHostingView<AnyView>!
    func applicationDidFinishLaunching(_ notification: Notification) {
        note = NoteStore(directory: directory)
        note.update((1...65).map { "Line \($0) of a long note" }.joined(separator: "\n"))
        panel = FloatingPanel(contentRect: CGRect(x: 100, y: 100, width: 360, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        host = GlassHostingView(rootView: AnyView(NotePane(note: note)
            .environmentObject(BistFocusContext()).tint(accent).background(ivory)))
        host.sizingOptions = []
        panel.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            try await self.runChecks()
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
    }
    func runChecks() async throws {
        defer { panel.orderOut(nil); try? FileManager.default.removeItem(at: directory) }
        try await Task.sleep(for: .milliseconds(350))
        func pump() async { try? await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        func findEditor(_ view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView { return editor }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        await pump()
        panel.makeKeyAndOrderFront(nil); await pump()
        let editor = findEditor(host)!
        let scroll = editor.enclosingScrollView!
        // Geometry comes from TextKit, so another foreground app cannot turn
        // this scrolling regression into an unrelated activation failure.
        precondition(panel.makeFirstResponder(editor), "Note accepts native keyboard focus")
        let originalText = note.text
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let visibleTop = scroll.contentView.bounds.origin
        let thirdLine = (editor.string as NSString).range(of: "Line 3 of a long note").location
        editor.setSelectedRange(NSRange(location: thirdLine, length: 0)); await pump()
        precondition(abs(scroll.contentView.bounds.minY - visibleTop.y) < 1,
                     "Placing the caret on an already visible line must not jump to the bottom")
        let layout = editor.layoutManager!
        layout.ensureLayout(for: editor.textContainer!)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        let middleViewport = editor.visibleRect
        var edgeSelections: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            let line = rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            if line.minY >= middleViewport.minY && line.maxY <= middleViewport.maxY &&
               min(line.minY - middleViewport.minY, middleViewport.maxY - line.maxY) < 24 {
                edgeSelections.append(layout.characterIndexForGlyph(at: glyphs.location))
            }
        }
        precondition(edgeSelections.count >= 2, "Fixture includes visible lines near both viewport edges")
        for location in [edgeSelections.first!, edgeSelections.last!] {
            scroll.contentView.scroll(to: middleViewport.origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.setSelectedRange(NSRange(location: location, length: 0)); await pump()
            precondition(abs(scroll.contentView.bounds.minY - middleViewport.minY) < 1,
                         "Selecting an already visible edge line must leave the text stationary")
        }
        precondition(editor.textContainerOrigin.y == 0, "First-line alignment matches the original note editor")
        for incoming in [originalText + "\nAn incoming line", "An incoming heading\n" + originalText,
                         originalText.replacingOccurrences(of: "long note", with: "kept note")] {
            editor.setSelectedRange(NSRange(location: 0, length: 0)); await pump()
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 400))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pump()
            let readingOrigin = scroll.contentView.bounds.origin
            note.update(incoming); await pump()
            precondition(editor.string == incoming && panel.firstResponder === editor,
                         "Incoming note updates preserve the focused editor")
            precondition(abs(scroll.contentView.bounds.minY - readingOrigin.y) < 1,
                         "Incoming note updates must preserve the reading position when the caret is offscreen")
        }
        note.update(originalText); await pump()
        var checks = 0
        var minimumClearance = CGFloat.greatestFiniteMagnitude
        func expectCaretVisible(_ label: String) {
            var caret = CGRect.zero
            if let layout = editor.textLayoutManager, let content = layout.textContentManager,
               let location = content.location(content.documentRange.location, offsetBy: editor.selectedRange().location) {
                let range = NSTextRange(location: location)
                layout.ensureLayout(for: content.documentRange)
                layout.enumerateTextSegments(in: range, type: .selection, options: []) { _, rect, _, _ in
                    caret = rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    return false
                }
            } else if let layout = editor.layoutManager, let container = editor.textContainer {
                layout.ensureLayout(for: container)
                if editor.string.hasSuffix("\n") {
                    caret = layout.extraLineFragmentRect
                } else {
                    let glyph = layout.glyphIndexForCharacter(at: max(0, editor.selectedRange().location - 1))
                    caret = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                }
                caret = caret.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            }
            let visible = editor.visibleRect
            let clearance = visible.maxY - caret.maxY
            precondition(caret.height > 0 && caret.minY >= visible.minY - 1 && clearance >= 18,
                         "\(label) must show the final line with clearance. Caret \(caret), visible \(visible), clearance \(clearance)")
            minimumClearance = min(minimumClearance, clearance)
            checks += 1
        }
        for size in [CGSize(width: 360, height: 500), CGSize(width: 520, height: 300)] {
            panel.setContentSize(size); await pump()
            if checks > 0 { expectCaretVisible("Resizing while editing") }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange()); await pump()
            for _ in 0..<8 {
                editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
                await pump()
                expectCaretVisible("Return at \(size)")
            }
            editor.insertText(String(repeating: "wrapped last line ", count: 30), replacementRange: editor.selectedRange())
            await pump(); expectCaretVisible("Wrapped final line at \(size)")
            precondition(note.text == editor.string, "Native edits update the NoteStore binding")
            editor.breakUndoCoalescing()
            editor.insertText(" undo me", replacementRange: editor.selectedRange()); await pump()
            let withUndo = editor.string
            editor.breakUndoCoalescing()
            editor.undoManager?.undo(); await pump()
            // AppKit may coalesce consecutive typing into one undo step.
            precondition(editor.string != withUndo && withUndo.hasPrefix(editor.string) &&
                         editor.string.hasPrefix(originalText) && note.text == editor.string,
                         "Undo restores an earlier note state and updates the binding")
            editor.undoManager?.redo(); await pump()
            precondition(editor.string == withUndo && note.text == withUndo, "Redo restores the complete edit")
            precondition(scroll.documentVisibleRect.height > 0, "Editor keeps a usable scrolling viewport")
        }
        note.save()
        precondition(NoteStore(directory: directory).text == note.text, "Edited notes persist")
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/note-scroll.png"))
        panel.makeFirstResponder(nil)
        note.update("An external note update"); await pump()
        precondition(editor.string == note.text, "External note updates reach the native editor")
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        note.update("An external note update with more text"); await pump()
        precondition(editor.selectedRange() == NSRange(location: 3, length: 4), "External updates preserve a valid selection")
        note.update(""); await pump()
        precondition(editor.string.isEmpty, "Clearing the note restores its empty state")
        precondition(editor.frame.height >= scroll.contentSize.height,
                     "An empty note keeps its whole viewport available for clicking and typing")
        print("PASS \(checks) final note line visibility checks, minimum clearance \(minimumClearance), binding, undo, persistence and external updates")
    }
}

@main struct NoteScrollTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = NoteScrollRunner()
        app.delegate = runner
        app.run()
        withExtendedLifetime(runner) {}
    }
}
