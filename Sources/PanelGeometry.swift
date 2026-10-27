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

    static func previewRegions(pointer: CGPoint, anchor: CGRect, preview: CGRect?) -> Set<HoverPreviewInteraction.Region> {
        var regions = Set<HoverPreviewInteraction.Region>()
        if anchor.insetBy(dx: compactHitInset, dy: compactHitInset).contains(pointer) { regions.insert(.corner) }
        if let preview, preview.contains(pointer) {
            let above = preview.minY >= anchor.maxY
            let bridge = above ? pointer.y < preview.minY + previewGap : pointer.y >= preview.maxY - previewGap
            regions.insert(bridge ? .bridge : .preview)
        }
        return regions
    }

    /// The window includes a transparent 8 pt bridge above its visible surface.
    /// This keeps tracking continuous between the stationary corner and preview.
    static func previewFrame(anchor: CGRect, contentHeight: CGFloat, visibleFrame: CGRect) -> CGRect {
        let bounds = visibleFrame.standardized
        let width = min(previewWidth, max(0, bounds.width - 2 * min(edgeInset, bounds.width / 2)))
        let height = min(max(0, contentHeight), previewMaximumHeight) + previewGap
        let below = max(0, anchor.minY - bounds.minY)
        let above = max(0, bounds.maxY - anchor.maxY)
        let useAbove = below < height && above > below
        let fittedHeight = min(height, useAbove ? above : below)
        let x = min(max(anchor.maxX - width, bounds.minX), bounds.maxX - width)
        return CGRect(x: x, y: useAbove ? anchor.maxY : anchor.minY - fittedHeight, width: width, height: fittedHeight)
    }

    /// Keep the user's compact origin independent from temporary expansion clamping.
    static func frame(expanded: Bool, visibleFrame: CGRect, compactOrigin: CGPoint) -> CGRect {
        let size = frame(expanded: expanded, visibleFrame: visibleFrame).size
        let compact = frame(expanded: false, visibleFrame: visibleFrame).size
        let origin = CGPoint(x: compactOrigin.x + compact.width - size.width,
                             y: compactOrigin.y + compact.height - size.height)
        return clamped(CGRect(origin: origin, size: size), to: visibleFrame)
    }

    static func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let bounds = bounds.standardized
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height),
                      width: frame.width, height: frame.height)
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
    var needsPointerSampling: Bool { !isExpanded && (isVisible || pending != nil || !regions.isEmpty) }

    mutating func pointerChanged(_ region: Region, inside: Bool, at now: TimeInterval) {
        var next = regions
        if inside { next.insert(region) } else { next.remove(region) }
        reconcilePointer(regions: next, at: now)
    }

    mutating func reconcilePointer(regions next: Set<Region>, at now: TimeInterval) {
        guard !isExpanded else { return }
        guard next != regions else { return }
        regions = next
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

struct PointingHandGeometry {
    static func rectangles(in bounds: CGRect, excluding exclusions: [CGRect], enabled: Bool) -> [CGRect] {
        guard enabled && !bounds.isEmpty && !bounds.isNull else { return [] }
        return exclusions.reduce([bounds]) { rectangles, exclusion in
            rectangles.flatMap { rectangle -> [CGRect] in
                let overlap = rectangle.intersection(exclusion)
                guard !overlap.isNull && !overlap.isEmpty else { return [rectangle] }
                return [
                    CGRect(x: rectangle.minX, y: rectangle.minY, width: rectangle.width, height: overlap.minY - rectangle.minY),
                    CGRect(x: rectangle.minX, y: overlap.maxY, width: rectangle.width, height: rectangle.maxY - overlap.maxY),
                    CGRect(x: rectangle.minX, y: overlap.minY, width: overlap.minX - rectangle.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: rectangle.maxX - overlap.maxX, height: overlap.height)
                ].filter { !$0.isEmpty }
            }
        }
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

/// A small slop keeps ordinary clicks from becoming accidental drags.
struct CompactDrag {
    let pointer: CGPoint
    let origin: CGPoint
    private(set) var moved = false
    mutating func update(pointer next: CGPoint) -> CGPoint? {
        let dx = next.x - pointer.x, dy = next.y - pointer.y
        moved = moved || hypot(dx, dy) >= 4
        return moved ? CGPoint(x: origin.x + dx, y: origin.y + dy) : nil
    }
}

/// SwiftUI reports top-left content coordinates; native mouse events use bottom-left.
struct BistInteractionRegion: Equatable {
    enum Kind { case text, drag }
    let kind: Kind
    let rect: CGRect
    static func contains(_ kind: Kind, point: CGPoint, contentHeight: CGFloat, regions: [Self]) -> Bool {
        let topLeft = CGPoint(x: point.x, y: contentHeight - point.y)
        return regions.contains { $0.kind == kind && $0.rect.contains(topLeft) }
    }
}
