import Foundation
import Combine
import Darwin

/// One location for Finder launches, run.sh, bookmarks, inboxes, and panel position.
enum BistDataLocation {
    static func directory(demo: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let override = environment["BIST_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(demo ? "bist-demo" : "bist", isDirectory: true)
    }

    static func legacyDirectory(demo: Bool) -> URL {
        let bundle = Bundle.main.bundleURL
        let base = bundle.pathExtension == "app"
            ? bundle.deletingLastPathComponent().deletingLastPathComponent()
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(demo ? ".demo-data" : ".local-data", isDirectory: true)
    }

    /// Publish a complete copy once; never remove the original or merge over a newer store.
    /// The same advisory lock is used by the Python helper commands.
    static func prepare(_ directory: URL, legacy: URL?) throws {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = parent.appendingPathComponent(".\(directory.lastPathComponent)-migration.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        if let legacy, fm.fileExists(atPath: legacy.path) {
            let staging = parent.appendingPathComponent(".\(directory.lastPathComponent)-migration-\(UUID())")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: legacy, to: staging)
            let values = try staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnknown) }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            try fm.moveItem(at: staging, to: directory)
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
}

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

enum TaskHorizon: String, Codable, CaseIterable, Identifiable {
    case shortTerm, longerTerm
    var id: String { rawValue }
    var title: String { self == .shortTerm ? "Short term" : "Longer term" }
}

/// The whole dragged subtree travels together. A list drop promotes it to a
/// root; a row drop either nests it or gives it the target's parent and order.
enum TaskPlacement: Equatable {
    case list(TaskHorizon), inside(UUID), before(UUID), after(UUID)
}

enum TaskLabelColor: String, Codable, CaseIterable, Identifiable {
    case lavender, blue, green, amber, rose, gray
    var id: String { rawValue }
    var hex: String {
        switch self {
        case .lavender: return "#7567B7"
        case .blue: return "#4D77A8"
        case .green: return "#448171"
        case .amber: return "#AD7A38"
        case .rose: return "#AB627B"
        case .gray: return "#717581"
        }
    }
}

struct TaskLabel: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var color: TaskLabelColor

    // Stable IDs keep migration deterministic. Defaults are editable and are
    // never automatically assigned to an existing or newly created task.
    static let defaults = [
        TaskLabel(id: UUID(uuidString: "C4502D0B-E7AB-48B3-A073-50040F539E26")!, name: "School", color: .blue),
        TaskLabel(id: UUID(uuidString: "73CC5AE9-F640-4BE8-9BD8-AE80128EAA74")!, name: "Class", color: .amber),
        TaskLabel(id: UUID(uuidString: "0090A4D6-EF0E-447F-8CE6-8B383AEAE701")!, name: "Koan", color: .green)
    ]
}

/// User-reviewed evidence of an agent result, independent of the user's own
/// completion state. No session status is inferred or changed by this record.
struct AgentCompletion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sessionID: UUID
    var artifactURL: String
    var summary: String
    var observedAt: Date
    var reviewedAt: Date
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
    var parentID: UUID? = nil
    var labelIDs: [UUID] = []
    var linkedSessionID: UUID? = nil
    var agentCompletion: AgentCompletion? = nil
    var horizon: TaskHorizon = .shortTerm
    var agentHelpRequested: Bool = false
    var completedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, notes, nextAction, source, sourceURL, lane, isSample, completed, createdAt
        case parentID, labelIDs, linkedSessionID, agentCompletion, horizon, agentHelpRequested, completedAt
    }
}

extension TaskItem {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            notes: try values.decodeIfPresent(String.self, forKey: .notes) ?? "",
            nextAction: try values.decodeIfPresent(String.self, forKey: .nextAction) ?? "",
            source: try values.decodeIfPresent(String.self, forKey: .source),
            sourceURL: try values.decodeIfPresent(String.self, forKey: .sourceURL),
            lane: try values.decodeIfPresent(TaskLane.self, forKey: .lane) ?? .next,
            isSample: try values.decodeIfPresent(Bool.self, forKey: .isSample) ?? false,
            completed: try values.decodeIfPresent(Bool.self, forKey: .completed) ?? false,
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            parentID: try values.decodeIfPresent(UUID.self, forKey: .parentID),
            labelIDs: try values.decodeIfPresent([UUID].self, forKey: .labelIDs) ?? [],
            linkedSessionID: try values.decodeIfPresent(UUID.self, forKey: .linkedSessionID),
            agentCompletion: try values.decodeIfPresent(AgentCompletion.self, forKey: .agentCompletion),
            horizon: try values.decodeIfPresent(TaskHorizon.self, forKey: .horizon) ?? .shortTerm,
            agentHelpRequested: try values.decodeIfPresent(Bool.self, forKey: .agentHelpRequested) ?? false,
            completedAt: try values.decodeIfPresent(Date.self, forKey: .completedAt)
        )
    }
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

/// Version 2 local file: {"schemaVersion":2,"tasks":[],"sessions":[],"labels":[]}.
/// Dates are ISO 8601; task/session IDs are UUID strings. This file contains only
/// explicitly entered local tasks and bookmarks. There are no account tokens,
/// private conversation imports, agent control commands, or network operations.
struct BistSnapshot: Codable, Equatable {
    var schemaVersion: Int = 2
    var tasks: [TaskItem] = []
    var sessions: [SessionItem] = []
    var labels: [TaskLabel] = TaskLabel.defaults

    enum CodingKeys: String, CodingKey { case schemaVersion, tasks, sessions, labels }
}

extension BistSnapshot {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values,
                                                   debugDescription: "Unsupported local data version")
        }
        // Migration is in memory only. AppStore persists v2 on the next real
        // mutation, leaving the original v1 file untouched merely by opening it.
        self.init(schemaVersion: 2,
                  tasks: try values.decode([TaskItem].self, forKey: .tasks),
                  sessions: try values.decode([SessionItem].self, forKey: .sessions),
                  labels: version == 1
                    ? (try values.decodeIfPresent([TaskLabel].self, forKey: .labels) ?? TaskLabel.defaults)
                    : (try values.decode([TaskLabel].self, forKey: .labels)))
    }
}

/// Accept the original whole-second ISO 8601 format and retain fractional
/// seconds for new writes, so rapid completions keep their order after restart.
private enum BistDateCoding {
    private static let secondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        if let dot = text.lastIndex(of: ".") {
            let afterDot = text.index(after: dot)
            if let zone = text[afterDot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                let digits = text[afterDot..<zone]
                if !digits.isEmpty, digits.count <= 9,
                   digits.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                   let fraction = Double("0." + digits),
                   let whole = secondsFormatter.date(from: String(text[..<dot]) + text[zone...]) {
                    return whole.addingTimeInterval(fraction)
                }
            }
        } else if let whole = secondsFormatter.date(from: text) {
            return whole
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 timestamp")
    }

    static func encode(_ date: Date, to encoder: Encoder) throws {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else {
            throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Non-finite timestamp"))
        }
        var seconds = floor(interval)
        var nanoseconds = Int(((interval - seconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 { seconds += 1; nanoseconds = 0 }
        let whole = secondsFormatter.string(from: Date(timeIntervalSince1970: seconds))
        guard whole.hasSuffix("Z") else {
            throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Unrepresentable timestamp"))
        }
        let text = nanoseconds == 0 ? whole : String(whole.dropLast()) + String(format: ".%09dZ", nanoseconds)
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var sessions: [SessionItem] = []
    @Published private(set) var labels: [TaskLabel] = TaskLabel.defaults
    @Published private(set) var storeError: String? = nil
    @Published private(set) var lastActionLabel: String? = nil
    @Published private(set) var canUndo = false
    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var completedHistory: [TaskItem] {
        tasks.enumerated().filter { $0.element.completed }.sorted { left, right in
            switch (left.element.completedAt, right.element.completedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate: return leftDate > rightDate
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }

    private struct UndoEntry {
        let snapshot: BistSnapshot
        let label: String
    }
    /// Drafts for deleted tasks stay available for every retained Undo action.
    var undoTaskIDs: Set<UUID> {
        Set(undoEntries.flatMap { $0.snapshot.tasks.map(\.id) })
    }
    private var undoEntries: [UndoEntry] = []
    private var blockedByUnreadableStore = false
    private let fileManager = FileManager.default
    private let legacyDirectory: URL?
    private let preparesDefaultDirectory: Bool
    private var snapshot: BistSnapshot { BistSnapshot(tasks: tasks, sessions: sessions, labels: labels) }

    init(directory: URL? = nil, demo: Bool = false, legacyDirectory: URL? = nil) {
        self.directory = directory ?? BistDataLocation.directory(demo: demo)
        preparesDefaultDirectory = legacyDirectory != nil || (directory == nil && ProcessInfo.processInfo.environment["BIST_DATA_DIR"] == nil)
        self.legacyDirectory = legacyDirectory ?? (preparesDefaultDirectory ? BistDataLocation.legacyDirectory(demo: demo) : nil)
        _ = reload()
        if demo && !fileManager.fileExists(atPath: stateURL.path) && !blockedByUnreadableStore {
            _ = loadSamples()
            undoEntries.removeAll()
            canUndo = false
            lastActionLabel = nil
        }
    }

    /// Auxiliary files must not create an empty destination after migration failed.
    func prepareForAuxiliaryWrite() -> Bool {
        guard !blockedByUnreadableStore else { return false }
        do {
            if preparesDefaultDirectory { try BistDataLocation.prepare(directory, legacy: legacyDirectory) }
            else { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            return true
        } catch {
            storeError = "Couldn’t save the panel position. Check local folder access."
            return false
        }
    }

    /// Explicit reload, for an approved local file update. No watcher or background
    /// sync is installed. An invalid file is preserved and blocks further writes.
    @discardableResult
    func reload() -> Bool {
        if preparesDefaultDirectory {
            do { try BistDataLocation.prepare(directory, legacy: legacyDirectory) }
            catch {
                blockedByUnreadableStore = true
                storeError = "Couldn’t prepare local storage at \(directory.path). Existing files are unchanged. Check folder access, then reload."
                return false
            }
        }
        guard fileManager.fileExists(atPath: stateURL.path) else {
            tasks = []; sessions = []; labels = TaskLabel.defaults
            blockedByUnreadableStore = false
            storeError = nil
            undoEntries.removeAll(); canUndo = false; lastActionLabel = nil
            return true
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { try BistDateCoding.decode($0) }
            let value = try decoder.decode(BistSnapshot.self, from: Data(contentsOf: stateURL))
            try validate(value)
            tasks = value.tasks; sessions = value.sessions; labels = value.labels
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
    func addTask(title: String, details: String = "", labelIDs: [UUID] = [],
                 agentHelpRequested: Bool = false, parentID: UUID? = nil,
                 horizon: TaskHorizon = .shortTerm) -> Bool {
        guard !blockedByUnreadableStore else { return false }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty && clean.count <= 240 else {
            storeError = "Give this task a title of 1–240 characters."
            return false
        }
        guard parentID == nil || tasks.contains(where: { $0.id == parentID }) else {
            storeError = "Choose an existing parent task."; return false
        }
        guard details.count <= 8000 else {
            storeError = "Use details of at most 8,000 characters."; return false
        }
        let knownLabels = Set(labels.map(\.id))
        guard Set(labelIDs).count == labelIDs.count, labelIDs.allSatisfy({ knownLabels.contains($0) }) else {
            storeError = "Choose each existing label only once."; return false
        }
        let inheritedHorizon = tasks.first(where: { $0.id == parentID })?.horizon ?? horizon
        return commit(label: "Task added") {
            $0.tasks.append(TaskItem(title: clean, notes: details, parentID: parentID,
                                    labelIDs: labelIDs, horizon: inheritedHorizon,
                                    agentHelpRequested: agentHelpRequested))
        }
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
        return setUserCompletion(id: id, completed: true)
    }

    /// User completion never completes descendants or changes agent evidence.
    @discardableResult
    func setUserCompletion(id: UUID, completed: Bool) -> Bool {
        guard !blockedByUnreadableStore, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        guard tasks[index].completed != completed else { storeError = nil; return true }
        return commit(label: completed ? "Task completed" : "Task reopened") {
            $0.tasks[index].completed = completed
            $0.tasks[index].completedAt = completed ? Date() : nil
        }
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
                    source: String? = nil, sourceURL: String? = nil,
                    agentHelpRequested: Bool? = nil) -> Bool {
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
        if let agentHelpRequested { updated.agentHelpRequested = agentHelpRequested }
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
    func reparentTask(id: UUID, parentID: UUID?) -> Bool {
        guard !blockedByUnreadableStore, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        guard parentID == nil || tasks.contains(where: { $0.id == parentID }) else {
            storeError = "Choose an existing parent task."; return false
        }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var ancestor = parentID
        var visited = Set<UUID>()
        while let current = ancestor {
            guard current != id, visited.insert(current).inserted else {
                storeError = "A task can’t be its own parent or become a child of its descendants."; return false
            }
            ancestor = byID[current]?.parentID
        }
        guard tasks[index].parentID != parentID else { storeError = nil; return true }
        let inheritedHorizon = parentID.flatMap { byID[$0]?.horizon } ?? tasks[index].horizon
        let descendants = subtreeIDs(rootID: id)
        return commit(label: "Task parent changed") { value in
            value.tasks[index].parentID = parentID
            for descendantIndex in value.tasks.indices where descendants.contains(value.tasks[descendantIndex].id) {
                value.tasks[descendantIndex].horizon = inheritedHorizon
            }
        }
    }

    func canMoveTask(id: UUID, to placement: TaskPlacement) -> Bool {
        guard tasks.contains(where: { $0.id == id }) else { return false }
        let descendants = subtreeIDs(rootID: id)
        switch placement {
        case .list: return true
        case .inside(let target), .before(let target), .after(let target):
            return !descendants.contains(target) && tasks.contains { $0.id == target && !$0.completed }
        }
    }

    /// A single validated commit keeps reparenting, group and ordering atomic,
    /// including on disk failures and undo. Unrelated siblings never move.
    @discardableResult
    func moveTask(id: UUID, to placement: TaskPlacement) -> Bool {
        guard !blockedByUnreadableStore, canMoveTask(id: id, to: placement) else {
            storeError = "Choose a destination outside this task and its subtasks."; return false
        }
        let subtree = subtreeIDs(rootID: id)
        let target: TaskItem?
        let parentID: UUID?
        let horizon: TaskHorizon
        switch placement {
        case .list(let group): target = nil; parentID = nil; horizon = group
        case .inside(let targetID):
            target = tasks.first { $0.id == targetID }!
            parentID = targetID; horizon = target!.horizon
        case .before(let targetID), .after(let targetID):
            target = tasks.first { $0.id == targetID }!
            parentID = target!.parentID; horizon = target!.horizon
        }
        var moved = tasks.filter { subtree.contains($0.id) }
        for index in moved.indices {
            moved[index].horizon = horizon
            if moved[index].id == id { moved[index].parentID = parentID }
        }
        var remaining = tasks.filter { !subtree.contains($0.id) }
        let insertion: Int
        switch placement {
        case .before:
            insertion = remaining.firstIndex { $0.id == target!.id }!
        case .after:
            // Storage need not be depth-first. Only sibling order determines
            // placement; a late descendant may follow unrelated siblings.
            insertion = remaining.firstIndex { $0.id == target!.id }! + 1
        case .inside:
            // Append among direct children, independent of where their deeper
            // descendants happen to be stored.
            insertion = (remaining.lastIndex { $0.parentID == target!.id }
                         ?? remaining.firstIndex { $0.id == target!.id }!) + 1
        case .list:
            insertion = (remaining.lastIndex { $0.horizon == horizon } ?? remaining.count - 1) + 1
        }
        remaining.insert(contentsOf: moved, at: insertion)
        guard remaining != tasks else { storeError = nil; return true }
        return commit(label: "Task moved") { $0.tasks = remaining }
    }

    /// Deleting a parent preserves its children at the closest retained parent.
    /// Deleting the subtree is a separate, explicit action. Both are undoable.
    @discardableResult
    func deleteTask(id: UUID, includingSubtasks: Bool = false) -> Bool {
        guard !blockedByUnreadableStore, let task = tasks.first(where: { $0.id == id }) else { return false }
        let removed = includingSubtasks ? subtreeIDs(rootID: id) : [id]
        return commit(label: includingSubtasks ? "Task and subtasks deleted" : "Task deleted") { value in
            if includingSubtasks {
                value.tasks.removeAll { removed.contains($0.id) }
            } else {
                var promoted = value.tasks.filter { $0.parentID == id }
                for index in promoted.indices { promoted[index].parentID = task.parentID }
                // Replace the deleted sibling with its direct children in their
                // existing order. Descendants retain their own sibling order.
                value.tasks = value.tasks.flatMap { item -> [TaskItem] in
                    if item.id == id { return promoted }
                    return item.parentID == id ? [] : [item]
                }
            }
        }
    }

    /// Group membership belongs to the whole task tree. Acting on a child moves
    /// its root and siblings too, keeping every checklist in one stable group.
    @discardableResult
    func setTaskHorizon(id: UUID, horizon: TaskHorizon) -> Bool {
        guard !blockedByUnreadableStore, tasks.contains(where: { $0.id == id }) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var rootID = id
        while let parentID = byID[rootID]?.parentID { rootID = parentID }
        guard byID[rootID]?.horizon != horizon else { storeError = nil; return true }
        let descendants = subtreeIDs(rootID: rootID)
        return commit(label: "Task group changed") { value in
            for index in value.tasks.indices where descendants.contains(value.tasks[index].id) {
                value.tasks[index].horizon = horizon
            }
        }
    }

    @discardableResult
    func addLabel(name: String, color: TaskLabelColor) -> Bool {
        guard !blockedByUnreadableStore, let name = validLabelName(name) else { return false }
        guard !labels.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            storeError = "A label with this name already exists."; return false
        }
        return commit(label: "Label added") { $0.labels.append(TaskLabel(name: name, color: color)) }
    }

    @discardableResult
    func updateLabel(id: UUID, name: String, color: TaskLabelColor) -> Bool {
        guard !blockedByUnreadableStore, let name = validLabelName(name),
              let index = labels.firstIndex(where: { $0.id == id }) else { return false }
        guard !labels.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) else {
            storeError = "A label with this name already exists."; return false
        }
        let updated = TaskLabel(id: id, name: name, color: color)
        guard updated != labels[index] else { storeError = nil; return true }
        return commit(label: "Label updated") { $0.labels[index] = updated }
    }

    @discardableResult
    func deleteLabel(id: UUID) -> Bool {
        guard labels.contains(where: { $0.id == id }) else { return false }
        return commit(label: "Label removed") { value in
            value.labels.removeAll { $0.id == id }
            for index in value.tasks.indices { value.tasks[index].labelIDs.removeAll { $0 == id } }
        }
    }

    @discardableResult
    func setTaskLabels(id: UUID, labelIDs: [UUID]) -> Bool {
        guard !blockedByUnreadableStore, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let known = Set(labels.map(\.id))
        guard Set(labelIDs).count == labelIDs.count, labelIDs.allSatisfy({ known.contains($0) }) else {
            storeError = "Choose each existing label only once."; return false
        }
        guard tasks[index].labelIDs != labelIDs else { storeError = nil; return true }
        return commit(label: "Task labels updated") { $0.tasks[index].labelIDs = labelIDs }
    }

    @discardableResult
    func linkTask(id: UUID, sessionID: UUID?) -> Bool {
        guard !blockedByUnreadableStore, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        guard sessionID == nil || sessions.contains(where: { $0.id == sessionID }) else {
            storeError = "Choose an existing saved session."; return false
        }
        guard tasks[index].linkedSessionID != sessionID else { storeError = nil; return true }
        guard tasks[index].agentCompletion == nil else {
            storeError = "Clear the reviewed agent result before changing its session link."; return false
        }
        return commit(label: sessionID == nil ? "Task session unlinked" : "Task session linked") {
            $0.tasks[index].linkedSessionID = sessionID
        }
    }

    @discardableResult
    func recordAgentCompletion(_ evidence: AgentCompletion, taskID: UUID) -> Bool {
        guard !blockedByUnreadableStore, let index = tasks.firstIndex(where: { $0.id == taskID }) else { return false }
        guard tasks[index].linkedSessionID == evidence.sessionID,
              sessions.contains(where: { $0.id == evidence.sessionID }) else {
            storeError = "Link this task to the same saved session before recording its result."; return false
        }
        guard Self.validEvidence(evidence), !tasks.contains(where: {
            $0.id != taskID && $0.agentCompletion?.id == evidence.id
        }) else {
            storeError = "Use a unique result with a safe artifact link, a summary, and valid observation and review dates."; return false
        }
        guard tasks[index].agentCompletion != evidence else { storeError = nil; return true }
        guard tasks[index].agentCompletion == nil else {
            storeError = "Clear the previous reviewed agent result before recording a different result."; return false
        }
        return commit(label: "Agent result recorded") { $0.tasks[index].agentCompletion = evidence }
    }

    @discardableResult
    func clearAgentCompletion(taskID: UUID) -> Bool {
        guard !blockedByUnreadableStore, let index = tasks.firstIndex(where: { $0.id == taskID }) else { return false }
        guard tasks[index].agentCompletion != nil else { storeError = nil; return true }
        return commit(label: "Agent result cleared") { $0.tasks[index].agentCompletion = nil }
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
        guard !tasks.contains(where: { $0.linkedSessionID == id || $0.agentCompletion?.sessionID == id }) else {
            storeError = "Unlink the tasks using this session before removing it."; return false
        }
        return commit(label: "Session link removed") { $0.sessions.removeAll { $0.id == id } }
    }

    @discardableResult
    func undo() -> Bool {
        guard let entry = undoEntries.last, !blockedByUnreadableStore else { return false }
        guard write(entry.snapshot) else { return false }
        tasks = entry.snapshot.tasks; sessions = entry.snapshot.sessions; labels = entry.snapshot.labels
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
        return commit(label: "Sample tasks cleared") { value in
            let byID = Dictionary(uniqueKeysWithValues: value.tasks.map { ($0.id, $0) })
            value.tasks.removeAll(where: \.isSample)
            // User-created children of a sample survive. Promote them to the
            // closest retained ancestor, or to the root, without losing content.
            for index in value.tasks.indices {
                var parent = value.tasks[index].parentID
                while let current = parent, byID[current]?.isSample == true {
                    parent = byID[current]?.parentID
                }
                value.tasks[index].parentID = parent
            }
        }
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

    private func subtreeIDs(rootID: UUID) -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for task in tasks {
            if let parentID = task.parentID { children[parentID, default: []].append(task.id) }
        }
        var result: Set<UUID> = [rootID]
        var pending = [rootID]
        while let id = pending.popLast() {
            for childID in children[id] ?? [] where result.insert(childID).inserted {
                pending.append(childID)
            }
        }
        return result
    }

    private func validLabelName(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidLabelName(clean) else {
            storeError = "Use a label name of 1–40 characters on one line."; return nil
        }
        return clean
    }

    private static func isValidLabelName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 &&
        name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
        name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    }

    private static func validEvidence(_ evidence: AgentCompletion, now: Date = Date()) -> Bool {
        let tolerance: TimeInterval = 300
        return safeURL(evidence.artifactURL) != nil &&
            !evidence.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            evidence.summary.count <= 4000 &&
            evidence.observedAt.timeIntervalSince1970.isFinite &&
            evidence.reviewedAt.timeIntervalSince1970.isFinite &&
            evidence.observedAt <= now.addingTimeInterval(tolerance) &&
            evidence.reviewedAt <= now.addingTimeInterval(tolerance) &&
            evidence.reviewedAt >= evidence.observedAt.addingTimeInterval(-tolerance)
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
        tasks = after.tasks; sessions = after.sessions; labels = after.labels
        canUndo = true; lastActionLabel = label
        return true
    }

    private func write(_ value: BistSnapshot) -> Bool {
        do {
            try validate(value)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { try BistDateCoding.encode($0, to: $1) }
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
        guard value.schemaVersion == 2,
              Set(value.tasks.map(\.id)).count == value.tasks.count,
              Set(value.sessions.map(\.id)).count == value.sessions.count,
              Set(value.labels.map(\.id)).count == value.labels.count,
              Set(value.labels.map { $0.name.lowercased() }).count == value.labels.count,
              value.labels.allSatisfy({ Self.isValidLabelName($0.name) }) else { throw ValidationError.invalidSnapshot }
        let taskIDs = Set(value.tasks.map(\.id))
        let sessionIDs = Set(value.sessions.map(\.id))
        let labelIDs = Set(value.labels.map(\.id))
        var evidenceIDs = Set<UUID>()
        for task in value.tasks {
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.title.count <= 240, task.notes.count <= 8000, task.nextAction.count <= 2000,
                  task.sourceURL == nil || Self.safeURL(task.sourceURL!) != nil,
                  task.completed || task.completedAt == nil,
                  task.completedAt == nil || task.completedAt!.timeIntervalSince1970.isFinite,
                  task.parentID == nil || (task.parentID != task.id && taskIDs.contains(task.parentID!)),
                  Set(task.labelIDs).count == task.labelIDs.count,
                  task.labelIDs.allSatisfy({ labelIDs.contains($0) }),
                  task.linkedSessionID == nil || sessionIDs.contains(task.linkedSessionID!) else { throw ValidationError.invalidSnapshot }
            if let evidence = task.agentCompletion {
                guard task.linkedSessionID == evidence.sessionID, sessionIDs.contains(evidence.sessionID),
                      evidenceIDs.insert(evidence.id).inserted, Self.validEvidence(evidence) else { throw ValidationError.invalidSnapshot }
            }
        }
        // Iterative traversal keeps deeply nested checklists safe from recursion
        // limits. Already-validated branches make the whole traversal linear.
        let byID = Dictionary(uniqueKeysWithValues: value.tasks.map { ($0.id, $0) })
        var resolved = Set<UUID>()
        for task in value.tasks {
            if let parentID = task.parentID {
                guard byID[parentID]?.horizon == task.horizon else { throw ValidationError.invalidSnapshot }
            }
            var chain = Set<UUID>()
            var current: UUID? = task.id
            while let id = current, !resolved.contains(id) {
                guard chain.insert(id).inserted else { throw ValidationError.invalidSnapshot }
                current = byID[id]?.parentID
            }
            resolved.formUnion(chain)
        }
        for session in value.sessions {
            guard !session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  session.title.count <= 240,
                  session.url == nil || Self.safeURL(session.url!) != nil else { throw ValidationError.invalidSnapshot }
        }
    }
}
