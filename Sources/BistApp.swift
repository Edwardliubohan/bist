import AppKit
import SwiftUI

final class PanelState: ObservableObject {
    @Published private(set) var corner = CornerInteraction()
    @Published var cornerHighlighted = false
    var expanded: Bool {
        get { corner.isExpanded }
        set { if newValue { corner.activate() } else { corner.collapse() } }
    }
    func setHovered(_ value: Bool) {
        guard corner.isHovered != value else { return }
        cornerHighlighted = value
        if value { corner.pointerEntered() } else { corner.pointerExited() }
        hoverChanged?(value)
    }
    let focusContext = BistFocusContext()
    @Published var focusPolicy = ButtonFocusPolicy() {
        didSet { focusContext.keyboardNavigation = focusPolicy.keyboardNavigation }
    }
    var keyboardNavigation: Bool { focusPolicy.keyboardNavigation }
    @Published var isTransitioning = false
    @Published var reveal: Double = 0
    @Published var openSize = CornerLayout.expandedSize
    @Published var selectedTab = 0
    @Published var focusAddToken = 0
    @Published var detailID: UUID?
    @Published var showSessionForm = false
    @Published var showInbox = false
    @Published var showAgentResults = false
    @Published var showSettings = false
    @Published var notice: String?
    private let preferences: UserDefaults
    @Published var transparency: Double {
        didSet { preferences.set(transparency, forKey: "panelTransparency") }
    }
    @Published var opaque: Bool {
        didSet { preferences.set(opaque, forKey: "opaquePanel") }
    }
    @Published var reduced: Bool {
        didSet { preferences.set(reduced, forKey: "reducedMotion") }
    }
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        transparency = preferences.object(forKey: "panelTransparency")
            .map { _ in min(1, max(0, preferences.double(forKey: "panelTransparency"))) } ?? 0.5
        opaque = ProcessInfo.processInfo.arguments.contains("--opaque") || preferences.bool(forKey: "opaquePanel")
        reduced = ProcessInfo.processInfo.arguments.contains("--reduced-motion") || preferences.bool(forKey: "reducedMotion")
    }
    var resize: ((Bool, Bool) -> Void)?
    var hoverChanged: ((Bool) -> Void)?
    var syncPreviewPreferences: ((Bool) -> Void)?
    var syncSurfaceAppearance: ((Double, Bool) -> Void)?
    func selectTab(_ index: Int) {
        detailID = nil; showSessionForm = false; showInbox = false; showAgentResults = false; showSettings = false
        selectedTab = index
    }
    func openSettings(animated: Bool = true) {
        setExpanded(true, animated: animated)
        showSettings = true
    }
    func toggleSettings() {
        if showSettings { showSettings = false } else { openSettings() }
    }
    func toggle() { setExpanded(!expanded) }
    func setExpanded(_ value: Bool, animated: Bool = true) {
        detailID = nil; showSessionForm = false; showInbox = false; showAgentResults = false; showSettings = false
        if !value { cornerHighlighted = false }
        expanded = value; resize?(value, animated)
    }
    func dismiss(animated: Bool = true) {
        if showSettings { showSettings = false }
        else if detailID != nil { detailID = nil }
        else if showSessionForm { showSessionForm = false }
        else if showInbox { showInbox = false }
        else if showAgentResults { showAgentResults = false }
        else { setExpanded(false, animated: animated) }
    }
}

final class FloatingPanel: NSPanel {
    private var synchronizingTextInput = false
    override var contentView: NSView? {
        didSet {
            // AppKit inserts sheet dimming beside the content view. Clip their
            // common native container so that overlay cannot square off the
            // transparent corners outside the panel's own reveal mask.
            if let container = contentView?.superview {
                container.wantsLayer = true
                container.layer?.cornerRadius = CornerLayout.cornerRadius
                container.layer?.masksToBounds = true
            }
        }
    }
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        // A floating utility must be able to take keyboard focus while app
        // activation is still pending. An activating borderless panel can
        // receive the first text click without ever becoming key on cold launch.
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel), backing: backingStoreType, defer: flag)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        refreshTextInsertionPoint()
        // Activation can complete after the mouse event has assigned its editor.
        // Re-read the current responder; never restore an earlier field or range.
        DispatchQueue.main.async { [weak self] in self?.refreshTextInsertionPoint() }
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseDown { refreshTextInsertionPoint() }
    }

    func refreshTextInsertionPoint() {
        guard !synchronizingTextInput, isKeyWindow, NSApp.keyWindow === self, let editor = firstResponder as? NSTextView,
              editor.window === self, editor.isEditable, editor.shouldDrawInsertionPoint,
              editor.selectedRange().length == 0, !editor.hasMarkedText() else { return }
        // The first field editor can create its input context during mouse
        // tracking, before AppKit's next window update registers that context.
        // Restarting the blink timer alone does not activate the new context.
        synchronizingTextInput = true
        defer { synchronizingTextInput = false }
        NSApp.updateWindows()
        guard isKeyWindow, NSApp.keyWindow === self, firstResponder === editor,
              editor.window === self, editor.isEditable, editor.shouldDrawInsertionPoint,
              editor.selectedRange().length == 0, !editor.hasMarkedText() else { return }
        editor.insertionPointColor = NSColor(accent)
        editor.updateInsertionPointStateAndRestartTimer(true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    let state: PanelState
    init(state: PanelState = PanelState()) { self.state = state; super.init() }
    var store: AppStore!
    var preview: PreviewPanelController!
    var monitor: Any?
    var screenObserver: NSObjectProtocol?
    private(set) var transitionGeneration: UInt64 = 0
    private var transitionTarget: Bool?
    private var transitionPress: CGPoint?
    var surface: PanelTransitionSurface? { panel?.contentView as? PanelTransitionSurface }
    var reduceWindowMotion = false
    var compactOrigin: CGPoint?
    var compactDrag: CompactDrag?
    var draggingExpanded = false
    var positionURL: URL!

    func screen(for point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? panel?.screen ?? NSScreen.main
    }

    func savePosition() {
        guard store != nil, store.prepareForAuxiliaryWrite(), let origin = compactOrigin,
              let data = try? JSONEncoder().encode([Double(origin.x), Double(origin.y)]) else { return }
        try? data.write(to: positionURL, options: .atomic)
    }

    func updateDraggedFrame(_ origin: CGPoint, pointer: CGPoint) {
        guard let screen = screen(for: pointer) else { return }
        let frame = CornerLayout.pixelAligned(CornerLayout.dragFrame(expanded: draggingExpanded, origin: origin, visibleFrame: screen.visibleFrame), scale: screen.backingScaleFactor)
        applyDraggedFrame(frame, visibleFrame: screen.visibleFrame)
    }

    func applyDraggedFrame(_ frame: CGRect, visibleFrame: CGRect) {
        if draggingExpanded { state.openSize = frame.size }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let contentSize = draggingExpanded ? frame.size : state.openSize
        if let surface, surface.presentationRect != bounds || surface.contentSize != contentSize {
            surface.frame = bounds
            surface.settle(rect: bounds, contentSize: contentSize)
        }
        CATransaction.commit()
        compactOrigin = draggingExpanded
            ? CGPoint(x: frame.maxX - CornerLayout.compactSize.width, y: frame.maxY - CornerLayout.compactSize.height)
            : frame.origin
        let anchor = CornerLayout.frame(expanded: false, visibleFrame: visibleFrame, compactOrigin: compactOrigin!)
        preview.reposition(anchor: anchor, visibleFrame: visibleFrame)
    }

    func handleCompactPointer(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else { return false }
        let pointer = eventWindow.convertPoint(toScreen: event.locationInWindow)
        if event.type == .leftMouseDown {
            guard event.window === panel else { return false }
            if state.isTransitioning {
                let visible = surface?.presentationRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) ?? panel.frame
                let corner = CGRect(x: visible.maxX - 48, y: visible.maxY - 48, width: 48, height: 48).insetBy(dx: 2, dy: 2)
                transitionPress = corner.contains(pointer) ? pointer : nil
                // A press never cancels or snaps an in-flight transition.
                return true
            }
            if state.expanded {
                guard state.focusContext.contains(.drag, point: event.locationInWindow, in: panel) else { return false }
            } else {
                guard panel.frame.insetBy(dx: 2, dy: 2).contains(pointer) else { return false }
            }
            draggingExpanded = state.expanded
            compactDrag = CompactDrag(pointer: pointer, origin: panel.frame.origin)
            return true
        }
        if let press = transitionPress {
            if event.type == .leftMouseUp {
                transitionPress = nil
                if hypot(pointer.x - press.x, pointer.y - press.y) < 4 { state.toggle() }
                return true
            }
            if event.type == .leftMouseDragged {
                guard hypot(pointer.x - press.x, pointer.y - press.y) >= 4 else { return true }
                transitionPress = nil
                draggingExpanded = state.expanded
                position(state.expanded)
                compactDrag = CompactDrag(pointer: press, origin: panel.frame.origin)
            }
        }
        guard var drag = compactDrag else { return false }
        if event.type == .leftMouseDragged || event.type == .leftMouseUp {
            if let origin = drag.update(pointer: pointer) {
                preview.cancel()
                updateDraggedFrame(origin, pointer: pointer)
            }
            if event.type == .leftMouseUp {
                compactDrag = nil
                if drag.moved { savePosition() }
                else if !draggingExpanded && panel.frame.contains(pointer) { state.toggle() }
            } else { compactDrag = drag }
            return true
        }
        return false
    }

    func focusForPointer(_ event: NSEvent) {
        guard event.type == .leftMouseDown, event.window === panel, state.expanded, !state.isTransitioning else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        guard !state.focusContext.hasPresentedPicker else { return }
        if state.focusContext.contains(.text, point: event.locationInWindow, in: panel) { return }
        state.focusContext.dismissTextEntry()
        panel.makeFirstResponder(nil)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        panel?.refreshTextInsertionPoint()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        store = AppStore(demo: args.contains("--demo"))
        let directory = store.directory
        positionURL = directory.appendingPathComponent("panel-position.json")
        if let data = try? Data(contentsOf: positionURL),
           let values = try? JSONDecoder().decode([Double].self, from: data),
           values.count == 2, values.allSatisfy({ $0.isFinite }) {
            compactOrigin = CGPoint(x: values[0], y: values[1])
        }
        preview = PreviewPanelController(store: store)
        state.hoverChanged = { [weak self] inside in self?.preview.cornerHoverChanged(inside) }
        state.syncPreviewPreferences = { [weak self] motion in
            guard let self else { return }
            self.preview.reducedMotion = motion
            self.reduceWindowMotion = motion
            if motion && self.state.isTransitioning { self.position(self.state.expanded) }
        }
        panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "bist"
        panel.appearance = NSAppearance(named: .aqua)
        panel.isFloatingPanel = true; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false; panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        let host = GlassHostingView(rootView: BistView(store: store, state: state, directory: directory))
        // AppKit owns the fixed corner geometry; child scroll content must not resize the window.
        host.sizingOptions = []
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = PanelTransitionSurface(host: host)
        state.syncSurfaceAppearance = { [weak self] transparency, opaque in
            self?.surface?.updateAppearance(transparency: transparency, opaque: opaque)
        }
        state.resize = { [weak self] expanded, animated in self?.position(expanded, animated: animated) }
        state.expanded = args.contains("--expanded") || args.contains("--demo")
        position(state.expanded)
        panel.orderFrontRegardless()
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit bist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem(); appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = editMenu; mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: 35)
        statusItem.button?.title = "bist"
        statusItem.button?.font = .systemFont(ofSize: 12, weight: .semibold)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            self.focusForPointer(event)
            if self.handleCompactPointer(event) {
                self.state.focusPolicy.pointerDown()
                return nil
            }
            if event.type != .keyDown {
                if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown { self.state.focusPolicy.pointerDown() }
                return event
            }
            // Keep hidden/partly revealed fields from receiving typed input or
            // Tab. Command navigation and Escape still settle immediately.
            if self.state.isTransitioning && !event.modifierFlags.contains(.command) && event.keyCode != 53 { return nil }
            self.state.focusPolicy.keyDown(code: event.keyCode)
            guard self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 {
                // Let a child picker consume Escape before the panel navigation does.
                if self.state.focusContext.hasPresentedPicker { return event }
                if !self.preview.handleEscape() { self.state.dismiss(animated: false) }
                return nil
            }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case ",": self.state.openSettings(animated: false); return nil
                case "n": self.state.selectedTab = 0; self.state.setExpanded(true, animated: false); self.state.focusAddToken += 1; return nil
                case "a": if let editor = self.panel.firstResponder as? NSText { editor.selectAll(nil); return nil }
                case "1": self.state.selectTab(0); self.state.setExpanded(true, animated: false); return nil
                case "2": self.state.selectTab(1); self.state.setExpanded(true, animated: false); return nil
                case "3": self.state.selectTab(2); self.state.setExpanded(true, animated: false); return nil
                case "z":
                    if !(self.panel.firstResponder is NSTextView) { _ = self.store.undo(); return nil }
                case "q": NSApp.terminate(nil); return nil
                default: break
                }
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.position(self.state.expanded)
            }
        }
    }
    func position(_ expanded: Bool, animated: Bool = false) {
        let point = compactOrigin.map { CGPoint(x: $0.x + 24, y: $0.y + 24) }
        guard let screen = point.flatMap({ self.screen(for: $0) }) ?? panel?.screen ?? NSScreen.main else { return }
        let requestedAnchor = compactOrigin.map { CornerLayout.frame(expanded: false, visibleFrame: screen.visibleFrame, compactOrigin: $0) }
            ?? CornerLayout.frame(expanded: false, visibleFrame: screen.visibleFrame)
        let anchor = CornerLayout.pixelAligned(requestedAnchor, scale: screen.backingScaleFactor)
        let open = CornerLayout.frame(expanded: true, visibleFrame: screen.visibleFrame, compactOrigin: anchor.origin)
        let target = expanded ? open : anchor
        // Idempotent opens (Settings / menu / shortcuts) cannot restart a reveal.
        let motionDisabled = reduceWindowMotion || state.reduced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !motionDisabled && state.isTransitioning && transitionTarget == expanded { return }
        let visible = surface?.presentationRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) ?? panel.frame
        transitionGeneration &+= 1
        let generation = transitionGeneration
        transitionTarget = expanded
        compactOrigin = anchor.origin
        state.openSize = open.size
        // Suppress hover previews for BOTH directions until the compositor settles.
        preview.setExpanded(true)
        preview.reposition(anchor: anchor, visibleFrame: screen.visibleFrame)
        state.setHovered(false)
        if expanded {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            state.focusContext.dismissTextEntry()
            panel.makeFirstResponder(nil)
        }
        let shouldAnimate = animated && surface != nil && visible != target && !motionDisabled
        guard shouldAnimate, let surface else {
            finishTransition(expanded, target: target, contentSize: open.size, generation: generation)
            return
        }
        state.isTransitioning = true
        // A single stable native window covers both endpoints. Window-server
        // rounding and SwiftUI relayout no longer happen on every animation frame.
        let stage = open.union(anchor).union(visible)
        let startRect = visible.offsetBy(dx: -stage.minX, dy: -stage.minY)
        let targetRect = target.offsetBy(dx: -stage.minX, dy: -stage.minY)
        let distance = max(abs(visible.width - target.width) / max(1, open.width - anchor.width),
                           abs(visible.height - target.height) / max(1, open.height - anchor.height))
        let duration = PanelMotion.duration * min(1, max(0.35, distance))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(stage, display: false)
        surface.frame = CGRect(origin: .zero, size: stage.size)
        surface.animate(from: startRect, to: targetRect, contentSize: open.size, duration: duration) { [weak self] in
            self?.finishTransition(expanded, target: target, contentSize: open.size, generation: generation)
        }
        let curve = PanelMotion.curve
        withAnimation(.timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: duration)) { state.reveal = expanded ? 1 : 0 }
        // Flush this endpoint update once, before the compositor begins. There
        // are no layout calls on individual animation frames.
        surface.host.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }

    private func finishTransition(_ expanded: Bool, target: CGRect, contentSize: CGSize, generation: UInt64) {
        // Removing a CA animation can invoke its old completion. Only the newest
        // request is allowed to resize the window or re-enable the page.
        guard generation == transitionGeneration else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.reveal = expanded ? 1 : 0
            state.isTransitioning = false
        }
        panel.setFrame(target, display: false)
        surface?.frame = CGRect(origin: .zero, size: target.size)
        surface?.settle(rect: CGRect(origin: .zero, size: target.size), contentSize: contentSize)
        panel.invalidateShadow()
        CATransaction.commit()
        transitionTarget = nil
        preview.setExpanded(expanded)
    }
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Show bist", action: #selector(showPanel), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit bist", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else {
            state.toggle()
            if state.expanded { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        }
    }
    @objc func showPanel() { state.setExpanded(true); panel.makeKeyAndOrderFront(nil) }
    @objc func quit() { NSApp.terminate(nil) }
}

/// Track the inactive floating panel too, without making it key or intercepting clicks.
struct CornerHoverRegion: NSViewRepresentable {
    var onHover: (Bool) -> Void
    func makeNSView(context: Context) -> HoverView { HoverView(onHover: onHover) }
    func updateNSView(_ view: HoverView, context: Context) { view.onHover = onHover }
    static func dismantleNSView(_ view: HoverView, coordinator: ()) { view.stopTracking() }

    final class HoverView: NSView {
        var onHover: (Bool) -> Void
        private var hoverArea: NSTrackingArea?
        private var pointerTimer: Timer?
        private var inside = false
        init(onHover: @escaping (Bool) -> Void) { self.onHover = onHover; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        deinit { pointerTimer?.invalidate() }
        func stopTracking() {
            pointerTimer?.invalidate(); pointerTimer = nil
            if inside { inside = false; onHover(false) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopTracking() }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // SwiftUI can report a visibleRect larger than this 44-point view.
            // Constrain native tracking as well as the timer to our own bounds.
            let rect = bounds.intersection(visibleRect)
            // Keep unchanged areas stable across hover-driven SwiftUI updates.
            guard hoverArea?.rect != rect else { return }
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(area); hoverArea = area
        }
        private func reportPointerPresence() {
            guard let window else { stopTracking(); return }
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let present = bounds.intersection(visibleRect).contains(local)
            if present != inside { inside = present; onHover(present) }
            if present && pointerTimer == nil {
                let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.reportPointerPresence() }
                pointerTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else if !present {
                pointerTimer?.invalidate(); pointerTimer = nil
            }
        }
        override func mouseEntered(with event: NSEvent) { reportPointerPresence() }
        override func mouseExited(with event: NSEvent) { reportPointerPresence() }
        override func mouseMoved(with event: NSEvent) { reportPointerPresence() }
    }
}

struct BistView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var state: PanelState
    let directory: URL
    @StateObject private var checklistViewState = ChecklistViewState()
    @StateObject private var inspectorDrafts = TaskInspectorDrafts()
    @StateObject private var localSessions = LocalSessionConnection()
    @StateObject private var sessionBrowser = SessionBrowserState()
    @StateObject private var note: NoteStore
    @StateObject private var bobot: BobotStore
    @State private var questionJob: BobotJob?
    @State private var shownQuestions = Set<String>()
    init(store: AppStore, state: PanelState, directory: URL) {
        self.store = store
        self.state = state
        self.directory = directory
        _sessionBrowser = StateObject(wrappedValue: SessionBrowserState(directory: directory, prepareForWrite: store.prepareForAuxiliaryWrite))
        _bobot = StateObject(wrappedValue: BobotStore(directory: directory, prepare: store.prepareForAuxiliaryWrite))
        _note = StateObject(wrappedValue: NoteStore(directory: directory, prepareForWrite: store.prepareForAuxiliaryWrite))
    }
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var active: [TaskItem] { store.tasks.filter { !$0.completed } }
    var opaque: Bool { state.opaque || reduceTransparency }
    var motion: Animation? { reduceMotion || state.reduced ? nil : .easeInOut(duration: PanelMotion.duration) }
    var body: some View {
        Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            // An overlay cannot impose the open page's minimum size on the
            // compact host. Its layout stays stable while the window reveals it.
            expanded
                .frame(width: state.openSize.width, height: state.openSize.height)
                .opacity(state.reveal)
                .allowsHitTesting(state.expanded && !state.isTransitioning)
                .disabled(!state.expanded && !state.isTransitioning)
                .accessibilityHidden(!state.expanded || state.isTransitioning)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .overlay(alignment: .topTrailing) { collapsed.padding(2) }
        .foregroundColor(ink).font(.system(size: 13))
        .preferredColorScheme(.light)
        .tint(accent)
        .coordinateSpace(name: "bistPanel")
        .onPreferenceChange(BistInteractionRegionsKey.self) { state.focusContext.interactionRegions = $0 }
        .environment(\.bistReduced, reduceMotion || state.reduced)
        .environmentObject(state.focusContext)
        .environmentObject(bobot)
        .sheet(item: $questionJob, onDismiss: { bobot.requestedQuestionID = nil }) { job in
            BobotQuestionView(jobID: job.id, bobot: bobot) { questionJob = nil; bobot.requestedQuestionID = nil }
                .environmentObject(state.focusContext)
        }
        .onChange(of: bobot.requestedQuestionID) { _, id in
            if let job = bobot.jobs.first(where: { $0.id == id && $0.pendingQuestion != nil }) {
                shownQuestions.insert(job.pendingQuestion!.id)
                questionJob = job
            }
        }
        .task {
            while !Task.isCancelled {
                bobot.refresh()
                if questionJob == nil, let job = bobot.pending.first(where: { !shownQuestions.contains($0.pendingQuestion!.id) }) {
                    shownQuestions.insert(job.pendingQuestion!.id)
                    state.setExpanded(true)
                    questionJob = job
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onAppear { syncPreviewPreferences(); syncSurfaceAppearance() }
        .onChange(of: store.tasks) { _, tasks in
            checklistViewState.creation.reconcileParent(tasks: tasks)
            let retained = Set(tasks.map(\.id))
            if let id = state.detailID, !retained.contains(id) { state.detailID = nil }
            inspectorDrafts.retainTasks(ids: retained, undoableIDs: store.undoTaskIDs)
        }
        .onChange(of: reduceMotion || state.reduced) { syncPreviewPreferences() }
        .onChange(of: state.transparency) { syncSurfaceAppearance() }
        .onChange(of: opaque) { syncSurfaceAppearance() }
    }
    private func syncPreviewPreferences() { state.syncPreviewPreferences?(reduceMotion || state.reduced) }
    private func syncSurfaceAppearance() { state.syncSurfaceAppearance?(state.transparency, opaque) }
    var collapsed: some View {
        BistButton(focusRadius: 13) { state.toggle() } label: {
            BistFace(size: 25, isHovered: state.corner.isHovered, isExpanded: state.expanded, reduceMotion: reduceMotion || state.reduced)
                .overlay(alignment: .topTrailing) {
                    if active.contains(where: { $0.lane == .attention }) {
                        Circle().fill(accent).frame(width: 4, height: 4)
                            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 0.5))
                            .offset(x: 7, y: -5)
                    }
                }
                .frame(width: CornerLayout.compactHitSize.width, height: CornerLayout.compactHitSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(CornerButtonStyle(hovered: state.cornerHighlighted, feedback: 1 - state.reveal))
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(ivory)
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(accent.opacity(0.22), lineWidth: 1))
                .opacity(1 - state.reveal)
        }

        .background(CornerHoverRegion(onHover: state.setHovered)
            .frame(width: CornerLayout.compactHitSize.width, height: CornerLayout.compactHitSize.height))
        .accessibilityLabel(state.expanded ? "Collapse bist" : "Open bist, \(active.count) task\(active.count == 1 ? "" : "s")")
        .accessibilityHint(state.expanded ? "Click to collapse to the corner control." : "Click to open Tasks, Sessions, and Note. Drag to move bist. Hover briefly to preview outstanding tasks.")
        .animation(reduceMotion || state.reduced ? nil : .easeOut(duration: 0.16), value: state.cornerHighlighted)
    }
    var expanded: some View {
        VStack(spacing: 0) {
            header
            ZStack {
            if state.showSettings {
                BistSettingsView(store: store, state: state,
                    close: { state.showSettings = false },
                    reviewUpdates: { state.showSettings = false; state.showInbox = true },
                    reviewResults: { state.showSettings = false; state.showAgentResults = true })
                    .transition(editorTransition).zIndex(2)
            } else if let id = state.detailID, let task = store.tasks.first(where: { $0.id == id }) {
                TaskInspector(taskID: task.id, store: store, close: { state.detailID = nil }, reviewAgentResults: {
                    state.detailID = nil; state.showAgentResults = true
                }, drafts: inspectorDrafts)
                    .id(id).transition(editorTransition).zIndex(1)
            } else if state.showAgentResults {
                AgentResultsView(store: store, directory: directory) { state.showAgentResults = false }.transition(.opacity)
            } else if state.showSessionForm {
                SessionForm(store: store, close: { state.showSessionForm = false }, saved: {
                    sessionBrowser.collection = .saved; sessionBrowser.query = ""; sessionBrowser.provider = nil
                    state.showSessionForm = false
                }).transition(.opacity)
            } else if state.showInbox {
                InboxView(store: store, directory: directory) { state.showInbox = false }.transition(.opacity)
            } else {
                ZStack {
                    if state.selectedTab == 0 {
                        taskContent.transition(reduceMotion || state.reduced ? .opacity : .asymmetric(insertion: .offset(x: -12).combined(with: .opacity), removal: .offset(x: -12).combined(with: .opacity)))
                    } else if state.selectedTab == 1 {
                        sessionContent.transition(reduceMotion || state.reduced ? .opacity : .asymmetric(insertion: .offset(x: 12).combined(with: .opacity), removal: .offset(x: 12).combined(with: .opacity)))
                    } else {
                        NotePane(note: note).transition(editorTransition)
                    }
                }.transition(reduceMotion || state.reduced ? .opacity : .offset(x: -18).combined(with: .opacity))
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(navigationMotion, value: navigationID)
        }
    }
    private var navigationID: String {
        if state.showSettings { return "settings" }
        if let id = state.detailID { return id.uuidString }
        if state.showAgentResults { return "results" }
        if state.showInbox { return "inbox" }
        if state.showSessionForm { return "session-form" }
        return "tab-\(state.selectedTab)"
    }
    private var navigationMotion: Animation? {
        reduceMotion || state.reduced || state.keyboardNavigation ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.20)
    }
    private var editorTransition: AnyTransition {
        reduceMotion || state.reduced ? .opacity : .offset(x: 12).combined(with: .opacity)
    }
    var header: some View {
        HStack(spacing: 8) {
            tabs.fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
                .frame(maxHeight: .infinity)
                .bistInteractionRegion(.drag)
                .accessibilityLabel("Drag bist to move")
            BistButton {
                state.toggleSettings()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13)).frame(width: 30, height: 32)
                    .foregroundColor(state.showSettings ? accent : muted)
                    .background(state.showSettings ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).accessibilityLabel("Settings").help("Settings · ⌘,")
            Color.clear.frame(width: 32)
        }.padding(.leading, 17).padding(.trailing, 9).frame(height: 48)
    }
    var tabs: some View {
        HStack(spacing: 3) {
            tab("Tasks", number: active.count, index: 0)
            tab("Sessions", number: 0, index: 1)
            tab("Note", number: 0, index: 2)
        }
    }
    func tab(_ title: String, number: Int, index: Int) -> some View {
        BistButton { withAnimation(navigationMotion) { state.selectTab(index) } } label: {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 13, weight: state.selectedTab == index ? .semibold : .regular))
                if number > 0 { Text("\(number)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(state.selectedTab == index ? accent.opacity(0.1) : .clear, in: Capsule()) }
            }.foregroundColor(state.selectedTab == index ? ink : muted).padding(.horizontal, 5).frame(height: 34)
                .overlay(alignment: .bottom) { Rectangle().fill(state.selectedTab == index ? ink : .clear).frame(height: 1) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(state.selectedTab == index ? .isSelected : []).help("\(title) · ⌘\(index + 1)")
    }
    var taskContent: some View {
        ChecklistPane(store: store, openTask: { state.detailID = $0 }, focusRequest: state.focusAddToken, reducedMotion: reduceMotion || state.reduced, viewState: checklistViewState)
    }
    @ViewBuilder var bottomStatus: some View {
        if let error = store.storeError { Text(error).font(.system(size: 10)).foregroundColor(.red).lineLimit(3) }
        else if store.canUndo {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(accent).font(.system(size: 11))
                Text(store.lastActionLabel ?? "Task updated").font(.system(size: 11)).lineLimit(1)
                Spacer()
                BistButton("Undo") { withAnimation(motion) { _ = store.undo() } }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(accent).keyboardShortcut("z").accessibilityLabel("Undo last task action")
            }.padding(.horizontal, 10).frame(height: 32).background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    var sessionContent: some View {
        SessionsPane(store: store, connection: localSessions, browser: sessionBrowser, active: state.expanded,
                     addLink: { state.showSessionForm = true })
    }
}

func providerName(_ p: SessionProvider) -> String {
    switch p { case .claudeCode: return "Claude Code"; case .codex: return "ChatGPT / Codex"; case .muse: return "Meta Muse" }
}
func safeURL(_ string: String) -> URL? {
    guard let u = URL(string: string), ["https", "http"].contains(u.scheme?.lowercased() ?? ""), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return nil }; return u
}

struct SessionForm: View {
    @ObservedObject var store: AppStore
    let close: () -> Void
    let saved: () -> Void
    @State private var provider: SessionProvider = .codex
    @State private var title = ""
    @State private var url = ""
    @State private var error = false
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            BistButton(action: close) { Label("Sessions", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)) }.buttonStyle(.plain).foregroundColor(accent)
            Text("Add a session link").font(.system(size: 17, weight: .semibold))
            Text("Save an existing session URL. Local Codex and Claude sessions appear automatically under Recent.").font(.system(size: 12)).foregroundColor(muted).lineSpacing(3)
            Picker("Provider", selection: $provider) { ForEach(SessionProvider.allCases, id: \.self) { Text(providerName($0)).tag($0) } }.pickerStyle(.menu).bistPointingHand()
            linkField("Session title", text: $title, hint: "A name you’ll recognize")
            linkField("Session URL", text: $url, hint: "https://…")
            if let saveError = store.storeError { Text(saveError).font(.system(size: 11)).foregroundColor(.red) }
            if error { Text("Enter a title and a full http or https link without credentials.").font(.system(size: 11)).foregroundColor(.red) }
            Spacer()
            BistButton { error = false; guard safeURL(url) != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = true; return }; if store.addSession(provider: provider, title: title, url: url) { saved() } } label: { Text("Save link").frame(maxWidth: .infinity).font(.system(size: 12, weight: .semibold)) }.buttonStyle(TactileStyle(prominent: true))
        }.padding(.horizontal, 23).padding(.bottom, 23)
    }
    private func linkField(_ label: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium))
            ZStack(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(hint).font(.system(size: 12)).foregroundColor(muted).allowsHitTesting(false).accessibilityHidden(true)
                }
                TextField("", text: text).textFieldStyle(.plain).font(.system(size: 12)).bistTextEntry().accessibilityLabel(label)
            }.padding(10).background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct InboxView: View {
    @ObservedObject var store: AppStore
    let directory: URL
    let close: () -> Void
    @State private var proposals: [TaskProposal] = []
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BistButton(action: close) { Label("Back", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)) }.buttonStyle(.plain).foregroundColor(accent)
            Text("Review local updates").font(.system(size: 20, weight: .medium))
            Text("Proposed tasks wait for your review. No background sync is running.").font(.system(size: 12)).foregroundColor(muted).lineSpacing(3)
            if !loaded { ProgressView().controlSize(.small) }
            if let error = error { Text(error).font(.system(size: 11)).foregroundColor(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if loaded && proposals.isEmpty && error == nil { Text("No proposed tasks yet.").foregroundColor(muted).padding(.top, 20) }
                    ForEach(proposals) { p in
                        VStack(alignment: .leading, spacing: 5) { Text(p.title).fontWeight(.medium); Text(p.nextAction).font(.system(size: 11)).foregroundColor(muted); Text("Source: \(p.source)").font(.system(size: 10)).foregroundColor(muted) }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if !proposals.isEmpty {
                BistButton {
                    guard store.importProposals(proposals) else { error = store.storeError; return }
                    let imported = Set(proposals.map(\.id))
                    do { try LocalInbox(directory: directory).consume(ids: imported); proposals = try LocalInbox(directory: directory).load(); if proposals.isEmpty { close() } }
                    catch { self.error = error.localizedDescription }
                } label: { Text("Add \(proposals.count) task\(proposals.count == 1 ? "" : "s")").frame(maxWidth: .infinity) }.buttonStyle(TactileStyle(prominent: true))
            }
        }.padding(.horizontal, 23).padding(.bottom, 23)
        .onAppear { do { proposals = try LocalInbox(directory: directory).load() } catch { self.error = error.localizedDescription }; loaded = true }
    }
}

#if !BIST_TESTING
@main
struct BistMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
#endif
