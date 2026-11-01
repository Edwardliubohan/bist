import Foundation

enum PhoneTaskEditError: LocalizedError {
    case changedElsewhere(String)

    var errorDescription: String? {
        switch self {
        case .changedElsewhere(let field):
            return "This task’s \(field) changed on another device. Your draft is still here. Copy it or reload the saved version before saving."
        }
    }
}

/// Only fields the person edited replace the current saved task. A remote
/// change to another field remains intact while this form is open.
struct PhoneTaskTextDraft: Codable, Equatable {
    private let original: TaskItem
    var title: String
    var notes: String
    var nextAction: String

    init(_ task: TaskItem) {
        original = task
        title = task.title
        notes = task.notes
        nextAction = task.nextAction
    }

    var hasChanges: Bool {
        title != original.title || notes != original.notes || nextAction != original.nextAction
    }

    func merging(into current: TaskItem) throws -> (title: String, notes: String, nextAction: String) {
        func merge(_ draft: String, _ before: String, _ saved: String, field: String) throws -> String {
            guard draft != before else { return saved }
            guard saved == before || saved == draft else { throw PhoneTaskEditError.changedElsewhere(field) }
            return draft
        }
        return (
            try merge(title, original.title, current.title, field: "title"),
            try merge(notes, original.notes, current.notes, field: "notes"),
            try merge(nextAction, original.nextAction, current.nextAction, field: "next action")
        )
    }
}

enum PhoneTaskNavigation {
    static func parentChoices(for taskID: UUID, tasks: [TaskItem]) -> [TaskItem] {
        var excluded: Set<UUID> = [taskID]
        var pending = [taskID]
        let children = Dictionary(grouping: tasks.filter { $0.parentID != nil }, by: { $0.parentID! })
        while let current = pending.popLast() {
            for child in children[current] ?? [] where excluded.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        let currentParent = tasks.first(where: { $0.id == taskID })?.parentID
        return tasks.filter { !excluded.contains($0.id) && (!$0.completed || $0.id == currentParent) }
    }
}

/// UI tests use an explicit UUID inside this app's temporary container. A test
/// runner cannot point the app at an arbitrary path or reuse personal drafts.
enum PhoneLaunchConfiguration {
    static func testDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                              temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL? {
        guard let value = environment["BIST_UI_TEST_ID"], let id = UUID(uuidString: value) else { return nil }
        return temporaryDirectory.appendingPathComponent("bist-ui-tests", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static let preferences: UserDefaults = {
        guard let value = ProcessInfo.processInfo.environment["BIST_UI_TEST_ID"], let id = UUID(uuidString: value) else { return .standard }
        guard let store = UserDefaults(suiteName: "bist.ui-tests." + id.uuidString) else {
            preconditionFailure("Could not create isolated UI test preferences")
        }
        return store
    }()
}
