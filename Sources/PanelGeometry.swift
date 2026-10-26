import Foundation
import CoreGraphics

/// A stable partition for the small preview: no timestamps, priorities, or titles
/// can change the user's order within either horizon.
struct PreviewTaskSelection<Element> {
    let shortTerm: [Element]
    let longerTerm: [Element]
    let outstandingCount: Int
    var visibleCount: Int { shortTerm.count + longerTerm.count }
    var visibleGroupCount: Int { (shortTerm.isEmpty ? 0 : 1) + (longerTerm.isEmpty ? 0 : 1) }

    init(_ items: [Element], limit: Int = 3, isOutstanding: (Element) -> Bool, isShortTerm: (Element) -> Bool) {
        let active = items.filter(isOutstanding)
        let short = active.filter(isShortTerm)
        let long = active.filter { !isShortTerm($0) }
        let maximum = max(0, limit)
        shortTerm = Array(short.prefix(maximum))
        longerTerm = Array(long.prefix(max(0, maximum - shortTerm.count)))
        outstandingCount = active.count
    }
}

/// Screen-space geometry for the stationary corner control and expanded panel.
/// Coordinates use AppKit's bottom-left origin and the screen's visible frame.
struct CornerLayout {
    static let compactSize = CGSize(width: 48, height: 48)
    static let expandedSize = CGSize(width: 360, height: 560)
    static let edgeInset: CGFloat = 16
    static let compactHitInset: CGFloat = 2
    static let compactHitSize = CGSize(width: 44, height: 44)
    static let previewWidth: CGFloat = 260
    static let previewGap: CGFloat = 8
    static let previewMaximumHeight: CGFloat = 240

    /// The window includes a transparent 8 pt bridge above its visible surface.
    /// This keeps tracking continuous between the stationary corner and preview.
    static func previewFrame(anchor: CGRect, contentHeight: CGFloat, visibleFrame: CGRect) -> CGRect {
        let bounds = visibleFrame.standardized
        let width = min(previewWidth, max(0, bounds.width - 2 * min(edgeInset, bounds.width / 2)))
        let height = min(max(0, contentHeight), previewMaximumHeight) + previewGap
        let availableHeight = max(0, anchor.minY - bounds.minY - min(edgeInset, bounds.height / 2))
        let fittedHeight = min(height, availableHeight)
        let x = min(max(anchor.maxX - width, bounds.minX), bounds.maxX - width)
        return CGRect(x: x, y: anchor.minY - fittedHeight, width: width, height: fittedHeight)
    }

    static func frame(expanded: Bool, visibleFrame: CGRect) -> CGRect {
        let bounds = visibleFrame.standardized
        let requested = expanded ? expandedSize : compactSize
        // Preserve the 16 pt safe-area gap on every usable screen. On a smaller
        // visible area, reduce the panel rather than placing controls off-screen.
        let horizontalInset = min(edgeInset, bounds.width / 2)
        let verticalInset = min(edgeInset, bounds.height / 2)
        let size = CGSize(
            width: min(requested.width, max(0, bounds.width - horizontalInset * 2)),
            height: min(requested.height, max(0, bounds.height - verticalInset * 2))
        )
        return CGRect(
            x: bounds.maxX - horizontalInset - size.width,
            y: bounds.maxY - verticalInset - size.height,
            width: size.width,
            height: size.height
        )
    }
}

/// A clock-driven intent model. Timer generations make cancelled callbacks inert.
/// Hover only opens the passive preview; it never expands or activates the app.
struct HoverPreviewInteraction {
    enum Region: Hashable { case corner, preview, bridge }
    enum Intent: Equatable { case show, hide }
    struct Pending: Equatable {
        let intent: Intent
        let deadline: TimeInterval
        let generation: UInt64
    }
    static let enterDelay: TimeInterval = 0.25
    static let leaveGrace: TimeInterval = 0.16
    private(set) var isVisible = false
    private(set) var pending: Pending?
    private(set) var generation: UInt64 = 0
    private(set) var isExpanded = false
    private(set) var regions: Set<Region> = []
    private(set) var suppressedUntilExit = false

    mutating func pointerChanged(_ region: Region, inside: Bool, at now: TimeInterval) {
        let changed = inside ? regions.insert(region).inserted : regions.remove(region) != nil
        guard changed else { return }
        if regions.isEmpty { suppressedUntilExit = false }
        guard !isExpanded && !suppressedUntilExit else { return }
        if isVisible {
            if regions.isEmpty { schedule(.hide, at: now + Self.leaveGrace) }
            else { invalidate() }
        } else if regions.contains(.corner) {
            if pending?.intent != .show { schedule(.show, at: now + Self.enterDelay) }
        } else {
            invalidate()
        }
    }

    /// The caller supplies the captured timer token, not a current mutable token.
    @discardableResult
    mutating func advance(at now: TimeInterval, generation token: UInt64) -> Bool {
        guard let action = pending, action.generation == token, now >= action.deadline else { return false }
        invalidate()
        switch action.intent {
        case .show:
            guard !isExpanded && !suppressedUntilExit && regions.contains(.corner) else { return false }
            isVisible = true
        case .hide:
            guard regions.isEmpty else { return false }
            isVisible = false
        }
        return true
    }

    mutating func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        cancel()
        regions.removeAll()
        suppressedUntilExit = false
    }

    mutating func cancel() {
        invalidate()
        isVisible = false
        // Hiding a native window need not emit mouseExited for its tracking area.
        regions = regions.intersection([.corner])
        suppressedUntilExit = !regions.isEmpty
    }

    @discardableResult
    mutating func escape() -> Bool {
        let handled = isVisible || pending != nil
        if handled { cancel() }
        return handled
    }

    private mutating func schedule(_ intent: Intent, at deadline: TimeInterval) {
        generation &+= 1
        pending = Pending(intent: intent, deadline: deadline, generation: generation)
    }
    private mutating func invalidate() {
        generation &+= 1
        pending = nil
    }
}

/// Hover is visual feedback only. Opening always requires explicit activation.
struct CornerInteraction {
    private(set) var isHovered = false
    private(set) var isExpanded = false

    mutating func pointerEntered() { isHovered = true }
    mutating func pointerExited() { isHovered = false }

    mutating func activate() {
        isExpanded = true
        isHovered = false
    }

    mutating func collapse() {
        isExpanded = false
        isHovered = false
    }
}

/// Keep a visible keyboard focus indicator without leaving a ring after clicks.
/// Input modality changes independently of which control currently owns focus.
struct ButtonFocusPolicy {
    private(set) var keyboardNavigation = false

    mutating func keyDown(code: UInt16) {
        switch code {
        case 48, 49, 36, 76, 123...126: // Tab, Space, Return, keypad Enter, arrows
            keyboardNavigation = true
        default:
            break
        }
    }

    mutating func pointerDown() { keyboardNavigation = false }

    static func showsRing(focused: Bool, keyboardNavigation: Bool) -> Bool {
        focused && keyboardNavigation
    }
}
