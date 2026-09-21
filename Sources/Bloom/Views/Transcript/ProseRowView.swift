import SwiftUI

/// Shared by live and saved messages so their boundaries do not move when streaming finishes.
struct ProseRowView: View {
    var text: String
    var isStreaming = false
    /// Present only on the response that closes a completed turn.
    var copyText: String?

    var body: some View {
        HStack(alignment: .top, spacing: TranscriptLayout.block) {
            MarkdownView(text, isStreaming: isStreaming)
                .font(Typo.body)
                .proseLeading()
                .textSelection(.enabled)
                // Capped, then left aligned in whatever is left. One frame would centre the column
                // in a wide pane and take the paragraph off the line every other row starts on.
                .frame(maxWidth: TranscriptLayout.proseMeasure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The slot stays present while streaming and on intermediate prose, so completion
            // reveals a control without narrowing the response and changing its line breaks.
            Group {
                if let copyText, !copyText.isEmpty {
                    CopyButton(
                        text: copyText,
                        title: "Copy this answer",
                        size: 18,
                        imageScale: .small
                    )
                } else {
                    Color.clear
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 18, height: 18)
        }
        .padding(.horizontal, TranscriptLayout.inset)
        // The old rule occupied this boundary. Two clean rungs preserve the separation without
        // putting a hard line between the work and the response.
        .padding(.top, TranscriptLayout.block * 2)
        .padding(.bottom, TranscriptLayout.block)
    }
}
