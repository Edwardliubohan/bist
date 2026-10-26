import Foundation
import Darwin

@main
struct AgentResultsTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            guard condition else { fatalError("FAIL: \(message)") }
        }
        func rejects(_ label: String, _ operation: () throws -> Void) {
            checks += 1
            do { try operation(); fatalError("Expected rejection: \(label)") }
            catch { }
        }
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-10-26T12:00:00Z")!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bist-agent-results-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = AgentResultsInbox(directory: directory)
        let initial = try inbox.load(now: now)
        expect(initial.isEmpty, "missing directory is an empty inbox")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("agent-results.json")
        let taskID = UUID(), sessionID = UUID()
        let first = UUID(), second = UUID(), addedLater = UUID()
        func result(_ id: UUID, url: String = "https://example.com/output", summary: String = "Review this sample output", date: String = "2026-10-26T11:00:00Z") -> [String: String] {
            ["id": id.uuidString, "taskID": taskID.uuidString,
             "sessionID": sessionID.uuidString, "artifactURL": url,
             "summary": summary, "observedAt": date]
        }
        func write(_ items: [[String: String]], version: Int = 1) throws {
            let data = try JSONSerialization.data(withJSONObject: ["version": version, "results": items], options: [.sortedKeys])
            try data.write(to: file)
        }
        func expectUnchangedAfterRejectedConsume(_ label: String) throws {
            let before = try Data(contentsOf: file)
            rejects(label) { try inbox.consume(ids: [first], now: now) }
            let after = try Data(contentsOf: file)
            expect(after == before, "\(label) preserves original bytes")
        }

        let empty = try inbox.load(now: now)
        expect(empty.isEmpty, "missing result file is empty")
        try inbox.consume(ids: [first], now: now)
        expect(!FileManager.default.fileExists(atPath: file.path), "consuming a missing result does not create an inbox")
        try write([])
        let emptyEnvelope = try inbox.load(now: now)
        expect(emptyEnvelope.isEmpty, "empty versioned envelope is valid")
        try write([result(first), result(second, url: "http://example.com/second", date: "2026-10-26T13:00:00+02:00")])
        let loaded = try inbox.load(now: now)
        expect(loaded.map(\.id) == [first, second], "result order and IDs survive parsing")
        expect(loaded[0].taskID == taskID && loaded[0].sessionID == sessionID, "explicit task and session IDs survive parsing")
        expect(loaded[0].artifactURL == "https://example.com/output", "artifact URL survives parsing")
        expect(loaded[1].observedAt == loaded[0].observedAt, "timezone offsets identify the same observed instant")

        // A proposal arriving after the preview must not be removed by approval.
        try write([result(first), result(second), result(addedLater)])
        try inbox.consume(ids: [first], now: now)
        let remaining = try inbox.load(now: now)
        expect(remaining.map(\.id) == [second, addedLater], "selective consume retains later results")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "consumed inbox remains private to its owner")
        let afterFirstConsume = try Data(contentsOf: file)
        try inbox.consume(ids: [first], now: now)
        let afterRepeatedConsume = try Data(contentsOf: file)
        expect(afterRepeatedConsume == afterFirstConsume, "repeating consume is an idempotent no-op")
        try inbox.consume(ids: [], now: now)
        let afterEmptyConsume = try Data(contentsOf: file)
        expect(afterEmptyConsume == afterFirstConsume, "empty consume does not rewrite inbox")

        try write([result(first), result(second)])
        let previewedProposal = try inbox.load(now: now)[0]
        try write([result(first, summary: "Changed after preview"), result(second), result(addedLater)])
        let changedProposalBytes = try Data(contentsOf: file)
        rejects("reused ID changed after preview") { try inbox.consume(proposal: previewedProposal, now: now) }
        let afterChangedProposal = try Data(contentsOf: file)
        expect(afterChangedProposal == changedProposalBytes, "changed proposal is preserved for another review")
        try write([result(first), result(second), result(addedLater)])
        try inbox.consume(proposal: previewedProposal, now: now)
        let afterExactProposal = try inbox.load(now: now)
        expect(afterExactProposal.map(\.id) == [second, addedLater], "exact proposal consume retains other and later records")
        let exactProposalBytes = try Data(contentsOf: file)
        try inbox.consume(proposal: previewedProposal, now: now)
        let repeatedProposalBytes = try Data(contentsOf: file)
        expect(repeatedProposalBytes == exactProposalBytes, "exact proposal consume retry is idempotent")

        try write([result(first), result(first)])
        rejects("duplicate IDs") { _ = try inbox.load(now: now) }
        try expectUnchangedAfterRejectedConsume("duplicate IDs")
        try write([result(first)], version: 2)
        rejects("unsupported version") { _ = try inbox.load(now: now) }
        try write((0..<101).map { _ in result(UUID()) })
        rejects("too many results") { _ = try inbox.load(now: now) }
        try write((0..<100).map { _ in result(UUID()) })
        let fullEnvelope = try inbox.load(now: now)
        expect(fullEnvelope.count == 100, "100 results are accepted at the documented limit")
        try write([result(first, summary: String(repeating: "x", count: 2001))])
        rejects("oversized summary") { _ = try inbox.load(now: now) }
        for blankSummary in ["", " \n\t", "\u{00A0}"] {
            try write([result(first, summary: blankSummary)])
            rejects("blank output summary") { _ = try inbox.load(now: now) }
            try expectUnchangedAfterRejectedConsume("blank output summary")
        }
        try write([result(first, summary: "  Review this output  ")])
        let paddedSummary = try inbox.load(now: now)
        expect(paddedSummary[0].summary == "  Review this output  ", "nonblank summary retains its exact content")
        try write([result(first, summary: String(repeating: "x", count: 2000))])
        let boundary = try inbox.load(now: now)
        expect(boundary.count == 1, "summary at the documented limit is valid")

        for badURL in ["javascript:alert(1)", "file:///tmp/output", "https:///output", "https://user:password@example.com/output", "https://user@example.com/output", "https://example.com/space here", "https://example.com/line\nbreak", "not a URL"] {
            try write([result(first, url: badURL)])
            rejects("unsafe or incomplete artifact URL") { _ = try inbox.load(now: now) }
        }
        try write([result(first, date: "2026-10-26T12:00:30Z")])
        let slightClockSkew = try inbox.load(now: now)
        expect(slightClockSkew.count == 1, "small clock skew is tolerated")
        try write([result(first, date: "2026-10-26T12:01:01Z")])
        rejects("future observation") { _ = try inbox.load(now: now) }
        try write([result(first, date: "1969-12-31T23:59:59Z")])
        rejects("pre-epoch observation") { _ = try inbox.load(now: now) }
        try write([result(first, date: "1970-01-01T00:00:00Z")])
        let epochEnvelope = try inbox.load(now: now)
        expect(epochEnvelope.count == 1, "Unix epoch boundary is accepted")
        for badDate in ["not a date", "2026-10-26T11:00:00", "2026-99-99T11:00:00Z"] {
            try write([result(first, date: badDate)])
            rejects("invalid observation timestamp") { _ = try inbox.load(now: now) }
        }
        var missingSession = result(first)
        missingSession.removeValue(forKey: "sessionID")
        try write([missingSession])
        rejects("missing session ID") { _ = try inbox.load(now: now) }
        var invalidTask = result(first)
        invalidTask["taskID"] = "not-a-uuid"
        try write([invalidTask])
        rejects("invalid task ID") { _ = try inbox.load(now: now) }

        try Data(repeating: 32, count: 256 * 1024 + 1).write(to: file)
        rejects("oversized file") { _ = try inbox.load(now: now) }
        try expectUnchangedAfterRejectedConsume("oversized file")
        try Data("{unfinished result".utf8).write(to: file)
        rejects("corrupt JSON") { _ = try inbox.load(now: now) }
        try expectUnchangedAfterRejectedConsume("corrupt JSON")

        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("other.json")
        let targetBytes = Data("{\"version\":1,\"results\":[]}".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        rejects("symbolic-link inbox") { _ = try inbox.load(now: now) }
        rejects("symbolic-link consume") { try inbox.consume(ids: [first], now: now) }
        let targetAfter = try Data(contentsOf: target)
        expect(targetAfter == targetBytes, "symbolic-link rejection preserves target bytes")

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        rejects("directory in place of inbox") { _ = try inbox.load(now: now) }
        rejects("directory consume") { try inbox.consume(ids: [first], now: now) }
        try FileManager.default.removeItem(at: file)
        guard mkfifo(file.path, 0o600) == 0 else { fatalError("Could not create test FIFO") }
        rejects("FIFO inbox") { _ = try inbox.load(now: now) }
        rejects("FIFO consume") { try inbox.consume(ids: [first], now: now) }
        try FileManager.default.removeItem(at: file)
        try write([result(first)])
        let lockFile = directory.appendingPathComponent(".agent-results.lock")
        let lockDescriptor = open(lockFile.path, O_RDWR)
        guard lockDescriptor >= 0 else { fatalError("Could not open test lock") }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { fatalError("Could not acquire test lock") }
        rejects("busy inbox load") { _ = try inbox.load(now: now) }
        try expectUnchangedAfterRejectedConsume("busy inbox consume")
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        let afterLockRelease = try inbox.load(now: now)
        expect(afterLockRelease.map(\.id) == [first], "inbox remains readable after contention clears")

        try FileManager.default.removeItem(at: lockFile)
        guard mkfifo(lockFile.path, 0o600) == 0 else { fatalError("Could not create test lock FIFO") }
        rejects("FIFO lock") { _ = try inbox.load(now: now) }
        try expectUnchangedAfterRejectedConsume("FIFO lock consume")
        try FileManager.default.removeItem(at: lockFile)
        try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: target)
        rejects("symbolic-link lock") { _ = try inbox.load(now: now) }
        try expectUnchangedAfterRejectedConsume("symbolic-link lock consume")

        // Exercise the public producer against isolated bytes and the native
        // parser. It must never inspect or mutate an actual user store.
        let cliDirectory = directory.appendingPathComponent("cli")
        let cliFile = cliDirectory.appendingPathComponent("agent-results.json")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/bist-result.py")
        let cliID = UUID().uuidString
        let arguments = [script.path, "--task-id", taskID.uuidString,
                         "--session-id", sessionID.uuidString, "--id", cliID,
                         "--artifact-url", "https://example.com/output", "--summary", "Reviewed sample",
                         "--observed-at", "2020-01-01T01:02:03.123+00:00", "--data-dir", cliDirectory.path]
        func runCLI(_ values: [String], succeeds: Bool) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3"] + values
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { process.waitUntilExit(); finished.signal() }
            guard finished.wait(timeout: .now() + 7) == .success else {
                process.terminate()
                fatalError("CLI blocked instead of returning")
            }
            expect((process.terminationStatus == 0) == succeeds, "CLI returns expected success or rejection")
        }
        try runCLI(arguments, succeeds: true)
        let cliInbox = AgentResultsInbox(directory: cliDirectory)
        let cliResult = try cliInbox.load()
        expect(cliResult.count == 1 && cliResult[0].taskID == taskID && cliResult[0].sessionID == sessionID,
               "CLI output is readable by the native parser with exact task/session provenance")
        expect(cliResult[0].observedAt == formatter.date(from: "2020-01-01T01:02:03Z"), "CLI normalizes fractions to native whole-second UTC")
        let originalCLIBytes = try Data(contentsOf: cliFile)
        try runCLI(arguments, succeeds: true)
        expect(try Data(contentsOf: cliFile) == originalCLIBytes, "CLI exact-ID retry does not rewrite the inbox")
        var changedCLI = arguments
        changedCLI[changedCLI.firstIndex(of: "--summary")! + 1] = "Changed content"
        try runCLI(changedCLI, succeeds: false)
        expect(try Data(contentsOf: cliFile) == originalCLIBytes, "CLI rejects a changed result with the same ID")
        for blankSummary in ["", " \n\t", "\u{00A0}"] {
            var blankCLI = arguments
            blankCLI[blankCLI.firstIndex(of: "--summary")! + 1] = blankSummary
            try runCLI(blankCLI, succeeds: false)
            expect(try Data(contentsOf: cliFile) == originalCLIBytes, "CLI blank summary leaves the queue unchanged")
        }
        let blankQueueBytes = Data(String(data: originalCLIBytes, encoding: .utf8)!
            .replacingOccurrences(of: "Reviewed sample", with: "   ").utf8)
        try blankQueueBytes.write(to: cliFile)
        try runCLI(arguments, succeeds: false)
        expect(try Data(contentsOf: cliFile) == blankQueueBytes, "CLI preserves an existing invalid blank-summary queue")
        try originalCLIBytes.write(to: cliFile)
        var unsafeCLI = arguments
        unsafeCLI[unsafeCLI.firstIndex(of: "--artifact-url")! + 1] = "https://account:secret@example.com/output"
        try runCLI(unsafeCLI, succeeds: false)
        expect(try Data(contentsOf: cliFile) == originalCLIBytes, "CLI unsafe URL does not mutate the queue")
        var futureCLI = arguments
        futureCLI[futureCLI.firstIndex(of: "--observed-at")! + 1] = "2099-01-01T00:00:00Z"
        try runCLI(futureCLI, succeeds: false)
        expect(try Data(contentsOf: cliFile) == originalCLIBytes, "CLI future date does not mutate the queue")
        let invalidDateBytes = Data(String(data: originalCLIBytes, encoding: .utf8)!
            .replacingOccurrences(of: "2020-01-01T01:02:03Z", with: "2020-01-01 01:02:03Z").utf8)
        try invalidDateBytes.write(to: cliFile)
        try runCLI(arguments, succeeds: false)
        expect(try Data(contentsOf: cliFile) == invalidDateBytes, "CLI preserves an envelope with a native-incompatible date")
        let corruptCLIBytes = Data("{invalid queue".utf8)
        try corruptCLIBytes.write(to: cliFile)
        try runCLI(arguments, succeeds: false)
        expect(try Data(contentsOf: cliFile) == corruptCLIBytes, "CLI preserves corrupt input")
        try FileManager.default.removeItem(at: cliFile)
        guard mkfifo(cliFile.path, 0o600) == 0 else { fatalError("Could not create CLI test FIFO") }
        try runCLI(arguments, succeeds: false)
        try FileManager.default.removeItem(at: cliFile)
        try FileManager.default.createSymbolicLink(at: cliFile, withDestinationURL: target)
        try runCLI(arguments, succeeds: false)
        expect(try Data(contentsOf: target) == targetBytes, "CLI never follows the inbox symlink")
        try FileManager.default.removeItem(at: cliFile)
        let cliLock = open(cliDirectory.appendingPathComponent(".agent-results.lock").path, O_RDWR)
        guard cliLock >= 0, flock(cliLock, LOCK_EX | LOCK_NB) == 0 else { fatalError("Could not acquire CLI test lock") }
        try runCLI(arguments, succeeds: false)
        flock(cliLock, LOCK_UN); close(cliLock)
        expect(!FileManager.default.fileExists(atPath: cliFile.path), "CLI lock rejection creates no inbox")
        print("PASS: \(checks) agent-results inbox checks")
    }
}
