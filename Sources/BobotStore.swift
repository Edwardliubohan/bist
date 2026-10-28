import Foundation
import Combine
import Darwin

struct BobotQuestion: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var answer: String?
}

struct BobotJob: Codable, Equatable, Identifiable {
    var id: String
    var taskID: String
    var title: String
    var details: String
    var state: String
    var revision: Int
    var createdAt: Double
    var updatedAt: Double
    var progress: String
    var claimID: String?
    var executionID: String?
    var questions: [BobotQuestion]
    var result: String?
    var resultURL: String?
    var terminal: Bool { ["completed", "failed", "cancelled"].contains(state) }
    var pendingQuestion: BobotQuestion? { state == "waiting" ? questions.first { $0.answer == nil } : nil }
    var status: String {
        switch state {
        case "queued": return "Queued for Bobot"
        case "ready": return "Answer sent · waiting for Bobot"
        case "working": return progress.isEmpty ? "Bobot is working…" : progress
        case "waiting": return "Bobot has a question"
        case "completed": return "Ready for review"
        case "cancelled": return "Cancelled in bist"
        default: return "Needs attention"
        }
    }
}

private struct BobotLedger: Codable {
    var version = 1
    var jobs: [BobotJob] = []
}

/// A separate durable queue: only an explicit assignment copies task text here.
/// The MCP bridge and app share this lock and atomic JSON format. Neither writes state.json.
@MainActor
final class BobotStore: ObservableObject {
    @Published private(set) var jobs: [BobotJob] = []
    @Published private(set) var connected = false
    @Published var error: String?
    @Published var questionDrafts: [String: String] = [:]
    @Published var requestedQuestionID: String?
    let directory: URL
    private let prepare: () -> Bool
    init(directory: URL, prepare: @escaping () -> Bool = { true }) {
        self.directory = directory; self.prepare = prepare
        refresh()
    }
    var pending: [BobotJob] { jobs.filter { $0.pendingQuestion != nil } }
    func latest(for id: UUID) -> BobotJob? { jobs.last { $0.taskID == id.uuidString.lowercased() } }
    /// The latest explicit assignment supersedes older results, including a rerun.
    /// This is a display projection only; personal completion and Undo stay in AppStore.
    func agentCompletionStatus(for task: TaskItem) -> (done: Bool, value: String, hint: String) {
        if error != nil {
            return (false, "Unknown. Couldn’t read agent status.", "Check Bobot’s queue in Sessions.")
        }
        if let job = latest(for: task.id) {
            return (job.state == "completed",
                    job.state == "completed" ? "Done by agent. Ready for your review." : job.status,
                    "Open task details for the assignment and output. Check Me after your own review and completion.")
        }
        return (task.agentCompletion != nil,
                task.agentCompletion == nil ? "No completed agent result." : "Done. Result reviewed by you.",
                "Open task details for result evidence.")
    }

    private func read() throws -> BobotLedger {
        let path = directory.appendingPathComponent("bobot-jobs.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return BobotLedger() }
            throw CocoaError(.fileReadUnknown)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size <= 4_194_304 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(BobotLedger.self, from: handle.readToEnd() ?? Data())
        try validate(value)
        return value
    }
    private func validate(_ value: BobotLedger) throws {
        guard value.version == 1, value.jobs.count <= 1000,
              Set(value.jobs.map(\.id)).count == value.jobs.count,
              value.jobs.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.taskID) != nil &&
                  ["queued", "ready", "working", "waiting", "completed", "failed", "cancelled"].contains($0.state) &&
                  $0.revision >= 0 && $0.title.count <= 240 && $0.details.count <= 8000 &&
                  $0.questions.count <= 100 && $0.questions.allSatisfy { $0.text.count <= 8000 && ($0.answer?.count ?? 0) <= 8000 } &&
                  ($0.result?.count ?? 0) <= 32000 }) else { throw CocoaError(.fileReadCorruptFile) }
    }
    func refresh() {
        do {
            let value = try read()
            if jobs != value.jobs { jobs = value.jobs }
            error = nil
            struct Connection: Decodable { var heartbeat: Double; var subscribed: Bool }
            let connection = try? JSONDecoder().decode(Connection.self, from: Data(contentsOf: directory.appendingPathComponent("bobot-connection.json")))
            connected = connection.map { $0.subscribed && Date().timeIntervalSince1970 - $0.heartbeat < 15 && $0.heartbeat <= Date().timeIntervalSince1970 + 5 } ?? false
        } catch { connected = false; self.error = "Couldn’t read Bobot’s queue. Check bobot-jobs.json; existing data was kept." }
    }
    @discardableResult private func change(_ body: (inout BobotLedger) throws -> Void) -> Bool {
        do {
            guard prepare() else { throw CocoaError(.fileWriteUnknown) }
            let fd = open(directory.appendingPathComponent(".bobot-jobs.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(fd, LOCK_UN) }
            var ledger = try read()
            try body(&ledger)
            try validate(ledger)
            let data = try JSONEncoder().encode(ledger)
            guard data.count <= 4_194_304 else { throw CocoaError(.fileWriteOutOfSpace) }
            let temporary = directory.appendingPathComponent(".bobot-\(UUID())")
            let output = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(output); unlink(temporary.path) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += count
                }
            }
            guard fsync(output) == 0, rename(temporary.path, directory.appendingPathComponent("bobot-jobs.json").path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let folder = open(directory.path, O_RDONLY)
            if folder >= 0 { _ = fsync(folder); close(folder) }
            jobs = ledger.jobs; error = nil
            return true
        } catch { self.error = "Couldn’t save Bobot’s queue. Check the data folder, then try again."; return false }
    }
    @discardableResult func assign(_ task: TaskItem) -> Bool {
        change { ledger in
            guard !ledger.jobs.contains(where: { $0.taskID == task.id.uuidString.lowercased() && !$0.terminal }) else { return }
            guard ledger.jobs.count < 1000 else { throw CocoaError(.fileWriteOutOfSpace) }
            let now = Date().timeIntervalSince1970
            ledger.jobs.append(BobotJob(id: UUID().uuidString.lowercased(), taskID: task.id.uuidString.lowercased(),
                title: task.title, details: task.notes, state: "queued", revision: 0, createdAt: now, updatedAt: now,
                progress: "", questions: []))
        }
    }
    @discardableResult func answer(jobID: String, questionID: String, text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8000 else { return false }
        return change { ledger in
            guard let i = ledger.jobs.firstIndex(where: { $0.id == jobID }), ledger.jobs[i].state == "waiting",
                  let q = ledger.jobs[i].questions.firstIndex(where: { $0.id == questionID && $0.answer == nil }) else { throw CocoaError(.fileWriteUnknown) }
            ledger.jobs[i].questions[q].answer = text
            ledger.jobs[i].state = "ready"; ledger.jobs[i].revision += 1; ledger.jobs[i].updatedAt = Date().timeIntervalSince1970
        }
    }
    @discardableResult func cancel(_ id: String) -> Bool {
        change { ledger in
            guard let i = ledger.jobs.firstIndex(where: { $0.id == id }), !ledger.jobs[i].terminal else { throw CocoaError(.fileWriteUnknown) }
            ledger.jobs[i].state = "cancelled"; ledger.jobs[i].revision += 1; ledger.jobs[i].updatedAt = Date().timeIntervalSince1970
        }
    }
}
