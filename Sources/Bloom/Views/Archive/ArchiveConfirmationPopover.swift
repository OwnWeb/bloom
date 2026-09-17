import SwiftUI
import BloomCore

struct ArchiveConfirmationPopover: View {
    let request: ArchiveRequest
    var canConfirm = true
    var tint: Color = Palette.controlAccent
    let onConfirm: (ArchiveRequest) -> Void
    let onCancel: () -> Void

    @Environment(AppModel.self) private var app
    @State private var checkedRequest: ArchiveRequest?

    private var currentRequest: ArchiveRequest {
        guard let checkedRequest, checkedRequest.id == request.id else { return request }
        return checkedRequest
    }

    var body: some View {
        ConfirmationPopover(
            title: "Archive this workspace?",
            confirmLabel: currentRequest.confirmLabel,
            tint: tint,
            canConfirm: canConfirm,
            onConfirm: { onConfirm(currentRequest) },
            onCancel: onCancel,
            width: 380
        ) {
            if currentRequest.isChecking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking for unsaved work…")
                }
            }
            ViewThatFits(in: .vertical) {
                Text(currentRequest.message).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(currentRequest.message).frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: 440)
        }
        .task(id: request.id) {
            guard request.isChecking else { return }
            let checked = await app.checkArchive(request)
            guard !Task.isCancelled else { return }
            checkedRequest = checked
        }
    }

}

extension View {
    /// Attach this to the initiating control, which stays in the hierarchy until dismissal.
    ///
    /// `tint` is the initiating control's own colour where it has one, so the confirm button
    /// matches the button that opened it. The pull request strip's Archive is the merged band's
    /// purple; a sidebar row has no coloured control and keeps the accent.
    func archiveConfirmation(
        _ request: Binding<ArchiveRequest?>,
        arrowEdge: Edge = .top,
        canConfirm: Bool = true,
        tint: Color = Palette.controlAccent,
        onConfirm: @escaping (ArchiveRequest) -> Void
    ) -> some View {
        popover(item: request, arrowEdge: arrowEdge) { value in
            ArchiveConfirmationPopover(
                request: value,
                canConfirm: canConfirm,
                tint: tint,
                onConfirm: { confirmed in
                    request.wrappedValue = nil
                    onConfirm(confirmed)
                },
                onCancel: { request.wrappedValue = nil }
            )
        }
    }
}
