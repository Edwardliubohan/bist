import Foundation
import CoreGraphics

@main
struct PanelGeometryTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        func equal(_ first: CGFloat, _ second: CGFloat) -> Bool {
            abs(first - second) < 0.0001
        }

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let compact = CornerLayout.frame(expanded: false, visibleFrame: screen)
        let expanded = CornerLayout.frame(expanded: true, visibleFrame: screen)
        expect(CornerLayout.compactSize == CGSize(width: 48, height: 48), "compact window is 48 by 48")
        expect(CornerLayout.expandedSize == CGSize(width: 360, height: 560), "expanded preferred size is 360 by 560")
        expect(compact.size == CornerLayout.compactSize, "compact frame retains fixed size")
        expect(expanded.size == CornerLayout.expandedSize, "expanded frame retains preferred size when it fits")
        expect(equal(screen.maxX - compact.maxX, 16) && equal(screen.maxY - compact.maxY, 16), "compact top-right inset is 16 pt")
        expect(equal(screen.maxX - expanded.maxX, 16) && equal(screen.maxY - expanded.maxY, 16), "expanded top-right inset is 16 pt")
        expect(compact.maxX == expanded.maxX && compact.maxY == expanded.maxY, "expansion preserves the top-right anchor")
        let compactHit = CGRect(origin: .zero, size: CornerLayout.compactSize)
            .insetBy(dx: CornerLayout.compactHitInset, dy: CornerLayout.compactHitInset)
        expect(compactHit.size == CornerLayout.compactHitSize, "2 pt inset creates declared compact hit region")
        expect(compactHit.width >= 44 && compactHit.height >= 44, "compact hit target is at least 44 by 44")

        var interaction = CornerInteraction()
        expect(!interaction.isHovered && !interaction.isExpanded, "corner starts collapsed and unhovered")
        for _ in 0..<100 {
            interaction.pointerEntered()
            expect(interaction.isHovered && !interaction.isExpanded, "pointer entry never expands")
            expect(CornerLayout.frame(expanded: interaction.isExpanded, visibleFrame: screen) == compact, "pointer entry preserves geometry")
            interaction.pointerEntered()
            expect(interaction.isHovered && !interaction.isExpanded, "repeated entry is stable")
            interaction.pointerExited()
            expect(!interaction.isHovered && !interaction.isExpanded, "pointer exit stays collapsed")
            expect(CornerLayout.frame(expanded: interaction.isExpanded, visibleFrame: screen) == compact, "pointer exit preserves geometry")
            interaction.pointerExited()
            expect(!interaction.isHovered && !interaction.isExpanded, "repeated exit is stable")
        }
        interaction.pointerEntered()
        interaction.activate()
        expect(interaction.isExpanded && !interaction.isHovered, "explicit activation expands and clears hover")
        interaction.activate()
        expect(interaction.isExpanded && !interaction.isHovered, "repeated activation remains expanded")
        interaction.pointerEntered()
        interaction.pointerExited()
        expect(interaction.isExpanded && !interaction.isHovered, "pointer transitions never collapse an open panel")
        interaction.pointerEntered()
        interaction.collapse()
        expect(!interaction.isExpanded && !interaction.isHovered, "collapse clears expanded and hover state")
        interaction.collapse()
        expect(!interaction.isExpanded && !interaction.isHovered, "repeated collapse remains stable")

        let leftScreen = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        let leftCompact = CornerLayout.frame(expanded: false, visibleFrame: leftScreen)
        let leftExpanded = CornerLayout.frame(expanded: true, visibleFrame: leftScreen)
        expect(leftCompact == CGRect(x: -64, y: 836, width: 48, height: 48), "negative-origin compact frame uses actual screen coordinates")
        expect(leftExpanded == CGRect(x: -376, y: 324, width: 360, height: 560), "negative-origin expanded frame uses actual screen coordinates")
        expect(leftScreen.contains(leftCompact) && leftScreen.contains(leftExpanded), "negative-origin screen contains both frames")

        let smallScreen = CGRect(x: -320, y: -400, width: 320, height: 400)
        let smallExpanded = CornerLayout.frame(expanded: true, visibleFrame: smallScreen)
        expect(smallExpanded == CGRect(x: -304, y: -384, width: 288, height: 368), "expanded panel clamps to small visible screen with 16 pt margins")
        expect(smallScreen.contains(smallExpanded), "clamped expanded panel stays entirely on screen")
        expect(equal(smallScreen.maxX - smallExpanded.maxX, 16) && equal(smallScreen.maxY - smallExpanded.maxY, 16), "small screen preserves top-right inset")
        expect(CornerLayout.frame(expanded: false, visibleFrame: smallScreen).size == CornerLayout.compactSize, "compact size stays fixed on small usable screens")
        let narrowScreen = CGRect(x: 400, y: 30, width: 300, height: 900)
        let narrowExpanded = CornerLayout.frame(expanded: true, visibleFrame: narrowScreen)
        expect(narrowExpanded.size == CGSize(width: 268, height: 560), "width clamping does not unnecessarily shrink height")
        let shortScreen = CGRect(x: 50, y: 60, width: 900, height: 300)
        let shortExpanded = CornerLayout.frame(expanded: true, visibleFrame: shortScreen)
        expect(shortExpanded.size == CGSize(width: 360, height: 268), "height clamping does not unnecessarily shrink width")
        let tinyScreen = CGRect(x: -10, y: -20, width: 10, height: 20)
        let tinyExpanded = CornerLayout.frame(expanded: true, visibleFrame: tinyScreen)
        expect(tinyExpanded.width >= 0 && tinyExpanded.height >= 0, "degenerate available space never produces a negative size")
        expect(tinyExpanded.minX >= tinyScreen.minX && tinyExpanded.maxX <= tinyScreen.maxX && tinyExpanded.minY >= tinyScreen.minY && tinyExpanded.maxY <= tinyScreen.maxY, "degenerate geometry stays within visible bounds")

        var focus = ButtonFocusPolicy()
        expect(!focus.keyboardNavigation, "focus starts in pointer mode")
        focus.pointerDown()
        expect(!ButtonFocusPolicy.showsRing(focused: true, keyboardNavigation: focus.keyboardNavigation), "mouse click hides ring even when button owns focus")
        for code: UInt16 in [48, 49, 36, 76, 123, 124, 125, 126] {
            focus.pointerDown()
            focus.keyDown(code: code)
            expect(focus.keyboardNavigation, "navigation or activation key enables keyboard mode: \(code)")
            expect(ButtonFocusPolicy.showsRing(focused: true, keyboardNavigation: focus.keyboardNavigation), "keyboard-focused button shows its ring: \(code)")
            expect(!ButtonFocusPolicy.showsRing(focused: false, keyboardNavigation: focus.keyboardNavigation), "unfocused button never shows keyboard ring: \(code)")
            focus.pointerDown()
            expect(!focus.keyboardNavigation && !ButtonFocusPolicy.showsRing(focused: true, keyboardNavigation: focus.keyboardNavigation), "subsequent mouse click hides keyboard ring: \(code)")
        }
        for code: UInt16 in [0, 1, 2, 18, 51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63] {
            focus.pointerDown()
            focus.keyDown(code: code)
            expect(!focus.keyboardNavigation, "text, modifier, and non-navigation keys do not start keyboard mode: \(code)")
            focus.keyDown(code: 48)
            focus.keyDown(code: code)
            expect(focus.keyboardNavigation, "ordinary keys preserve established keyboard mode: \(code)")
        }
        expect(!ButtonFocusPolicy.showsRing(focused: false, keyboardNavigation: false), "unfocused pointer mode has no ring")
        let previewFrame = CornerLayout.previewFrame(anchor: compact, contentHeight: 171, visibleFrame: screen)
        expect(previewFrame.width == 260 && previewFrame.height == 179, "preview has a 260 pt surface plus 8 pt transparent bridge")
        expect(previewFrame.maxX == compact.maxX && previewFrame.maxY == compact.minY, "preview bridge touches stationary icon without moving it")
        expect(previewFrame.maxY - CornerLayout.previewGap == compact.minY - 8, "visible preview starts 8 pt below the icon")
        expect(CornerLayout.previewFrame(anchor: compact, contentHeight: 1000, visibleFrame: screen).height == 248, "preview content caps at 240 pt")
        let smallPreview = CornerLayout.previewFrame(anchor: CornerLayout.frame(expanded: false, visibleFrame: smallScreen), contentHeight: 240, visibleFrame: smallScreen)
        expect(smallScreen.contains(smallPreview), "preview stays on a negative-origin small screen")
        let shortPreview = CornerLayout.previewFrame(anchor: CornerLayout.frame(expanded: false, visibleFrame: shortScreen), contentHeight: 240, visibleFrame: shortScreen)
        expect(shortScreen.contains(shortPreview), "preview clamps vertically to available space")

        var preview = HoverPreviewInteraction()
        expect(!preview.isVisible && preview.pending == nil, "preview starts hidden without a timer")
        preview.pointerChanged(.corner, inside: true, at: 1)
        let initial = preview.pending!
        expect(initial.intent == .show && abs(initial.deadline - 1.25) < 0.001, "corner enter schedules 250 ms intent")
        preview.pointerChanged(.corner, inside: true, at: 1.1)
        expect(preview.pending == initial, "repeated pointer events do not extend intent delay")
        expect(!preview.advance(at: 1.249, generation: initial.generation) && !preview.isVisible, "preview remains hidden before deadline")
        expect(preview.advance(at: 1.25, generation: initial.generation) && preview.isVisible, "preview appears after sustained hover")
        expect(preview.pending == nil, "show consumes intent timer")
        preview.pointerChanged(.corner, inside: false, at: 2)
        let leave = preview.pending!
        expect(leave.intent == .hide && abs(leave.deadline - 2.16) < 0.001, "leaving schedules 160 ms dismissal grace")
        preview.pointerChanged(.bridge, inside: true, at: 2.05)
        expect(preview.pending == nil && preview.isVisible, "entering transparent gap bridge cancels dismissal")
        expect(!preview.advance(at: 2.2, generation: leave.generation) && preview.isVisible, "cancelled hide callback cannot dismiss while crossing gap")
        preview.pointerChanged(.preview, inside: true, at: 2.1)
        preview.pointerChanged(.bridge, inside: false, at: 2.11)
        expect(preview.isVisible && preview.pending == nil, "preview body keeps read-only popup open")
        preview.pointerChanged(.preview, inside: false, at: 3)
        let dismissal = preview.pending!
        expect(!preview.advance(at: 3.15, generation: dismissal.generation) && preview.isVisible, "leave grace tolerates a short pointer excursion")
        expect(preview.advance(at: 3.17, generation: dismissal.generation) && !preview.isVisible, "leaving both surfaces dismisses after grace")

        preview.pointerChanged(.corner, inside: true, at: 4)
        let cancelledShow = preview.pending!
        preview.pointerChanged(.corner, inside: false, at: 4.1)
        expect(preview.pending == nil, "brief hover cancels pending show")
        expect(!preview.advance(at: 4.3, generation: cancelledShow.generation) && !preview.isVisible, "stale show callback cannot resurrect preview")
        preview.pointerChanged(.corner, inside: true, at: 5)
        let escaping = preview.pending!
        expect(preview.escape() && preview.pending == nil, "Escape cancels pending intent")
        expect(!preview.advance(at: 5.3, generation: escaping.generation), "Escape invalidates stale callback")
        preview.pointerChanged(.corner, inside: true, at: 5.4)
        expect(preview.pending == nil && !preview.isVisible, "remaining over icon after Escape does not reopen")
        preview.pointerChanged(.corner, inside: false, at: 5.5)
        preview.pointerChanged(.corner, inside: true, at: 6)
        let reopened = preview.pending!
        _ = preview.advance(at: 6.3, generation: reopened.generation)
        expect(preview.isVisible, "leaving and returning after Escape allows preview again")
        expect(preview.escape() && !preview.isVisible, "Escape dismisses visible preview")
        expect(!preview.escape(), "Escape is unhandled when nothing is pending or visible")
        preview.pointerChanged(.corner, inside: false, at: 7)
        preview.pointerChanged(.corner, inside: true, at: 8)
        let beforeClick = preview.pending!
        preview.setExpanded(true)
        expect(preview.isExpanded && !preview.isVisible && preview.pending == nil, "explicit full activation cancels pending preview")
        expect(!preview.advance(at: 9, generation: beforeClick.generation), "timer from before activation cannot reopen popup")
        preview.pointerChanged(.corner, inside: true, at: 9)
        expect(!preview.isVisible && preview.pending == nil, "hover cannot create popup while full panel is open")
        preview.setExpanded(false)
        expect(preview.regions.isEmpty && preview.pending == nil, "collapse starts fresh without phantom pointer regions")
        preview.pointerChanged(.preview, inside: true, at: 10)
        expect(preview.pending == nil, "orphan preview tracking cannot open a popup")
        preview.cancel()
        expect(preview.regions.isEmpty, "hidden native preview does not retain stale hover region")
        for index in 0..<100 {
            let now = Double(index + 20)
            preview.pointerChanged(.corner, inside: true, at: now)
            let stale = preview.pending!
            preview.pointerChanged(.corner, inside: false, at: now + 0.05)
            preview.pointerChanged(.corner, inside: true, at: now + 0.1)
            let current = preview.pending!
            expect(!preview.advance(at: now + 0.4, generation: stale.generation), "rapid reentry rejects old generation")
            expect(preview.advance(at: now + 0.4, generation: current.generation), "rapid reentry keeps newest generation actionable")
            preview.pointerChanged(.corner, inside: false, at: now + 0.5)
            let close = preview.pending!
            _ = preview.advance(at: now + 0.7, generation: close.generation)
            expect(!preview.isVisible, "rapid interaction cycle returns to hidden state")
        }
        struct PreviewFixture {
            let id: String
            let short: Bool
            let completed: Bool
        }
        let previewItems = [
            PreviewFixture(id: "long-first", short: false, completed: false),
            PreviewFixture(id: "short-first", short: true, completed: false),
            PreviewFixture(id: "completed", short: true, completed: true),
            PreviewFixture(id: "long-second", short: false, completed: false),
            PreviewFixture(id: "short-second", short: true, completed: false)
        ]
        let picked = PreviewTaskSelection(previewItems, isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(picked.shortTerm.map(\.id) == ["short-first", "short-second"], "preview preserves store order inside Short term")
        expect(picked.longerTerm.map(\.id) == ["long-first"], "Longer term follows Short term within the three-task limit")
        expect(picked.outstandingCount == 4 && picked.visibleCount == 3, "preview total excludes completed tasks and retains hidden count")
        expect(picked.visibleGroupCount == 2, "mixed preview has both horizon headers")
        let allPicked = PreviewTaskSelection(previewItems, limit: 10, isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(allPicked.longerTerm.map(\.id) == ["long-first", "long-second"], "longer-term order is stable independently of input interleaving")
        let zeroPicked = PreviewTaskSelection(previewItems, limit: -1, isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(zeroPicked.visibleCount == 0 && zeroPicked.outstandingCount == 4, "invalid negative limit never exposes tasks")
        let longOnly = PreviewTaskSelection(previewItems.filter { !$0.short }, isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(longOnly.shortTerm.isEmpty && longOnly.longerTerm.count == 2 && longOnly.visibleGroupCount == 1, "only Longer term remains accurately labeled")
        let emptyPreview = PreviewTaskSelection([PreviewFixture](), isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(emptyPreview.outstandingCount == 0 && emptyPreview.visibleGroupCount == 0, "empty preview emits no false group headers")
        print("PASS: \(checks) panel geometry and interaction checks")
    }
}
