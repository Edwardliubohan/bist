import Foundation

@main
struct SyncOrderTests {
    struct Failure: Error { let names: [String] }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-sync-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        var failures: [String] = []
        func expect(_ value: Bool, _ name: String) { checks += 1; if !value { failures.append(name) } }
        func make(_ name: String) throws -> (AppStore, BistReplicaBridge) {
            let store = AppStore(directory: root.appendingPathComponent(name))
            return (store, try BistReplicaBridge(store: store, note: NoteStore(directory: store.directory)))
        }
        func exchange(_ left: BistReplicaBridge, _ right: BistReplicaBridge) throws {
            let a = try left.database.records(), b = try right.database.records()
            try left.receive(b); try right.receive(a)
        }
        for iteration in 0..<20 {
            let (mac, mb) = try make("append-mac-\(iteration)")
            for title in ["A", "B", "C", "D", "E"] { precondition(mac.addTask(title: title)) }
            let (phone, pb) = try make("append-phone-\(iteration)")
            try pb.receive(mb.database.records())
            precondition(mac.deleteTask(id: mac.tasks[0].id))
            precondition(mac.deleteTask(id: mac.tasks[0].id))
            precondition(phone.addTask(title: "F"))
            try exchange(mb, pb)
            precondition(phone.addTask(title: "G"))
            let intended = phone.tasks.map(\.id)
            try pb.reload()
            expect(phone.tasks.map(\.id) == intended, "append after concurrent order gaps survives reload \(iteration)")
            try mb.receive(pb.database.records())
            expect(mac.tasks.map(\.id) == intended, "append after gaps matches on peer \(iteration)")
        }
        let (moving, movingBridge) = try make("moving")
        for title in ["A", "B", "C", "D", "E", "F"] { precondition(moving.addTask(title: title)) }
        let (peer, peerBridge) = try make("moving-peer")
        try peerBridge.receive(movingBridge.database.records())
        for _ in 0..<3 { precondition(moving.deleteTask(id: moving.tasks[0].id)) }
        for title in ["G", "H", "I"] { precondition(peer.addTask(title: title)) }
        try exchange(movingBridge, peerBridge)
        let i = peer.tasks.first { $0.title == "I" }!.id
        let h = peer.tasks.first { $0.title == "H" }!.id
        precondition(peer.moveTask(id: i, to: .before(h)))
        let intendedMove = peer.tasks.map(\.id)
        try exchange(movingBridge, peerBridge)
        expect(peer.tasks.map(\.id) == intendedMove && moving.tasks.map(\.id) == intendedMove, "moving across gaps preserves untouched siblings on both replicas")

        let (tags, tagsBridge) = try make("tags")
        for name in ["T1", "T2", "T3"] { precondition(tags.addLabel(name: name, color: .blue)) }
        let (tagPeer, tagPeerBridge) = try make("tags-peer")
        try tagPeerBridge.receive(tagsBridge.database.records())
        for name in ["School", "Class", "Koan"] { precondition(tags.deleteLabel(id: tags.labels.first { $0.name == name }!.id)) }
        precondition(tagPeer.addLabel(name: "P1", color: .rose))
        try exchange(tagsBridge, tagPeerBridge)
        precondition(tagPeer.addLabel(name: "P2", color: .rose))
        let intendedTags = tagPeer.labels.map(\.id)
        try tagPeerBridge.reload()
        try tagsBridge.receive(tagPeerBridge.database.records())
        expect(tags.labels.map(\.id) == intendedTags && tagPeer.labels.map(\.id) == intendedTags, "tag append after gaps survives reload and sync")

        let (samples, samplesBridge) = try make("samples")
        precondition(samples.loadSamples())
        precondition(samples.addTask(title: "Real1"))
        let (samplePeer, samplePeerBridge) = try make("samples-peer")
        try samplePeerBridge.receive(samplesBridge.database.records())
        precondition(samplePeer.addTask(title: "Real2"))
        let intendedReal = samplePeer.tasks.map(\.id)
        try samplePeerBridge.reload()
        try samplesBridge.receive(samplePeerBridge.database.records())
        expect(samplePeer.tasks.map(\.id) == intendedReal, "local samples never offset portable task order")
        expect(samples.tasks.filter { !$0.isSample }.map(\.id) == intendedReal, "portable order stays identical with samples on only one replica")
        let sampleOrder = samples.tasks.map(\.id)
        try samplesBridge.reload()
        expect(samples.tasks.map(\.id) == sampleOrder, "unchanged local sample arrangement survives reload")
        if !failures.isEmpty { throw Failure(names: failures) }
        print("PASS \(checks) concurrent order-gap and sample regressions")
    }
}
