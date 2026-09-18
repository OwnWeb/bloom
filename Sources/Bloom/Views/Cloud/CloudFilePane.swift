import BloomCore
import SwiftUI

/// A file of a Cloud workspace that nobody changed, read from its machine.
///
/// The review shows this where a local workspace shows the file with its editor: the text is the
/// machine's, read once and held (`CloudChanges.contents`), and there is nothing to edit here,
/// which `.editFiles` already says everywhere a control would offer it.
struct CloudFilePane: View {
    var session: CloudWorkspaceSession
    var path: String

    var body: some View {
        Group {
            if let text = session.contents(of: path) {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.gutter)
                }
            } else {
                // The first ask starts the read and answers nothing, and the pane comes back when
                // it lands. See `CloudChanges.contents(of:)`.
                LoadingView("Reading \((path as NSString).lastPathComponent)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.codeBackground)
    }
}

extension CloudWorkspaceSession {
    func filePane(path: String) -> CloudFilePane {
        CloudFilePane(session: self, path: path)
    }
}
