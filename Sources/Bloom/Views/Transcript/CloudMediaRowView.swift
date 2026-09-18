import BloomCore
import SwiftUI

/// A picture an agent on a Bloom Cloud machine showed, drawn the way a local `media_show` is.
///
/// **The same view, once the file is here.** A local row resolves a path on this Mac's disk; a
/// machine's row names a copy on the machine, so this fetches it through the workspace's own
/// `download` and then hands `MediaShowRowView` a file that is on this disk after all. What a
/// reader sees is the same caption, the same picture or player, the same name and menu under it,
/// whichever kind of workspace it came from. See `CloudChatLink.media`.
///
/// While it comes, the caption is already there and the picture's place is held by a line saying
/// so, rather than by nothing that then grows. A picture that cannot be fetched says why, with a
/// way to ask again, because the likeliest reason is a machine that was asleep.
struct CloudMediaRowView: View {
    var media: SharedMedia
    var home: TranscriptHome
    var link: CloudChatLink?

    private enum Load: Equatable {
        case loading
        case loaded(URL)
        case failed(String)
    }

    @State private var load: Load = .loading
    @State private var attempt = 0

    var body: some View {
        Group {
            switch load {
            case .loaded(let url):
                MediaShowRowView(
                    request: MediaShowRequest(path: media.path, caption: media.caption),
                    home: home,
                    source: .fetched(WorkspaceMedia(
                        url: url, relativePath: media.name,
                        kind: WorkspaceMediaKind(rawValue: media.kind) ?? .image
                    ))
                )
            case .loading, .failed:
                waiting
            }
        }
        .task(id: attempt) { await fetch() }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: TranscriptLayout.block) {
            if !media.caption.isEmpty {
                Text(media.caption)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .proseLeading()
                    .textSelection(.enabled)
            }
            HStack(spacing: Metrics.spacing) {
                if case .failed(let reason) = load {
                    Label("\(media.name) could not be fetched from the machine. \(reason)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Palette.textSecondary)
                    Button("Try Again") { attempt += 1 }
                        .linkButton()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Fetching \(media.name) from the machine…")
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .font(Typo.caption)
            .padding(TranscriptLayout.block)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        }
        .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.block)
    }

    private func fetch() async {
        guard let link else {
            load = .failed("This transcript is not connected to its machine.")
            return
        }
        load = .loading
        switch await link.media(media) {
        case .success(let url): load = .loaded(url)
        case .failure(let trouble): load = .failed(trouble.sentence)
        }
    }
}
