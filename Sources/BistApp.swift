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
    @Published var transparency = UserDefaults.standard.object(forKey: "panelTransparency")
        .map { _ in min(1, max(0, UserDefaults.standard.double(forKey: "panelTransparency"))) } ?? 0.5 {
        didSet { UserDefaults.standard.set(transparency, forKey: "panelTransparency") }
    }
    @Published var opaque = ProcessInfo.processInfo.arguments.contains("--opaque") || UserDefaults.standard.bool(forKey: "opaquePanel") {
        didSet { UserDefaults.standard.set(opaque, forKey: "opaquePanel") }
    }
    @Published var reduced = ProcessInfo.processInfo.arguments.contains("--reduced-motion") || UserDefaults.standard.bool(forKey: "reducedMotion") {
        didSet { UserDefaults.standard.set(reduced, forKey: "reducedMotion") }
    }
    var resize: ((Bool) -> Void)?
    var hoverChanged: ((Bool) -> Void)?
    var syncPreviewPreferences: ((Bool, Bool) -> Void)?
    func selectTab(_ index: Int) {
        detailID = nil; showSessionForm = false; showInbox = false; showAgentResults = false; showSettings = false
        selectedTab = index
    }
    func openSettings() {
        setExpanded(true)
        showSettings = true
    }
    func toggleSettings() {
        if showSettings { showSettings = false } else { openSettings() }
    }
    func toggle() { setExpanded(!expanded) }
    func setExpanded(_ value: Bool) {
        detailID = nil; showSessionForm = false; showInbox = false; showAgentResults = false; showSettings = false
        if !value { cornerHighlighted = false }
        expanded = value; resize?(value)
    }
    func dismiss() {
        if showSettings { showSettings = false }
        else if detailID != nil { detailID = nil }
        else if showSessionForm { showSessionForm = false }
        else if showInbox { showInbox = false }
        else if showAgentResults { showAgentResults = false }
        else { setExpanded(false) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    let state = PanelState()
    var store: AppStore!
    var preview: PreviewPanelController!
    var monitor: Any?
    var screenObserver: NSObjectProtocol?
    var resizeTimer: Timer?
    var reduceWindowMotion = false
    var compactOrigin: CGPoint?
    var compactDrag: CompactDrag?
    var draggingExpanded = false
    var positionURL: URL!

    func screen(for point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? panel?.screen ?? NSScreen.main
    }

    func savePosition() {
        guard let origin = compactOrigin,
              let data = try? JSONEncoder().encode([Double(origin.x), Double(origin.y)]) else { return }
        try? FileManager.default.createDirectory(at: positionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: positionURL, options: .atomic)
    }

    func updateDraggedFrame(_ origin: CGPoint, pointer: CGPoint) {
        guard let screen = screen(for: pointer) else { return }
        let frame = CornerLayout.dragFrame(expanded: draggingExpanded, origin: origin, visibleFrame: screen.visibleFrame)
        if draggingExpanded { state.openSize = frame.size }
        panel.setFrame(frame, display: true)
        compactOrigin = draggingExpanded
            ? CGPoint(x: frame.maxX - CornerLayout.compactSize.width, y: frame.maxY - CornerLayout.compactSize.height)
            : frame.origin
        let anchor = CornerLayout.frame(expanded: false, visibleFrame: screen.visibleFrame, compactOrigin: compactOrigin!)
        preview.reposition(anchor: anchor, visibleFrame: screen.visibleFrame)
    }

    func handleCompactPointer(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else { return false }
        let pointer = eventWindow.convertPoint(toScreen: event.locationInWindow)
        if event.type == .leftMouseDown {
            guard event.window === panel else { return false }
            if state.expanded {
                // Header dragging starts only after the reveal settles. Cancelling
                // its timer here would strand a partly sized, noninteractive panel.
                guard resizeTimer == nil else { return false }
                guard state.focusContext.contains(.drag, point: event.locationInWindow, in: panel) else { return false }
            } else {
                // Do not freeze an intermediate-size window when a closing logo is grabbed.
                if resizeTimer != nil { position(false) }
                guard panel.frame.insetBy(dx: 2, dy: 2).contains(pointer) else { return false }
            }
            resizeTimer?.invalidate(); resizeTimer = nil
            draggingExpanded = state.expanded
            compactDrag = CompactDrag(pointer: pointer, origin: panel.frame.origin)
            return true
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
        guard event.type == .leftMouseDown, event.window === panel, state.expanded else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        guard !state.focusContext.hasPresentedPicker else { return }
        if state.focusContext.contains(.text, point: event.locationInWindow, in: panel) { return }
        state.focusContext.dismissTextEntry()
        panel.makeFirstResponder(nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let base = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = ProcessInfo.processInfo.environment["BIST_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent(args.contains("--demo") ? ".demo-data" : ".local-data")
        positionURL = directory.appendingPathComponent("panel-position.json")
        if let data = try? Data(contentsOf: positionURL),
           let values = try? JSONDecoder().decode([Double].self, from: data),
           values.count == 2, values.allSatisfy({ $0.isFinite }) {
            compactOrigin = CGPoint(x: values[0], y: values[1])
        }
        store = AppStore(directory: directory, demo: args.contains("--demo"))
        preview = PreviewPanelController(store: store)
        state.hoverChanged = { [weak self] inside in self?.preview.cornerHoverChanged(inside) }
        state.syncPreviewPreferences = { [weak self] motion, transparency in
            self?.preview.reducedMotion = motion
            self?.reduceWindowMotion = motion
            self?.preview.reduceTransparency = transparency
        }
        panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "bist"
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
        panel.contentView = host
        state.resize = { [weak self] expanded in self?.position(expanded, animated: true) }
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
            self.state.focusPolicy.keyDown(code: event.keyCode)
            guard self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 {
                // Let a child picker consume Escape before the panel navigation does.
                if self.state.focusContext.hasPresentedPicker { return event }
                if !self.preview.handleEscape() { self.state.dismiss() }
                return nil
            }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case ",": self.state.openSettings(); return nil
                case "n": self.state.selectedTab = 0; self.state.setExpanded(true); self.state.focusAddToken += 1; return nil
                case "a": if let editor = self.panel.firstResponder as? NSText { editor.selectAll(nil); return nil }
                case "1": self.state.selectTab(0); self.state.setExpanded(true); return nil
                case "2": self.state.selectTab(1); self.state.setExpanded(true); return nil
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
        resizeTimer?.invalidate()
        resizeTimer = nil
        preview.setExpanded(expanded)
        let anchor = compactOrigin.map { CornerLayout.frame(expanded: false, visibleFrame: screen.visibleFrame, compactOrigin: $0) }
            ?? CornerLayout.frame(expanded: false, visibleFrame: screen.visibleFrame)
        compactOrigin = anchor.origin
        preview.reposition(anchor: anchor, visibleFrame: screen.visibleFrame)
        let open = CornerLayout.frame(expanded: true, visibleFrame: screen.visibleFrame, compactOrigin: anchor.origin)
        state.openSize = open.size
        let target = expanded ? open : anchor
        if expanded {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            state.focusContext.dismissTextEntry()
            panel.makeFirstResponder(nil)
        }
        guard animated && !reduceWindowMotion && !state.reduced && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            state.reveal = expanded ? 1 : 0
            panel.setFrame(target, display: true)
            return
        }
        let start = panel.frame
        let startReveal = state.reveal
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / PanelMotion.duration)
                self.state.reveal = startReveal + ((expanded ? 1 : 0) - startReveal) * PanelMotion.fraction(progress)
                self.panel.setFrame(PanelMotion.frame(from: start, to: target, progress: progress), display: true)
                if progress == 1 { timer.invalidate(); self.resizeTimer = nil }
            }
        }
        resizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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

struct GlassMaterial: NSViewRepresentable {
    let opaque: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.blendingMode = .behindWindow; view.material = .popover; view.alphaValue = 1; view.state = .active; view.appearance = NSAppearance(named: .aqua); return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.isHidden = opaque }
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
            // inVisibleRect follows layout automatically. Keep the same area so
            // hover-driven SwiftUI updates cannot reset enter/exit tracking.
            guard hoverArea == nil else { return }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(area); hoverArea = area
        }
        private func reportPointerPresence() {
            guard let window else { stopTracking(); return }
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let present = visibleRect.contains(local)
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
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var active: [TaskItem] { store.tasks.filter { !$0.completed } }
    var opaque: Bool { state.opaque || reduceTransparency }
    var motion: Animation? { reduceMotion || state.reduced ? nil : .easeInOut(duration: PanelMotion.duration) }
    var body: some View {
        ZStack {
            GlassMaterial(opaque: opaque)
            ivory.opacity(opaque ? 1 : 0.92 - 0.38 * state.transparency)
            LinearGradient(colors: [.white.opacity(0.20), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            // An overlay cannot impose the open page's minimum size on the
            // compact host. Its layout stays stable while the window reveals it.
            expanded
                .frame(width: state.openSize.width, height: state.openSize.height)
                .opacity(state.reveal)
                .allowsHitTesting(state.expanded && state.reveal > 0.98)
                .disabled(!state.expanded || state.reveal <= 0.98)
                .accessibilityHidden(!state.expanded)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .overlay(alignment: .topTrailing) { collapsed.padding(2) }
        .clipShape(RoundedRectangle(cornerRadius: 16 + 9 * state.reveal, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16 + 9 * state.reveal, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3), .white.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 16 + 9 * state.reveal, style: .continuous).inset(by: 1.5).strokeBorder(ink.opacity(0.035), lineWidth: 0.5))
        .overlay {
            if state.reveal < 1 {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .inset(by: 1)
                    .strokeBorder(cornerOrange.opacity(state.cornerHighlighted ? 0.32 * (1 - state.reveal) : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion || state.reduced ? nil : .easeOut(duration: 0.16), value: state.cornerHighlighted)
        .foregroundColor(ink).font(.system(size: 13))
        .preferredColorScheme(.light)
        .tint(accent)
        .coordinateSpace(name: "bistPanel")
        .onPreferenceChange(BistInteractionRegionsKey.self) { state.focusContext.interactionRegions = $0 }
        .environment(\.bistReduced, reduceMotion || state.reduced)
        .environmentObject(state.focusContext)
        .onAppear { syncPreviewPreferences() }
        .onChange(of: store.tasks) { _, tasks in
            checklistViewState.creation.reconcileParent(tasks: tasks)
            let retained = Set(tasks.map(\.id))
            if let id = state.detailID, !retained.contains(id) { state.detailID = nil }
            inspectorDrafts.retainTasks(ids: retained, undoableIDs: store.undoTaskIDs)
        }
        .onChange(of: opaque) { syncPreviewPreferences() }
        .onChange(of: reduceMotion || state.reduced) { syncPreviewPreferences() }
    }
    private func syncPreviewPreferences() { state.syncPreviewPreferences?(reduceMotion || state.reduced, opaque) }
    var collapsed: some View {
        BistButton(focusRadius: 13) { state.toggle() } label: {
            BistFace(size: 25, isHovered: state.corner.isHovered, isExpanded: state.expanded, reduceMotion: reduceMotion || state.reduced)
                .shadow(color: cornerOrange.opacity(state.cornerHighlighted ? 0.24 * (1 - state.reveal) : 0), radius: 4, y: 1)
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
        .accessibilityHint(state.expanded ? "Click to collapse to the corner control." : "Click to open Tasks and Sessions. Drag to move bist. Hover briefly to preview outstanding tasks.")
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
                SessionForm(store: store) { state.showSessionForm = false }.transition(.opacity)
            } else if state.showInbox {
                InboxView(store: store, directory: directory) { state.showInbox = false }.transition(.opacity)
            } else {
                ZStack {
                    if state.selectedTab == 0 {
                        taskContent.transition(reduceMotion || state.reduced ? .opacity : .asymmetric(insertion: .offset(x: -12).combined(with: .opacity), removal: .offset(x: -12).combined(with: .opacity)))
                    } else {
                        sessionContent.transition(reduceMotion || state.reduced ? .opacity : .asymmetric(insertion: .offset(x: 12).combined(with: .opacity), removal: .offset(x: 12).combined(with: .opacity)))
                    }
                }.transition(reduceMotion || state.reduced ? .opacity : .offset(x: -18).combined(with: .opacity))
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ivory.opacity(opaque ? 1 : 0.62))
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
            tab("Sessions", number: store.sessions.count, index: 1)
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
        }.buttonStyle(.plain).accessibilityAddTraits(state.selectedTab == index ? .isSelected : []).help(index == 0 ? "Tasks · ⌘1" : "Sessions · ⌘2")
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
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Your agent spaces").font(.system(size: 11, weight: .medium)).foregroundColor(muted); Spacer(); Text("Local links").font(.system(size: 9, weight: .medium)).foregroundColor(accent).padding(.horizontal, 7).padding(.vertical, 4).background(accent.opacity(0.08), in: Capsule()) }.padding(.horizontal, 23).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(SessionProvider.allCases, id: \.self) { provider in
                        providerCard(provider)
                    }
                    ForEach(store.sessions) { session in sessionRow(session) }
                }.padding(.horizontal, 17)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { Image(systemName: "lock.shield"); Text("Only what you choose to link").fontWeight(.medium) }.font(.system(size: 11))
                Text("Links open in your browser. Live status and agent controls are not connected.").font(.system(size: 11)).lineSpacing(3).foregroundColor(muted)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.36), in: RoundedRectangle(cornerRadius: 13)).padding(.horizontal, 17).padding(.bottom, 12)
            bottomStatus.padding(.horizontal, 19).padding(.bottom, 8)
            BistButton { state.showSessionForm = true } label: { Label("Add a session link", systemImage: "plus").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity) }.buttonStyle(TactileStyle()).padding(.horizontal, 17).padding(.bottom, 18)
        }
    }
    func providerCard(_ provider: SessionProvider) -> some View {
        HStack(spacing: 10) {
            providerGlyph(provider)
            VStack(alignment: .leading, spacing: 4) {
                Text(providerName(provider)).font(.system(size: 12, weight: .semibold))
                Text("Not connected").font(.system(size: 10)).foregroundColor(muted)
                Text("Last observed: never").font(.system(size: 9)).foregroundColor(muted)
            }
            Spacer(minLength: 2)
            Circle().strokeBorder(muted.opacity(0.5), lineWidth: 1).frame(width: 7, height: 7).accessibilityLabel("Disconnected")
        }.padding(12).background(.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.65), lineWidth: 0.7))
    }
    func sessionRow(_ session: SessionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(providerName(session.provider)) · Status unknown").font(.system(size: 9)).foregroundColor(muted)
                }
                Spacer()
                if let string = session.url, let url = safeURL(string) { BistButton { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)) }.buttonStyle(TactileStyle(compact: true)).accessibilityLabel("Open \(session.title)") }
                Menu { Button("Remove local link") { _ = store.removeSession(id: session.id) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().bistPointingHand().accessibilityLabel("Options for \(session.title)")
            }
            Text("Last observed: never").font(.system(size: 9)).foregroundColor(muted)
        }.padding(12).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
    }
}

func providerName(_ p: SessionProvider) -> String {
    switch p { case .claudeCode: return "Claude Code"; case .codex: return "ChatGPT / Codex"; case .muse: return "Meta Muse" }
}
func providerGlyph(_ p: SessionProvider) -> some View {
    let glyph: String = p == .claudeCode ? "asterisk" : p == .codex ? "command" : "infinity"
    let color: Color = p == .claudeCode ? Color(red: 0.64, green: 0.42, blue: 0.31) : p == .codex ? Color(red: 0.32, green: 0.48, blue: 0.43) : accent
    return Image(systemName: glyph).font(.system(size: 19, weight: .medium)).foregroundColor(color).frame(width: 38, height: 38).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.7), lineWidth: 0.7))
}
func safeURL(_ string: String) -> URL? {
    guard let u = URL(string: string), ["https", "http"].contains(u.scheme?.lowercased() ?? ""), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return nil }; return u
}

struct SessionForm: View {
    @ObservedObject var store: AppStore
    let close: () -> Void
    @State private var provider: SessionProvider = .codex
    @State private var title = ""
    @State private var url = ""
    @State private var error = false
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            BistButton(action: close) { Label("Sessions", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)) }.buttonStyle(.plain).foregroundColor(accent)
            Text("Keep a session close.").font(.system(size: 21, weight: .medium))
            Text("Save a link you already have. Adding a link does not connect an account or reveal its status.").font(.system(size: 12)).foregroundColor(muted).lineSpacing(3)
            Picker("Product", selection: $provider) { ForEach(SessionProvider.allCases, id: \.self) { Text(providerName($0)).tag($0) } }.pickerStyle(.menu).bistPointingHand()
            TextField("Session title", text: $title).textFieldStyle(.plain).bistTextEntry().padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Session title")
            TextField("https://…", text: $url).textFieldStyle(.plain).bistTextEntry().padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Session URL")
            if let saveError = store.storeError { Text(saveError).font(.system(size: 11)).foregroundColor(.red) }
            if error { Text("Enter a title and a full http or https link without credentials.").font(.system(size: 11)).foregroundColor(.red) }
            Spacer()
            BistButton { error = false; guard safeURL(url) != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = true; return }; if store.addSession(provider: provider, title: title, url: url) { close() } } label: { Text("Save local link").frame(maxWidth: .infinity).font(.system(size: 12, weight: .semibold)) }.buttonStyle(TactileStyle(prominent: true))
        }.padding(.horizontal, 23).padding(.bottom, 23)
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
