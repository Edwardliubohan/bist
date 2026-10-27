import SwiftUI

struct NotePane: View {
    @ObservedObject var note: NoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if note.text.isEmpty {
                    Text("Write a note…")
                        .foregroundColor(muted)
                        .padding(.horizontal, 5).padding(.top, 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                TextEditor(text: Binding(get: { note.text }, set: { note.update($0) }))
                    .scrollContentBackground(.hidden)
                    .foregroundColor(ink)
                    .bistTextEntry()
                    .accessibilityLabel("Note")
                    .accessibilityHint("One plain-text note. Changes save automatically on this Mac.")
            }
            .font(.system(size: 13)).lineSpacing(5)
            if let error = note.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    if note.canRetrySave {
                        BistButton("Retry save") { note.save() }
                            .buttonStyle(.plain).foregroundColor(accent)
                    }
                }.font(.system(size: 11)).foregroundColor(ink)
            } else {
                Text("Saved on this Mac").font(.system(size: 10)).foregroundColor(muted)
            }
        }
        .padding(.horizontal, 17).padding(.top, 14).padding(.bottom, 16)
    }
}
