import AppKit
import SwiftUI

struct BobotAssignment: View {
    let task: TaskItem
    @EnvironmentObject private var bobot: BobotStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let job = bobot.latest(for: task.id), !job.terminal {
                Text(job.status).font(.system(size: 11)).foregroundColor(accent)
                Text("Follow this task in Sessions.").font(.system(size: 10)).foregroundColor(muted)
            } else {
                if let job = bobot.latest(for: task.id), job.state == "completed" {
                    Text("Agent done · ready for your review").font(.system(size: 11)).foregroundColor(accent)
                    if let result = job.result {
                        Text(result).font(.system(size: 10)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let link = job.resultURL, let url = AppStore.safeURL(link) {
                        Link("Open output", destination: url).font(.system(size: 10)).foregroundColor(accent)
                    }
                    Text("Check Me when you’ve reviewed and finished your part.")
                        .font(.system(size: 10)).foregroundColor(muted)
                }
                BistButton("Ask Bobot to do this") { _ = bobot.assign(task) }
                    .buttonStyle(TactileStyle(compact: true)).font(.system(size: 11))
                Text(bobot.connected ? "Sends the saved task name and details to Bobot." : "Queues this task. Connect Bobot in Sessions to start work.")
                    .font(.system(size: 10)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            }
            if let error = bobot.error { Text(error).font(.system(size: 10)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct BobotQuestionView: View {
    let jobID: String
    @ObservedObject var bobot: BobotStore
    let close: () -> Void
    private var job: BobotJob? { bobot.jobs.first { $0.id == jobID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bobot has a question").font(.system(size: 16, weight: .semibold))
            if let job, let question = job.pendingQuestion {
                Text(job.title).font(.system(size: 11)).foregroundColor(muted).lineLimit(2)
                ScrollView { Text(question.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
                TextField("Your answer", text: Binding(get: { bobot.questionDrafts[question.id] ?? "" }, set: { bobot.questionDrafts[question.id] = $0 }), axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.plain).font(.system(size: 12)).bistTextEntry()
                    .padding(8).background(surfaceHighlight.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Answer Bobot")
                if let error = bobot.error { Text(error).font(.system(size: 10)).foregroundColor(.red) }
                if (bobot.questionDrafts[question.id] ?? "").count > 8000 { Text("Keep your answer under 8,000 characters.").font(.system(size: 10)).foregroundColor(.red) }
                HStack {
                    BistButton("Later", action: close).buttonStyle(.plain).foregroundColor(muted)
                    Spacer()
                    BistButton("Answer and continue") {
                        if bobot.answer(jobID: job.id, questionID: question.id, text: bobot.questionDrafts[question.id] ?? "") {
                            bobot.questionDrafts.removeValue(forKey: question.id); close()
                        }
                    }.buttonStyle(TactileStyle(prominent: true, compact: true))
                        .disabled((bobot.questionDrafts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (bobot.questionDrafts[question.id] ?? "").count > 8000)
                }.font(.system(size: 11))
            } else {
                Text("This question has already been answered or the task has stopped.").font(.system(size: 12))
                BistButton("Close", action: close).buttonStyle(.plain).foregroundColor(accent)
            }
        }.padding(20).frame(width: 320).foregroundColor(ink).background(ivory).tint(accent)
    }
}

struct BobotJobDetail: View {
    let job: BobotJob
    @ObservedObject var bobot: BobotStore
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(job.title).font(.system(size: 13, weight: .semibold))
            Text(job.status).font(.system(size: 11)).foregroundColor(accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !job.details.isEmpty { Text(job.details).foregroundColor(muted) }
                    ForEach(job.questions) { q in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(q.text).fontWeight(.medium)
                            if let answer = q.answer { Text(answer).foregroundColor(muted) }
                        }
                    }
                    if let result = job.result { Text(result) }
                    if let link = job.resultURL, let url = AppStore.safeURL(link) {
                        Link("Open output", destination: url).foregroundColor(accent)
                    }
                }.font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.background(OverlayScrollStyle())
            if job.pendingQuestion != nil {
                BistButton("Answer Bobot") { bobot.requestedQuestionID = job.id }.buttonStyle(TactileStyle(prominent: true, compact: true))
            }
            if !job.terminal {
                BistButton("Cancel assignment") { _ = bobot.cancel(job.id) }.buttonStyle(.plain).foregroundColor(muted).font(.system(size: 11))
                Text("Cancellation tells Bobot to stop at its next status check. Actions already taken remain.")
                    .font(.system(size: 10)).foregroundColor(muted)
            }
            if let error = bobot.error { Text(error).font(.system(size: 10)).foregroundColor(.red) }
        }
    }
}

struct BobotSetup: View {
    @ObservedObject var bobot: BobotStore
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(bobot.connected ? "Bobot connected" : "Connect Bobot").font(.system(size: 12, weight: .semibold))
            Text(bobot.connected ? "Assignments and answers notify your ChatGPT dot." : "Connect bist as a private ChatGPT plugin, then ask Bobot to watch assigned tasks. Queued tasks stay here until connected.")
                .font(.system(size: 11)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                BistButton("Setup guide") {
                    if let url = Bundle.main.url(forResource: "BOBOT", withExtension: "md") { NSWorkspace.shared.open(url) }
                }.buttonStyle(.plain).foregroundColor(accent)
                BistButton(copied ? "Copied" : "Copy bridge command") {
                    guard let script = Bundle.main.url(forResource: "bist-bobot", withExtension: "py") else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("python3 " + LocalSessionConnection.shellQuote(script.path) + " --data-dir " + LocalSessionConnection.shellQuote(bobot.directory.path), forType: .string)
                    copied = true
                }.buttonStyle(.plain).foregroundColor(accent)
            }.font(.system(size: 11))
        }.padding(.vertical, 9)
    }
}
