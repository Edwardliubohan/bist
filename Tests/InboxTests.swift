import Foundation

@main
struct InboxTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-inbox-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = LocalInbox(directory: directory)
        try check(inbox.load().isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("inbox.json")
        let first = UUID(), second = UUID(), addedLater = UUID()
        func proposal(_ id: UUID, title: String = "Review sample") -> [String: String] {
            ["id": id.uuidString, "title": title, "nextAction": "Read one paragraph", "source": "Test", "createdAt": "2026-10-26T12:00:00Z"]
        }
        func write(_ items: [[String: String]], version: Int = 1) throws {
            let data = try JSONSerialization.data(withJSONObject: ["version": version, "proposals": items])
            try data.write(to: file)
        }
        func rejects(_ label: String, operation: () throws -> Void) {
            do { try operation(); fatalError("Expected rejection: \(label)") } catch { }
        }
        try write([proposal(first), proposal(second)])
        let loaded = try inbox.load()
        precondition(loaded.count == 2 && loaded[0].id == first)
        // A new proposal written after the UI preview survives the reviewed consume.
        try write([proposal(first), proposal(second), proposal(addedLater)])
        try inbox.consume(ids: [first])
        try check(inbox.load().map(\.id) == [second, addedLater])
        try inbox.consume(ids: [first])
        try check(inbox.load().count == 2)
        try write([proposal(first), proposal(first)])
        rejects("duplicate IDs") { _ = try inbox.load() }
        try write([proposal(first, title: "   ")])
        rejects("blank title") { _ = try inbox.load() }
        try write([proposal(first, title: String(repeating: "x", count: 201))])
        rejects("long title") { _ = try inbox.load() }
        try write([proposal(first)], version: 2)
        rejects("unsupported version") { _ = try inbox.load() }
        try write((0..<101).map { _ in proposal(UUID()) })
        rejects("too many proposals") { _ = try inbox.load() }
        try Data(repeating: 32, count: LocalInbox.maximumBytes + 1).write(to: file)
        rejects("large file") { _ = try inbox.load() }
        try Data("broken".utf8).write(to: file)
        rejects("corruption") { try inbox.consume(ids: [first]) }
        try check(String(contentsOf: file) == "broken")
        try FileManager.default.removeItem(at: file)
        let other = directory.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        rejects("symbolic link") { _ = try inbox.load() }
        print("InboxTests: all checks passed")
    }
}
