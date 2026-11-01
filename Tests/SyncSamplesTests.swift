import Foundation

@main
struct SyncSamplesTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-sync-samples-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root)
        precondition(store.loadSamples())
        let parent = store.tasks[0]
        precondition(store.addTask(title: "My child", parentID: parent.id))
        let child = store.tasks.last!
        let bridge = try BistReplicaBridge(store: store, note: NoteStore(directory: root))
        precondition(store.tasks.first { $0.id == child.id }?.parentID == parent.id,
                     "A local sample parent still exists on this device and must retain its real child")
        let records = try bridge.database.records()
        precondition(!records.contains { $0.id == "task." + parent.id.uuidString.lowercased() }, "Sample tasks stay local")
        print("PASS local sample hierarchy survives shared storage migration")
    }
}
