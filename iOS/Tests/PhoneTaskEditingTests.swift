import Foundation

@main
struct PhoneTaskEditingTests {
    static func main() throws {
        let original = TaskItem(title: "Read", notes: "Old notes", nextAction: "Open book")
        var draft = PhoneTaskTextDraft(original)
        draft.title = "Read chapter"
        var remote = original
        remote.notes = "Notes from Mac"
        let merged = try draft.merging(into: remote)
        precondition(merged.title == "Read chapter")
        precondition(merged.notes == "Notes from Mac", "Saving a title must preserve a newer remote note")
        precondition(merged.nextAction == "Open book")

        remote.title = "Read paper"
        do {
            _ = try draft.merging(into: remote)
            fatalError("Concurrent title edits must remain visible for review")
        } catch PhoneTaskEditError.changedElsewhere(let field) {
            precondition(field == "title")
        }
        let savedDraft = try JSONEncoder().encode(draft)
        let reopenedDraft = try JSONDecoder().decode(PhoneTaskTextDraft.self, from: savedDraft)
        do {
            _ = try reopenedDraft.merging(into: remote)
            fatalError("Reopening a draft must retain its original merge baseline")
        } catch PhoneTaskEditError.changedElsewhere {}
        draft.title = remote.title
        let identical = try draft.merging(into: remote)
        precondition(identical.title == "Read paper")

        let root = TaskItem(title: "Parent")
        let child = TaskItem(title: "Child", parentID: root.id)
        let grandchild = TaskItem(title: "Grandchild", parentID: child.id)
        let other = TaskItem(title: "Other")
        let completed = TaskItem(title: "Past", completed: true)
        let choices = PhoneTaskNavigation.parentChoices(for: root.id, tasks: [root, child, grandchild, other, completed])
        precondition(choices.map(\.id) == [other.id], "Parent choices must exclude self, descendants and completed tasks")
        let childChoices = PhoneTaskNavigation.parentChoices(for: child.id, tasks: [root, child, grandchild, other])
        precondition(childChoices.map(\.id) == [root.id, other.id])
        var completedRoot = root
        completedRoot.completed = true
        let retainedParent = PhoneTaskNavigation.parentChoices(for: child.id, tasks: [completedRoot, child, other])
        precondition(retainedParent.map(\.id) == [root.id, other.id], "The current completed parent must remain a valid picker selection")
        let testID = "E17F5555-1111-4444-8888-222222222222"
        let temp = URL(fileURLWithPath: "/isolated-phone-temp", isDirectory: true)
        precondition(PhoneLaunchConfiguration.testDirectory(environment: [:], temporaryDirectory: temp) == nil)
        precondition(PhoneLaunchConfiguration.testDirectory(environment: ["BIST_UI_TEST_ID": "../../personal"], temporaryDirectory: temp) == nil)
        let isolated = PhoneLaunchConfiguration.testDirectory(environment: ["BIST_UI_TEST_ID": testID], temporaryDirectory: temp)
        precondition(isolated?.path == "/isolated-phone-temp/bist-ui-tests/E17F5555-1111-4444-8888-222222222222")
        print("PASS phone editing and hierarchy checks")
    }
}
