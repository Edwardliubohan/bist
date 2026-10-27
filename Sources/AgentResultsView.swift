import SwiftUI
import AppKit

@MainActor
struct AgentResultsView: View {
    @ObservedObject var store: AppStore
    let directory: URL
    let close: () -> Void
    @State private var results: [AgentResultProposal] = []
    @State private var reviewed = Set<UUID>()
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BistButton(action: close) { Label("Back", systemImage: "chevron.left").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(accent)
                Spacer()
                BistButton("Reload", action: load).buttonStyle(.plain).font(.system(size: 11)).foregroundColor(muted)
            }
            Text("Review agent results").font(.system(size: 18, weight: .medium))
            Text("Local submissions need your review. No live adapter is connected; a submitted file does not prove completion.")
                .font(.system(size: 11)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            if !loaded { ProgressView().controlSize(.small) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loaded && results.isEmpty && error == nil {
                        Text("No submitted results.\nLink a task to a saved session before reviewing an output.")
                            .font(.system(size: 12)).foregroundColor(muted).padding(.top, 20)
                    }
                    ForEach(results) { result in resultRow(result) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("“Agent done” records your reviewed output. It never changes “I’m done” or reports a running agent.")
                .font(.system(size: 10)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 20).padding(.bottom, 20).onAppear(perform: load)
    }

    private func resultRow(_ result: AgentResultProposal) -> some View {
        let task = store.tasks.first { $0.id == result.taskID }
        let session = store.sessions.first { $0.id == result.sessionID }
        let mismatch = validationMessage(result, task: task, session: session)
        let alreadyReviewed = matchingCompletion(result, task: task)
        return VStack(alignment: .leading, spacing: 8) {
            Text(task?.title ?? "Task not found").font(.system(size: 12, weight: .semibold)).lineLimit(2)
            Text(session.map { "\($0.provider.displayName) · \($0.title)" } ?? "Session not found")
                .font(.system(size: 10)).foregroundColor(muted).lineLimit(2)
            Text("Task \(result.taskID.uuidString.prefix(8)) · Session \(result.sessionID.uuidString.prefix(8))")
                .font(.system(size: 9)).foregroundColor(muted)
            if !result.summary.isEmpty { Text(result.summary).font(.system(size: 11)).textSelection(.enabled).lineLimit(8) }
            if let url = AgentResultsInbox.safeURL(result.artifactURL) {
                BistButton { NSWorkspace.shared.open(url) } label: {
                    Label("Review output at \(url.host ?? "source")", systemImage: "arrow.up.right")
                        .font(.system(size: 11)).lineLimit(1)
                }.buttonStyle(.plain).foregroundColor(accent).help(result.artifactURL)
                    .accessibilityLabel("Review output: \(result.artifactURL)")
            }
            Text("Submitted observation: \(result.observedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 9)).foregroundColor(muted)
            if let mismatch { Text(mismatch).font(.system(size: 10)).foregroundColor(.red) }
            if alreadyReviewed {
                Text("This exact result is already reviewed.").font(.system(size: 10)).foregroundColor(muted)
                BistButton("Remove queued copy") { removeReviewedCopy(result) }
                    .buttonStyle(TactileStyle(compact: true)).disabled(mismatch != nil)
            } else {
                BistButton {
                    if reviewed.contains(result.id) { reviewed.remove(result.id) }
                    else { reviewed.insert(result.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: reviewed.contains(result.id) ? "checkmark.square.fill" : "square")
                            .foregroundColor(reviewed.contains(result.id) ? accent : muted)
                        Text("I reviewed this output")
                    }.font(.system(size: 11)).padding(.vertical, 3)
                }.buttonStyle(.plain).disabled(mismatch != nil)
                    .accessibilityLabel("I reviewed this output")
                    .accessibilityValue(reviewed.contains(result.id) ? "Checked" : "Unchecked")
                BistButton("Mark agent done") { accept(result) }
                    .buttonStyle(TactileStyle(prominent: true, compact: true))
                    .disabled(!reviewed.contains(result.id) || mismatch != nil)
                    .opacity(reviewed.contains(result.id) && mismatch == nil ? 1 : 0.5)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.30), in: RoundedRectangle(cornerRadius: 10))
    }

    private func matchingCompletion(_ result: AgentResultProposal, task: TaskItem?) -> Bool {
        guard let completion = task?.agentCompletion else { return false }
        return completion.id == result.id && completion.sessionID == result.sessionID &&
            completion.artifactURL == result.artifactURL && completion.summary == result.summary &&
            completion.observedAt == result.observedAt
    }

    private func validationMessage(_ result: AgentResultProposal, task: TaskItem?, session: SessionItem?) -> String? {
        guard !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "This result needs a nonblank output summary before it can be reviewed."
        }
        guard let task else { return "The referenced task no longer exists. This result cannot be applied." }
        guard session != nil else { return "The referenced session no longer exists. This result cannot be applied." }
        guard task.linkedSessionID == result.sessionID else { return "The task is not linked to this session. Check its task details first." }
        if task.agentCompletion != nil && !matchingCompletion(result, task: task) {
            return "The task already has different reviewed evidence. Clear it explicitly in task details before replacing it."
        }
        return nil
    }

    private func accept(_ result: AgentResultProposal) {
        guard reviewed.contains(result.id) else { return }
        let task = store.tasks.first { $0.id == result.taskID }
        let session = store.sessions.first { $0.id == result.sessionID }
        guard validationMessage(result, task: task, session: session) == nil else {
            error = validationMessage(result, task: task, session: session); return
        }
        if matchingCompletion(result, task: task) { consume(result); return }
        let completion = AgentCompletion(id: result.id, sessionID: result.sessionID, artifactURL: result.artifactURL,
                                         summary: result.summary, observedAt: result.observedAt, reviewedAt: Date())
        guard store.recordAgentCompletion(completion, taskID: result.taskID) else {
            error = store.storeError ?? "The task changed before this result could be saved. Reload and review it again."
            return
        }
        consume(result)
    }

    private func consume(_ result: AgentResultProposal) {
        do {
            try AgentResultsInbox(directory: directory).consume(proposal: result)
            reviewed.remove(result.id)
            load()
        } catch {
            self.error = "The reviewed result is saved. The queue could not be finalized; reload before retrying. \(error.localizedDescription)"
        }
    }

    private func removeReviewedCopy(_ result: AgentResultProposal) {
        let task = store.tasks.first { $0.id == result.taskID }
        let session = store.sessions.first { $0.id == result.sessionID }
        guard matchingCompletion(result, task: task), validationMessage(result, task: task, session: session) == nil else {
            error = "The task or reviewed result changed. Reload before removing this queued copy."
            return
        }
        consume(result)
    }

    private func load() {
        do {
            results = try AgentResultsInbox(directory: directory).load()
            // A file may reuse an ID with changed content. Reload always asks
            // for fresh review rather than carrying an earlier checkbox over.
            reviewed = []
            error = nil
        } catch {
            results = []
            reviewed = []
            self.error = error.localizedDescription
        }
        loaded = true
    }
}
