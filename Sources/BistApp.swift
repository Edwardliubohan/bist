import AppKit
import SwiftUI

private struct BistReducedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var bistReduced: Bool { get { self[BistReducedKey.self] } set { self[BistReducedKey.self] = newValue } } }

private let ink = Color(red: 0.18, green: 0.17, blue: 0.23)
private let muted = Color(red: 0.43, green: 0.41, blue: 0.49)
private let violet = Color(red: 0.47, green: 0.37, blue: 0.73)
private let ivory = Color(red: 0.97, green: 0.96, blue: 0.94)

final class PanelState: ObservableObject {
    @Published var expanded = false
    @Published var selectedTab = 0
    @Published var focusAddToken = 0
    @Published var detailID: UUID?
    @Published var showSessionForm = false
    @Published var showInbox = false
    @Published var notice: String?
    @Published var opaque = ProcessInfo.processInfo.arguments.contains("--opaque")
    @Published var reduced = ProcessInfo.processInfo.arguments.contains("--reduced-motion")
    var resize: ((Bool) -> Void)?
    func toggle() { setExpanded(!expanded) }
    func setExpanded(_ value: Bool) {
        detailID = nil; showSessionForm = false; showInbox = false
        expanded = value; resize?(value)
    }
    func dismiss() {
        if detailID != nil { detailID = nil }
        else if showSessionForm { showSessionForm = false }
        else if showInbox { showInbox = false }
        else { setExpanded(false) }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    let state = PanelState()
    var store: AppStore!
    var monitor: Any?
    var screenObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let base = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = ProcessInfo.processInfo.environment["BIST_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? base.appendingPathComponent(args.contains("--demo") ? ".demo-data" : ".local-data")
        store = AppStore(directory: directory, demo: args.contains("--demo"))
        panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "bist"
        panel.isFloatingPanel = true; panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false; panel.animationBehavior = .none
        let host = NSHostingView(rootView: BistView(store: store, state: state, directory: directory))
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        state.resize = { [weak self] expanded in self?.position(expanded) }
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 { self.state.dismiss(); return nil }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "n": self.state.selectedTab = 0; self.state.setExpanded(true); self.state.focusAddToken += 1; return nil
                case "a": if let editor = self.panel.firstResponder as? NSText { editor.selectAll(nil); return nil }
                case "1": self.state.selectedTab = 0; self.state.setExpanded(true); return nil
                case "2": self.state.selectedTab = 1; self.state.setExpanded(true); return nil
                case "z":
                    if !(self.panel.firstResponder is NSTextView) { _ = self.store.undo(); return nil }
                case "q": NSApp.terminate(nil); return nil
                default: break
                }
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }; self.position(self.state.expanded)
        }
    }
    func position(_ expanded: Bool) {
        guard let screen = panel?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: expanded ? 360 : 224, height: expanded ? min(560, visible.height - 32) : 44)
        panel.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16, width: size.width, height: size.height), display: true)
    }
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Show bist", action: #selector(showPanel), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit bist", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { state.toggle(); panel.orderFrontRegardless() }
    }
    @objc func showPanel() { state.setExpanded(true); panel.orderFrontRegardless() }
    @objc func quit() { NSApp.terminate(nil) }
}

struct GlassMaterial: NSViewRepresentable {
    let opaque: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.blendingMode = .behindWindow; view.material = .hudWindow; view.state = .active; return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.isHidden = opaque }
}

struct Clover: View {
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            ForEach(0..<4) { n in
                Ellipse().fill(LinearGradient(colors: [Color(red: 0.76, green: 0.69, blue: 0.93), violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size * 0.44, height: size * 0.55)
                    .rotationEffect(.degrees(Double(n) * 90 + 45))
                    .offset(x: n % 2 == 0 ? -size * 0.19 : size * 0.19, y: n < 2 ? -size * 0.19 : size * 0.19)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct TactileStyle: ButtonStyle {
    var accent = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) var reduce
    @Environment(\.bistReduced) var localReduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(accent ? .white : ink)
            .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 7 : 9)
            .background(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous).fill(accent ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.62, green: 0.51, blue: 0.84), violet], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.35 : 0.62))))
            .overlay(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous).strokeBorder(.white.opacity(accent ? 0.25 : 0.8), lineWidth: 0.8))
            .shadow(color: (accent ? violet : .black).opacity(configuration.isPressed ? 0.03 : 0.10), radius: configuration.isPressed ? 1 : 3, x: 0, y: configuration.isPressed ? 0 : 2)
            .scaleEffect(configuration.isPressed && !(reduce || localReduce) ? 0.97 : 1)
            .animation(reduce || localReduce ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct BistView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var state: PanelState
    let directory: URL
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var newTask = ""
    @State private var waitingOpen = false
    @State private var adding = false
    @FocusState private var addFocused: Bool
    var active: [TaskItem] { store.tasks.filter { !$0.completed } }
    var opaque: Bool { state.opaque || reduceTransparency }
    var motion: Animation? { reduceMotion || state.reduced ? nil : .spring(response: 0.28, dampingFraction: 0.86) }
    var body: some View {
        ZStack {
            GlassMaterial(opaque: opaque)
            (opaque ? ivory : ivory.opacity(0.66))
            if !opaque {
                LinearGradient(colors: [.white.opacity(0.62), .white.opacity(0.06), Color(red: 0.82, green: 0.78, blue: 0.95).opacity(0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if state.expanded {
                expanded.transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
            } else { collapsed }
        }
        .clipShape(RoundedRectangle(cornerRadius: state.expanded ? 25 : 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: state.expanded ? 25 : 18, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3), .white.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: state.expanded ? 25 : 18, style: .continuous).inset(by: 1.5).strokeBorder(ink.opacity(0.035), lineWidth: 0.5))
        .foregroundColor(ink).font(.system(size: 13))
        .preferredColorScheme(.light)
        .environment(\.bistReduced, reduceMotion || state.reduced)
        .animation(motion, value: state.expanded)
    }
    var collapsed: some View {
        Button { state.setExpanded(true) } label: {
            HStack(spacing: 10) {
                Clover(size: 22)
                Text("bist").font(.system(size: 19, weight: .semibold, design: .rounded))
                Spacer(minLength: 5)
                Text("\(active.count) task\(active.count == 1 ? "" : "s")").font(.system(size: 11, weight: .medium)).foregroundColor(muted)
                Circle().fill(active.contains { $0.lane == .attention } ? violet : muted.opacity(0.35)).frame(width: 6, height: 6)
            }.padding(.horizontal, 15).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).focusable().accessibilityLabel("Expand bist, \(active.count) tasks").help("Open bist")
    }
    var expanded: some View {
        VStack(spacing: 0) {
            header
            if let id = state.detailID, let task = store.tasks.first(where: { $0.id == id }) {
                TaskDetail(task: task, store: store, close: { state.detailID = nil })
                    .id(id).transition(.opacity)
            } else if state.showSessionForm {
                SessionForm(store: store) { state.showSessionForm = false }.transition(.opacity)
            } else if state.showInbox {
                InboxView(store: store, directory: directory) { state.showInbox = false }.transition(.opacity)
            } else {
                tabs.padding(.horizontal, 17).padding(.bottom, 17)
                if state.selectedTab == 0 { taskContent } else { sessionContent }
            }
        }
    }
    var header: some View {
        HStack(spacing: 10) {
            Clover(size: 24)
            Text("bist").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.5)
            Spacer()
            Menu {
                Button("Reload local task file") { _ = store.reload() }
                Button("Review local updates…") { state.showInbox = true; state.detailID = nil; state.showSessionForm = false }
                Divider()
                Button("Load sample tasks") { _ = store.loadSamples() }
                Button("Remove sample tasks") { _ = store.clearSamples() }
                Divider()
                Toggle("Reduce transparency", isOn: $state.opaque)
                Toggle("Reduce motion", isOn: $state.reduced)
                Divider()
                Button("Quit bist") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("bist options").accessibilityLabel("bist options")
            Button { state.setExpanded(false) } label: { Image(systemName: "minus").font(.system(size: 12, weight: .medium)).frame(width: 14, height: 14) }
                .buttonStyle(TactileStyle(compact: true)).help("Collapse · Escape").accessibilityLabel("Collapse bist")
        }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 18)
    }
    var tabs: some View {
        HStack(spacing: 3) {
            tab("Tasks", number: active.count, index: 0)
            tab("Sessions", number: store.sessions.count, index: 1)
        }.padding(3).background(ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.45), lineWidth: 0.8))
    }
    func tab(_ title: String, number: Int, index: Int) -> some View {
        Button { withAnimation(motion) { state.selectedTab = index } } label: {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12, weight: state.selectedTab == index ? .semibold : .medium))
                if number > 0 { Text("\(number)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(state.selectedTab == index ? violet.opacity(0.1) : .clear, in: Capsule()) }
            }.foregroundColor(state.selectedTab == index ? ink : muted).frame(maxWidth: .infinity).frame(height: 32)
                .background(state.selectedTab == index ? .white.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 11))
                .shadow(color: .black.opacity(state.selectedTab == index ? 0.07 : 0), radius: 2, y: 1)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).focusable().accessibilityAddTraits(state.selectedTab == index ? .isSelected : []).help(index == 0 ? "Tasks · ⌘1" : "Sessions · ⌘2")
    }
    var taskContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day()).font(.system(size: 11, weight: .medium)).foregroundColor(muted)
                Spacer()
                if active.contains(where: \.isSample) { Text("Sample tasks").font(.system(size: 9, weight: .medium)).foregroundColor(violet).padding(.horizontal, 7).padding(.vertical, 4).background(violet.opacity(0.08), in: Capsule()) }
            }.padding(.horizontal, 23).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if active.isEmpty { emptyTasks }
                    else {
                        taskSection("Needs attention", lane: .attention)
                        taskSection("Next", lane: .next)
                        waitingSection
                    }
                }.padding(.horizontal, 17).padding(.bottom, 8)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 0)
            bottomStatus.padding(.horizontal, 19).padding(.bottom, 8)
            HStack(spacing: 9) {
                Image(systemName: "plus").foregroundColor(violet)
                TextField("Add a task", text: $newTask).textFieldStyle(.plain).focused($addFocused).onSubmit(addTask).accessibilityLabel("New task title")
                if !newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: addTask) { Image(systemName: adding ? "checkmark" : "arrow.up").font(.system(size: 11, weight: .semibold)) }.buttonStyle(TactileStyle(accent: true, compact: true)).disabled(adding).accessibilityLabel("Add task")
                } else { Text("⌘N").font(.system(size: 10)).foregroundColor(muted.opacity(0.8)) }
            }.padding(.horizontal, 12).frame(height: 44).background(.white.opacity(0.53), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(addFocused ? violet.opacity(0.55) : .white.opacity(0.9), lineWidth: 1)).padding(.horizontal, 17)
            HStack(spacing: 5) {
                Image(systemName: "internaldrive").font(.system(size: 9))
                Text(store.storeError == nil ? "Saved on this Mac" : "Could not save changes").font(.system(size: 10))
                Spacer()
                Text("No live sync").font(.system(size: 10))
            }.foregroundColor(muted).padding(.horizontal, 22).padding(.top, 11).padding(.bottom, 16)
        }
        .onChange(of: state.focusAddToken) { _ in addFocused = true }
    }
    var emptyTasks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 29, weight: .ultraLight)).foregroundColor(violet)
            Text("A little space to think.").font(.system(size: 18, weight: .medium, design: .rounded))
            Text("Capture your next step below.\nYour tasks stay on this Mac.").font(.system(size: 12)).foregroundColor(muted).lineSpacing(4)
            Button("Try sample tasks") { _ = store.loadSamples() }.buttonStyle(TactileStyle(compact: true)).padding(.top, 5)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).padding(.top, 14)
    }
    @ViewBuilder func taskSection(_ title: String, lane: TaskLane) -> some View {
        let items = active.filter { $0.lane == lane }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if lane == .attention { Circle().fill(Color(red: 0.74, green: 0.50, blue: 0.22)).frame(width: 5, height: 5) }
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(lane == .attention ? Color(red: 0.51, green: 0.35, blue: 0.18) : muted)
                    Spacer(); Text("\(items.count)").font(.system(size: 10)).foregroundColor(muted)
                }.padding(.horizontal, 6)
                VStack(spacing: 6) { ForEach(items) { task in row(task) } }
            }
        }
    }
    var waitingSection: some View {
        let items = active.filter { $0.lane == .waiting }
        return VStack(spacing: 8) {
            Button { withAnimation(motion) { waitingOpen.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(waitingOpen ? 90 : 0))
                    Text("Waiting").font(.system(size: 11, weight: .medium))
                    Text("\(items.count)").font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 2).background(ink.opacity(0.05), in: Capsule())
                    Spacer()
                }.foregroundColor(muted).padding(.horizontal, 6).padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable().accessibilityLabel("Waiting, \(items.count) tasks, \(waitingOpen ? "expanded" : "collapsed")")
            if waitingOpen { ForEach(items) { task in row(task) }; if items.isEmpty { Text("Nothing waiting.").font(.system(size: 11)).foregroundColor(muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8) } }
        }
    }
    func row(_ task: TaskItem) -> some View {
        TaskRow(task: task, reduced: reduceMotion || state.reduced, complete: { withAnimation(motion) { _ = store.complete(id: task.id) } }, deferTask: { withAnimation(motion) { if task.lane == .waiting { _ = store.moveTask(id: task.id, lane: .next) } else { _ = store.deferTask(id: task.id) } } }, detail: { withAnimation(motion) { state.detailID = task.id } })
    }
    @ViewBuilder var bottomStatus: some View {
        if let error = store.storeError { Text(error).font(.system(size: 10)).foregroundColor(.red).lineLimit(3) }
        else if store.canUndo {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(violet).font(.system(size: 11))
                Text(store.lastActionLabel ?? "Task updated").font(.system(size: 11)).lineLimit(1)
                Spacer()
                Button("Undo") { withAnimation(motion) { _ = store.undo() } }.buttonStyle(.plain).focusable().font(.system(size: 11, weight: .semibold)).foregroundColor(violet).keyboardShortcut("z").accessibilityLabel("Undo last task action")
            }.padding(.horizontal, 10).frame(height: 32).background(violet.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    func addTask() {
        guard !adding, !newTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        adding = true
        withAnimation(motion) { if store.addTask(title: newTask) { newTask = "" } }
        adding = false
    }
    var sessionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Your agent spaces").font(.system(size: 11, weight: .medium)).foregroundColor(muted); Spacer(); Text("Local links").font(.system(size: 9, weight: .medium)).foregroundColor(violet).padding(.horizontal, 7).padding(.vertical, 4).background(violet.opacity(0.08), in: Capsule()) }.padding(.horizontal, 23).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(SessionProvider.allCases, id: \.self) { provider in
                        providerCard(provider)
                    }
                    ForEach(store.sessions) { session in sessionRow(session) }
                }.padding(.horizontal, 17)
            }.scrollIndicators(.hidden)
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { Image(systemName: "lock.shield"); Text("Only what you choose to link").fontWeight(.medium) }.font(.system(size: 11))
                Text("Links open in your browser. Live status and agent controls are not connected.").font(.system(size: 11)).lineSpacing(3).foregroundColor(muted)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.36), in: RoundedRectangle(cornerRadius: 13)).padding(.horizontal, 17).padding(.bottom, 12)
            bottomStatus.padding(.horizontal, 19).padding(.bottom, 8)
            Button { state.showSessionForm = true } label: { Label("Add a session link", systemImage: "plus").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity) }.buttonStyle(TactileStyle()).padding(.horizontal, 17).padding(.bottom, 18)
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
                if let string = session.url, let url = safeURL(string) { Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)) }.buttonStyle(TactileStyle(compact: true)).accessibilityLabel("Open \(session.title)") }
                Menu { Button("Remove local link") { _ = store.removeSession(id: session.id) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Options for \(session.title)")
            }
            Text("Last observed: never").font(.system(size: 9)).foregroundColor(muted)
        }.padding(12).background(violet.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
    }
}

func providerName(_ p: SessionProvider) -> String {
    switch p { case .claudeCode: return "Claude Code"; case .codex: return "ChatGPT / Codex"; case .muse: return "Meta Muse" }
}
func providerGlyph(_ p: SessionProvider) -> some View {
    let glyph: String = p == .claudeCode ? "asterisk" : p == .codex ? "command" : "infinity"
    let color: Color = p == .claudeCode ? Color(red: 0.64, green: 0.42, blue: 0.31) : p == .codex ? Color(red: 0.32, green: 0.48, blue: 0.43) : violet
    return Image(systemName: glyph).font(.system(size: 19, weight: .medium)).foregroundColor(color).frame(width: 38, height: 38).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.7), lineWidth: 0.7))
}
func safeURL(_ string: String) -> URL? {
    guard let u = URL(string: string), ["https", "http"].contains(u.scheme?.lowercased() ?? ""), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return nil }; return u
}

struct TaskRow: View {
    let task: TaskItem
    let reduced: Bool
    let complete: () -> Void
    let deferTask: () -> Void
    let detail: () -> Void
    @State private var hover = false
    @State private var finishing = false
    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard !finishing else { return }; finishing = true
                if reduced { complete(); finishing = false } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { complete(); finishing = false } }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(finishing ? violet : .white.opacity(0.44))
                    RoundedRectangle(cornerRadius: 6).strokeBorder(finishing ? violet : muted.opacity(0.34), lineWidth: 1)
                    if finishing { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundColor(.white) }
                }.frame(width: 21, height: 21).padding(3).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable().disabled(finishing).accessibilityLabel("Complete \(task.title)").help("Complete task")
            Button(action: detail) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading).strikethrough(finishing)
                    Text(task.nextAction.isEmpty ? (task.isSample ? "Sample · Try opening the details" : "Add a next action") : task.nextAction).font(.system(size: 10)).foregroundColor(muted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable().accessibilityLabel("Details for \(task.title)")
            Button(action: deferTask) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundColor(hover ? violet : muted.opacity(0.65)).frame(width: 23, height: 27).background(hover ? .white.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: 7)) }
                .buttonStyle(.plain).focusable().accessibilityLabel("Move \(task.title) to \(task.lane == .waiting ? "Next" : "Waiting")").help(task.lane == .waiting ? "Move to Next" : "Move to Waiting")
        }.padding(.horizontal, 8).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 13).fill(finishing ? violet.opacity(0.12) : .white.opacity(hover ? 0.78 : 0.46)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(hover ? 0.95 : 0.5), lineWidth: 0.8))
        .shadow(color: .black.opacity(hover ? 0.045 : 0), radius: 5, y: 2)
        .onHover { hover = $0 }
        .animation(reduced ? nil : .easeOut(duration: 0.12), value: hover)
        .animation(reduced ? nil : .easeOut(duration: 0.16), value: finishing)
    }
}

struct TaskDetail: View {
    let task: TaskItem
    @ObservedObject var store: AppStore
    let close: () -> Void
    @State private var title = ""
    @State private var next = ""
    @State private var notes = ""
    @State private var source = ""
    @State private var link = ""
    @State private var invalidLink = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: close) { Label("Tasks", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)) }.buttonStyle(.plain).focusable().foregroundColor(violet)
                Spacer(); if task.isSample { Text("Sample task").font(.system(size: 10)).foregroundColor(muted) }
            }.padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Task", text: $title)
                    field("Next action", text: $next, prompt: "One small, concrete step")
                    VStack(alignment: .leading, spacing: 7) { Text("Notes").font(.system(size: 10, weight: .semibold)).foregroundColor(muted); TextEditor(text: $notes).font(.system(size: 12)).scrollContentBackground(.hidden).frame(height: 64).padding(7).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Task notes") }
                    field("Source", text: $source, prompt: "Added by you")
                    field("Source link", text: $link, prompt: "https://…")
                    if invalidLink { Text("Use a full http or https link without credentials.").font(.system(size: 10)).foregroundColor(.red) }
                    if let url = safeURL(link) { Button { NSWorkspace.shared.open(url) } label: { Label("Open source", systemImage: "arrow.up.right") }.buttonStyle(TactileStyle(compact: true)) }
                }
            }.scrollIndicators(.hidden)
            if let error = store.storeError { Text(error).font(.system(size: 10)).foregroundColor(.red) }
            HStack {
                Menu("Move to…") {
                    Button("Needs attention") { move(to: .attention) }
                    Button("Next") { move(to: .next) }
                    Button("Waiting") { move(to: .waiting) }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Save changes") {
                    guard link.isEmpty || safeURL(link) != nil else { invalidLink = true; return }
                    if store.updateTask(id: task.id, title: title, notes: notes, nextAction: next, source: source.isEmpty ? nil : source, sourceURL: link.isEmpty ? nil : link) { close() }
                }.buttonStyle(TactileStyle(accent: true)).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 14)
        }.padding(.horizontal, 23).padding(.bottom, 22)
        .onAppear { title = task.title; next = task.nextAction; notes = task.notes; source = task.source ?? ""; link = task.sourceURL ?? "" }
    }
    func move(to lane: TaskLane) {
        guard link.isEmpty || safeURL(link) != nil else { invalidLink = true; return }
        if store.updateTask(id: task.id, title: title, notes: notes, nextAction: next, source: source.isEmpty ? nil : source, sourceURL: link.isEmpty ? nil : link), store.moveTask(id: task.id, lane: lane) { close() }
    }
    func field(_ name: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(.system(size: 10, weight: .semibold)).foregroundColor(muted)
            TextField(prompt, text: text).textFieldStyle(.plain).font(.system(size: 12)).padding(10).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel(name)
        }
    }
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
            Button(action: close) { Label("Sessions", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)) }.buttonStyle(.plain).focusable().foregroundColor(violet)
            Text("Keep a session close.").font(.system(size: 21, weight: .medium, design: .rounded))
            Text("Save a link you already have. Adding a link does not connect an account or reveal its status.").font(.system(size: 12)).foregroundColor(muted).lineSpacing(3)
            Picker("Product", selection: $provider) { ForEach(SessionProvider.allCases, id: \.self) { Text(providerName($0)).tag($0) } }.pickerStyle(.menu)
            TextField("Session title", text: $title).textFieldStyle(.plain).padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Session title")
            TextField("https://…", text: $url).textFieldStyle(.plain).padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel("Session URL")
            if let saveError = store.storeError { Text(saveError).font(.system(size: 11)).foregroundColor(.red) }
            if error { Text("Enter a title and a full http or https link without credentials.").font(.system(size: 11)).foregroundColor(.red) }
            Spacer()
            Button { error = false; guard safeURL(url) != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = true; return }; if store.addSession(provider: provider, title: title, url: url) { close() } } label: { Text("Save local link").frame(maxWidth: .infinity).font(.system(size: 12, weight: .semibold)) }.buttonStyle(TactileStyle(accent: true))
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
            Button(action: close) { Label("Back", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)) }.buttonStyle(.plain).focusable().foregroundColor(violet)
            Text("Review local updates").font(.system(size: 20, weight: .medium, design: .rounded))
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
                Button {
                    guard store.importProposals(proposals) else { error = store.storeError; return }
                    let imported = Set(proposals.map(\.id))
                    do { try LocalInbox(directory: directory).consume(ids: imported); proposals = try LocalInbox(directory: directory).load(); if proposals.isEmpty { close() } }
                    catch { self.error = error.localizedDescription }
                } label: { Text("Add \(proposals.count) task\(proposals.count == 1 ? "" : "s")").frame(maxWidth: .infinity) }.buttonStyle(TactileStyle(accent: true))
            }
        }.padding(.horizontal, 23).padding(.bottom, 23)
        .onAppear { do { proposals = try LocalInbox(directory: directory).load() } catch { self.error = error.localizedDescription }; loaded = true }
    }
}

@main
struct BistMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
