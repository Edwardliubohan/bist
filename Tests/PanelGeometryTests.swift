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
        for scale: CGFloat in [1, 2] {
            let fractional = CGRect(x: -123.76171875, y: 944.0703125, width: 48, height: 48)
            let aligned = CornerLayout.pixelAligned(fractional, scale: scale)
            expect(aligned.size == fractional.size, "Pixel alignment preserves the hit target size")
            expect(aligned.minX * scale == (aligned.minX * scale).rounded() && aligned.minY * scale == (aligned.minY * scale).rounded(), "Dragged origins are on the physical pixel grid")
            expect(CornerLayout.pixelAligned(aligned, scale: scale) == aligned, "Repeated alignment never moves the origin")
        }
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

        var drag = CompactDrag(pointer: CGPoint(x: 100, y: 100), origin: CGPoint(x: 400, y: 500))
        expect(drag.update(pointer: CGPoint(x: 102, y: 101)) == nil && !drag.moved, "click jitter does not start a drag")
        expect(drag.update(pointer: CGPoint(x: 110, y: 80)) == CGPoint(x: 410, y: 480), "drag uses screen delta from original press")
        expect(drag.update(pointer: CGPoint(x: 100, y: 100)) == CGPoint(x: 400, y: 500) && drag.moved, "returning to start remains a drag, never a click")
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 400), CGPoint(x: 1464, y: 896), CGPoint(x: -5000, y: 5000)] {
            let movedCompact = CornerLayout.frame(expanded: false, visibleFrame: screen, compactOrigin: origin)
            let movedExpanded = CornerLayout.frame(expanded: true, visibleFrame: screen, compactOrigin: movedCompact.origin)
            expect(screen.contains(movedCompact) && screen.contains(movedExpanded), "moved compact and expanded frames remain accessible at every edge")
            expect(CornerLayout.frame(expanded: false, visibleFrame: screen, compactOrigin: movedCompact.origin) == movedCompact, "collapse restores compact origin after expansion clamping")
            let movedPreview = CornerLayout.previewFrame(anchor: movedCompact, contentHeight: 171, visibleFrame: screen)
            expect(screen.contains(movedPreview) && movedPreview.height == 179, "preview fits above or below a moved icon")
        }
        let bottomAnchor = CornerLayout.frame(expanded: false, visibleFrame: screen, compactOrigin: .zero)
        expect(CornerLayout.previewFrame(anchor: bottomAnchor, contentHeight: 171, visibleFrame: screen).minY == bottomAnchor.maxY, "bottom-edge preview opens above icon")

        let shortDestination = CGRect(x: -800, y: -500, width: 800, height: 500)
        let crossDisplay = CornerLayout.dragFrame(expanded: true, origin: CGPoint(x: -500, y: -500), visibleFrame: shortDestination)
        expect(shortDestination.contains(crossDisplay), "drag refits expanded panel on shorter destination display")
        expect(crossDisplay.size == CGSize(width: 360, height: 468), "drag uses destination fitted content size")
        expect(CornerLayout.dragFrame(expanded: true, origin: .zero, visibleFrame: screen).size == CornerLayout.expandedSize, "drag restores preferred size on a larger display")
        expect(shortDestination.contains(CornerLayout.clamped(CGRect(x: -2000, y: -1000, width: 1000, height: 900), to: shortDestination)), "generic clamp also fits oversized frames")

        let inputRegions = [BistInteractionRegion(kind: .text, rect: CGRect(x: 40, y: 490, width: 240, height: 25)),
                            BistInteractionRegion(kind: .drag, rect: CGRect(x: 190, y: 0, width: 90, height: 48))]
        expect(BistInteractionRegion.contains(.text, point: CGPoint(x: 100, y: 55), contentHeight: 560, regions: inputRegions), "native input click maps into SwiftUI field bounds")
        expect(!BistInteractionRegion.contains(.text, point: CGPoint(x: 180, y: 210), contentHeight: 560, regions: inputRegions), "blank panel space is outside editable bounds and blurs input")
        expect(BistInteractionRegion.contains(.drag, point: CGPoint(x: 230, y: 536), contentHeight: 560, regions: inputRegions), "blank header starts drag")
        expect(!BistInteractionRegion.contains(.drag, point: CGPoint(x: 100, y: 536), contentHeight: 560, regions: inputRegions), "header buttons keep their click action")
        expect(!BistInteractionRegion.contains(.text, point: CGPoint(x: 100, y: 55), contentHeight: 560, regions: []), "removed field has no stale clickable region")

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
        expect(CornerLayout.previewFrame(anchor: compact, contentHeight: 1000, visibleFrame: screen).height == 728, "preview content caps at 720 pt plus bridge")
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
        expect(picked.longerTerm.map(\.id) == ["long-first", "long-second"], "all Longer term tasks follow Short term in store order")
        expect(picked.outstandingCount == 4 && picked.visibleCount == 4, "preview includes every outstanding task and excludes completed tasks")
        expect(picked.visibleGroupCount == 2, "mixed preview has both horizon headers")
        let manyItems = (0..<30).map { PreviewFixture(id: "short-\($0)", short: true, completed: false) }
        let manyPicked = PreviewTaskSelection(manyItems + previewItems, isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(manyPicked.shortTerm.map(\.id) == (manyItems + previewItems.filter { $0.short && !$0.completed }).map(\.id), "preview keeps all short-term tasks in store order")
        expect(manyPicked.visibleCount == 34 && manyPicked.outstandingCount == 34 && manyPicked.longerTerm.count == 2, "long lists retain both horizons without truncation")
        expect(manyPicked.contentHeight > CornerLayout.previewMaximumHeight, "long lists request enough content to scroll within the bounded panel")
        let mixedPicked = PreviewTaskSelection(Array(manyItems.prefix(14)) + previewItems.filter { !$0.short }, isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(mixedPicked.shortTerm.count == 14 && mixedPicked.longerTerm.map(\.id) == ["long-first", "long-second"], "Longer term remains accessible after many Short term tasks")
        let manyLong = PreviewTaskSelection((0..<20).map { PreviewFixture(id: "long-\($0)", short: false, completed: false) }, isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(manyLong.longerTerm.count == 20 && manyLong.visibleCount == 20, "longer-term-only preview retains every task")
        let longOnly = PreviewTaskSelection(previewItems.filter { !$0.short }, isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(longOnly.shortTerm.isEmpty && longOnly.longerTerm.count == 2 && longOnly.visibleGroupCount == 1, "only Longer term remains accurately labeled")
        let emptyPreview = PreviewTaskSelection([PreviewFixture](), isOutstanding: { !$0.completed }, isShortTerm: { $0.short })
        expect(emptyPreview.outstandingCount == 0 && emptyPreview.visibleGroupCount == 0, "empty preview emits no false group headers")
        expect(emptyPreview.contentHeight == 42, "empty preview uses a single concise line")
        let cornerCenter = CGPoint(x: compact.midX, y: compact.midY)
        let bridgeCenter = CGPoint(x: compact.midX, y: previewFrame.maxY - 4)
        let previewCenter = CGPoint(x: previewFrame.midX, y: previewFrame.midY)
        let outside = CGPoint(x: previewFrame.minX - 1, y: previewFrame.midY)
        expect(CornerLayout.previewRegions(pointer: cornerCenter, anchor: compact, preview: nil) == [.corner], "pointer samples recognize the compact hit region")
        expect(CornerLayout.previewRegions(pointer: compact.origin, anchor: compact, preview: nil).isEmpty, "transparent corner padding is not a hover target")
        expect(CornerLayout.previewRegions(pointer: bridgeCenter, anchor: compact, preview: previewFrame) == [.bridge], "pointer samples preserve the transparent bridge")
        expect(CornerLayout.previewRegions(pointer: previewCenter, anchor: compact, preview: previewFrame) == [.preview], "pointer samples recognize visible preview content")
        expect(CornerLayout.previewRegions(pointer: previewCenter, anchor: compact, preview: nil).isEmpty, "hidden preview geometry never keeps hover alive")
        expect(CornerLayout.previewRegions(pointer: outside, anchor: compact, preview: previewFrame).isEmpty, "pointer outside both surfaces clears all regions")
        let negativeAnchor = CornerLayout.frame(expanded: false, visibleFrame: smallScreen)
        expect(CornerLayout.previewRegions(pointer: CGPoint(x: negativeAnchor.midX, y: negativeAnchor.midY), anchor: negativeAnchor, preview: nil) == [.corner], "sampling uses screen coordinates on negative-origin displays")

        var sampled = HoverPreviewInteraction()
        expect(!sampled.needsPointerSampling, "idle hidden preview does not poll")
        sampled.pointerChanged(.corner, inside: true, at: 100)
        expect(sampled.needsPointerSampling, "pending hover starts pointer sampling")
        let missedShowExit = sampled.pending!
        sampled.reconcilePointer(regions: [], at: 100.1)
        expect(!sampled.advance(at: 100.3, generation: missedShowExit.generation) && !sampled.isVisible, "sampled leave cancels show after missed tracking exit")
        expect(!sampled.needsPointerSampling, "cancelled pending hover stops sampling")
        sampled.reconcilePointer(regions: [.corner], at: 101)
        _ = sampled.advance(at: 101.25, generation: sampled.pending!.generation)
        sampled.reconcilePointer(regions: [.preview], at: 101.3)
        expect(sampled.isVisible && sampled.regions == [.preview] && sampled.pending == nil, "atomic sample removes stale corner while entering preview")
        sampled.reconcilePointer(regions: [.bridge], at: 101.4)
        expect(sampled.pending == nil && sampled.isVisible, "bridge sampling keeps visible preview open")
        sampled.reconcilePointer(regions: [], at: 102)
        let missedHideExit = sampled.pending!
        sampled.reconcilePointer(regions: [], at: 102.1)
        expect(sampled.pending == missedHideExit, "repeated outside samples do not postpone dismissal")
        expect(!sampled.advance(at: 102.15, generation: missedHideExit.generation), "missed exits still preserve bridge grace")
        expect(sampled.advance(at: 102.17, generation: missedHideExit.generation) && !sampled.isVisible, "sampled leave dismisses after missed preview exit")
        expect(!sampled.needsPointerSampling, "completed dismissal stops pointer timer")
        sampled.reconcilePointer(regions: [.corner], at: 103)
        _ = sampled.escape()
        expect(sampled.suppressedUntilExit && sampled.needsPointerSampling, "Escape suppression polls until a real exit")
        sampled.reconcilePointer(regions: [.corner], at: 103.5)
        expect(sampled.pending == nil && !sampled.isVisible, "stationary pointer cannot reopen after Escape")
        sampled.reconcilePointer(regions: [], at: 104)
        expect(!sampled.suppressedUntilExit && !sampled.needsPointerSampling, "sample repairs missed exit after Escape")
        sampled.reconcilePointer(regions: [.corner], at: 105)
        let beforeExpansion = sampled.pending!
        sampled.setExpanded(true)
        expect(!sampled.needsPointerSampling && !sampled.advance(at: 106, generation: beforeExpansion.generation), "expansion stops polling and invalidates stale intent")
        sampled.pointerChanged(.corner, inside: true, at: 106.1)
        sampled.reconcilePointer(regions: [.corner, .bridge], at: 106.2)
        expect(sampled.regions.isEmpty && sampled.pending == nil && !sampled.isVisible && !sampled.needsPointerSampling, "persistent expanded logo hover remains entirely suppressed")
        sampled.setExpanded(false)
        sampled.reconcilePointer(regions: [.preview, .bridge], at: 107)
        expect(!sampled.isVisible && sampled.pending == nil, "preview and bridge cannot open or activate the panel")

        let cursorBounds = CGRect(x: 0, y: 0, width: 100, height: 40)
        let textBounds = CGRect(x: 20, y: 10, width: 50, height: 20)
        expect(PointingHandGeometry.rectangles(in: cursorBounds, excluding: [], enabled: true) == [cursorBounds], "enabled clickable control has a hand region")
        expect(PointingHandGeometry.rectangles(in: cursorBounds, excluding: [], enabled: false).isEmpty, "disabled control has no hand region")
        expect(PointingHandGeometry.rectangles(in: .zero, excluding: [], enabled: true).isEmpty, "removed or zero-size control has no hand region")
        let cursorRegions = PointingHandGeometry.rectangles(in: cursorBounds, excluding: [textBounds], enabled: true)
        expect(cursorRegions.count == 4, "text input leaves four surrounding clickable regions")
        expect(cursorRegions.allSatisfy { cursorBounds.contains($0) && $0.intersection(textBounds).isEmpty }, "hand cursor never overlaps text input")
        expect(equal(cursorRegions.reduce(0) { $0 + $1.width * $1.height }, 3000), "text exclusion preserves all remaining clickable area")
        expect(PointingHandGeometry.rectangles(in: cursorBounds, excluding: [cursorBounds], enabled: true).isEmpty, "fully covered text or disabled native control has no hand region")
        expect(PointingHandGeometry.rectangles(in: cursorBounds, excluding: [CGRect(x: 200, y: 0, width: 20, height: 20)], enabled: true) == [cursorBounds], "unrelated text fields do not alter cursor region")
        let overlappingExclusions = [textBounds, CGRect(x: 60, y: -10, width: 60, height: 30)]
        let remainingCursorRegions = PointingHandGeometry.rectangles(in: cursorBounds, excluding: overlappingExclusions, enabled: true)
        expect(remainingCursorRegions.allSatisfy { region in overlappingExclusions.allSatisfy { region.intersection($0).isEmpty } }, "overlapping and clipped input exclusions never restore hand regions")
        print("PASS: \(checks) panel geometry and interaction checks")
    }
}
