import SwiftUI
import BloomCore

/// The saved transcript of a conversation that has no project or worktree.
struct ArchivedConversationView: View {
    let sessionID: SessionID

    @Environment(AppModel.self) private var app
    @State private var transcript: TranscriptModel?
    @State private var title = "Conversation"
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.spacingWide) {
                Text(title)
                    .font(Typo.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Restore") { Task { await app.ask.restore(sessionID) } }
                Button("Delete…", role: .destructive) { isConfirmingDelete = true }
            }
            .padding(Metrics.gutter)
            .background(Palette.sidebar)
            Hairline()
            TranscriptView(transcript: transcript)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: sessionID) { await load() }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Conversation", role: .destructive) {
                Task { await app.ask.deleteArchived(sessionID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript will be removed. Files in its folder are removed when no other conversation uses them.")
        }
    }

    private func load() async {
        guard let store = app.store,
              let session = try? await store.session(id: sessionID),
              session.archivedAt != nil else { return }
        title = session.title
        let saved = try? await store.setting(AskTabs.directoryKey(sessionID))
        guard let directory = AskTabs.prepareDirectory(saved ?? "", databasePath: store.path) else {
            return
        }
        let model = TranscriptModel(askSession: session, directory: directory, app: app)
        transcript = model
        await model.load()
    }
}
