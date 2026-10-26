import Foundation
import Combine

enum TaskLane: String, Codable, CaseIterable, Identifiable {
    case attention, next, waiting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attention: return "Needs attention"
        case .next: return "Next"
        case .waiting: return "Waiting"
        }
    }
}

struct TaskItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var notes: String = ""
    var nextAction: String = ""
    var source: String? = nil
    var sourceURL: String? = nil
    var lane: TaskLane = .next
    var isSample: Bool = false
    var completed: Bool = false
    var createdAt: Date = Date()
}

enum SessionProvider: String, Codable, CaseIterable, Identifiable {
    case claudeCode, codex, muse
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "ChatGPT / Codex"
        case .muse: return "Meta Muse"
        }
    }
    var vendorName: String {
        switch self {
        case .claudeCode: return "Anthropic"
        case .codex: return "OpenAI"
        case .muse: return "Meta"
        }
    }
}

enum SessionStatus: String, Codable {
    case unknown, disconnected
    var title: String { rawValue.capitalized }
}

struct SessionItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var provider: SessionProvider
    var title: String
    var url: String? = nil
    // A saved bookmark is never evidence that an agent is running.
    var status: SessionStatus = .unknown
    var observedAt: Date? = nil
}

/// Version 1 local file: {"schemaVersion":1,"tasks":[TaskItem],"sessions":[SessionItem]}.
/// Dates are ISO 8601; task/session IDs are UUID strings. This file contains only
/// explicitly entered local tasks and bookmarks. There are no account tokens,
/// private conversation imports, agent control commands, or network operations.
struct BistSnapshot: Codable, Equatable {
    var schemaVersion: Int = 1
    var tasks: [TaskItem] = []
    var sessions: [SessionItem] = []
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var sessions: [SessionItem] = []
    @Published private(set) var storeError: String? = nil
    @Published private(set) var lastActionLabel: String? = nil
    @Published private(set) var canUndo = false
    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("state.json") }

    private struct UndoEntry {
        let snapshot: BistSnapshot
        let label: String
    }
    private var undoEntries: [UndoEntry] = []
    private var blockedByUnreadableStore = false
    private let fileManager = FileManager.default
    private var snapshot: BistSnapshot { BistSnapshot(tasks: tasks, sessions: sessions) }

    init(directory: URL? = nil, demo: Bool = false) {
        let fallback = ProcessInfo.processInfo.environment["BIST_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".local-data", isDirectory: true)
        self.directory = directory ?? fallback
        _ = reload()
        if demo && !fileManager.fileExists(atPath: stateURL.path) && !blockedByUnreadableStore {
            _ = loadSamples()
            undoEntries.removeAll()
            canUndo = false
            lastActionLabel = nil
        }
    }

    /// Explicit reload, for an approved local file update. No watcher or background
    /// sync is installed. An invalid file is preserved and blocks further writes.
    @discardableResult
    func reload() -> Bool {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            tasks = []; sessions = []
            blockedByUnreadableStore = false
            storeError = nil
            undoEntries.removeAll(); canUndo = false
            return true
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(BistSnapshot.self, from: Data(contentsOf: stateURL))
            try validate(value)
            tasks = value.tasks; sessions = value.sessions
            blockedByUnreadableStore = false
            storeError = nil
            undoEntries.removeAll(); canUndo = false; lastActionLabel = nil
            return true
        } catch {
            blockedByUnreadableStore = true
            storeError = "Couldn’t read the local task file. Your file is unchanged. Repair it, then reload."
            return false
        }
    }

    @discardableResult
    func addTask(title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean.count <= 240 else {
            storeError = "Give this task a title of 1–240 characters."
            return false
        }
        return commit(label: "Task added") { $0.tasks.append(TaskItem(title: clean)) }
    }

    /// Imports one explicitly reviewed local batch. Reusing proposal IDs makes a
    /// retry safe if saving succeeded but consuming the inbox did not. Existing
    /// tasks are never overwritten, including tasks edited after their import.
    @discardableResult
    func importProposals(_ proposals: [TaskProposal]) -> Bool {
        guard !blockedByUnreadableStore else { return false }
        guard proposals.count <= LocalInbox.maximumProposals,
              Set(proposals.map(\.id)).count == proposals.count,
              proposals.allSatisfy({ proposal in
                  !proposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  proposal.title.count <= 200 && proposal.nextAction.count <= 600 &&
                  proposal.source.count <= 160
              }) else {
            storeError = "Local updates contain an invalid task. Nothing was imported."
            return false
        }
        let existingIDs = Set(tasks.map(\.id))
        let additions = proposals.filter { !existingIDs.contains($0.id) }.map { proposal in
            TaskItem(id: proposal.id,
                     title: proposal.title.trimmingCharacters(in: .whitespacesAndNewlines),
                     nextAction: proposal.nextAction,
                     source: nonempty(proposal.source),
                     createdAt: proposal.createdAt)
        }
        guard !additions.isEmpty else {
            storeError = nil
            return true
        }
        return commit(label: "Local updates added") { $0.tasks += additions }
    }

    @discardableResult
    func complete(id: UUID) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].completed else { return false }
        return commit(label: "Task completed") { $0.tasks[index].completed = true }
    }

    @discardableResult
    func deferTask(id: UUID) -> Bool { moveTask(id: id, lane: .waiting) }

    @discardableResult
    func moveTask(id: UUID, lane: TaskLane) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              !tasks[index].completed, tasks[index].lane != lane else { return false }
        return commit(label: lane == .waiting ? "Task deferred" : "Task moved") { $0.tasks[index].lane = lane }
    }

    @discardableResult
    func updateTask(id: UUID, title: String, notes: String, nextAction: String,
                    source: String? = nil, sourceURL: String? = nil) -> Bool {
        guard !blockedByUnreadableStore else { return false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty && cleanTitle.count <= 240 else {
            storeError = "Give this task a title of 1–240 characters."; return false
        }
        guard notes.count <= 8000 && nextAction.count <= 2000 else {
            storeError = "Use shorter notes or a shorter next action."; return false
        }
        let cleanURL = nonempty(sourceURL)
        guard cleanURL == nil || Self.safeURL(cleanURL!) != nil else {
            storeError = "Use an http or https source link without account credentials."; return false
        }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        var updated = tasks[index]
        updated.title = cleanTitle
        updated.notes = notes
        updated.nextAction = nextAction
        updated.source = nonempty(source)
        updated.sourceURL = cleanURL
        // Saving an untouched detail is successful, including before a lane move.
        // Keep it out of the persistence and undo paths because nothing changed.
        guard updated != tasks[index] else {
            storeError = nil
            return true
        }
        return commit(label: "Task updated") {
            $0.tasks[index] = updated
        }
    }

    @discardableResult
    func addSession(provider: SessionProvider, title: String, url: String) -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty && cleanTitle.count <= 240 else {
            storeError = "Give this session a title of 1–240 characters."; return false
        }
        guard let safeURL = Self.safeURL(url) else {
            storeError = "Use an http or https session link without account credentials."; return false
        }
        return commit(label: "Session link saved") {
            $0.sessions.append(SessionItem(provider: provider, title: cleanTitle, url: safeURL.absoluteString))
        }
    }

    @discardableResult
    func removeSession(id: UUID) -> Bool {
        guard sessions.contains(where: { $0.id == id }) else { return false }
        return commit(label: "Session link removed") { $0.sessions.removeAll { $0.id == id } }
    }

    @discardableResult
    func undo() -> Bool {
        guard let entry = undoEntries.last, !blockedByUnreadableStore else { return false }
        guard write(entry.snapshot) else { return false }
        tasks = entry.snapshot.tasks; sessions = entry.snapshot.sessions
        undoEntries.removeLast(); canUndo = !undoEntries.isEmpty
        lastActionLabel = "Undone"
        return true
    }

    @discardableResult
    func loadSamples() -> Bool {
        guard !tasks.contains(where: \.isSample) else { return false }
        return commit(label: "Sample tasks added") {
            $0.tasks += [
                TaskItem(title: "Shape a calmer workspace", notes: "This is a sample task. Try completing it, then Undo to bring it back.", nextAction: "Try the completion button", source: "Sample task", lane: .attention, isSample: true),
                TaskItem(title: "Make room for what’s next", notes: "This sample stays on this Mac. Deferring moves it to Waiting.", nextAction: "Open the task details", source: "Sample task", lane: .next, isSample: true),
                TaskItem(title: "Keep a useful session close", notes: "Add a session link in Sessions. A bookmark does not connect an account or report live agent activity.", nextAction: "Explore Sessions", source: "Sample task", lane: .next, isSample: true),
                TaskItem(title: "A little space to think", notes: "Waiting is collapsed by default. Move this sample to Next whenever you’re ready.", nextAction: "Move to Next", source: "Sample task", lane: .waiting, isSample: true)
            ]
        }
    }

    @discardableResult
    func clearSamples() -> Bool {
        guard tasks.contains(where: \.isSample) else { return false }
        return commit(label: "Sample tasks cleared") { $0.tasks.removeAll(where: \.isSample) }
    }

    static func safeURL(_ value: String) -> URL? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 4096, let components = URLComponents(string: clean),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private func commit(label: String, mutation: (inout BistSnapshot) -> Void) -> Bool {
        guard !blockedByUnreadableStore else { return false }
        let before = snapshot
        var after = before
        mutation(&after)
        guard after != before else { return false }
        guard write(after) else { return false }
        undoEntries.append(UndoEntry(snapshot: before, label: label))
        // Keep local undo bounded while retaining enough steps for repeated actions.
        if undoEntries.count > 100 { undoEntries.removeFirst() }
        tasks = after.tasks; sessions = after.sessions
        canUndo = true; lastActionLabel = label
        return true
    }

    private func write(_ value: BistSnapshot) -> Bool {
        do {
            try validate(value)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: stateURL, options: .atomic)
            storeError = nil
            return true
        } catch {
            storeError = "Couldn’t save your changes. The previous task file is unchanged."
            return false
        }
    }

    private enum ValidationError: Error { case invalidSnapshot }
    private func validate(_ value: BistSnapshot) throws {
        guard value.schemaVersion == 1,
              Set(value.tasks.map(\.id)).count == value.tasks.count,
              Set(value.sessions.map(\.id)).count == value.sessions.count else { throw ValidationError.invalidSnapshot }
        for task in value.tasks {
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.title.count <= 240, task.notes.count <= 8000, task.nextAction.count <= 2000,
                  task.sourceURL == nil || Self.safeURL(task.sourceURL!) != nil else { throw ValidationError.invalidSnapshot }
        }
        for session in value.sessions {
            guard !session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  session.title.count <= 240,
                  session.url == nil || Self.safeURL(session.url!) != nil else { throw ValidationError.invalidSnapshot }
        }
    }
}
