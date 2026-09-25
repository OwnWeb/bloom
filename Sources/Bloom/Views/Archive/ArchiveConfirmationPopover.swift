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
    @FocusState private var focusedButton: ButtonFocus?

    private enum ButtonFocus: Hashable { case cancel, archive }

    private var currentRequest: ArchiveRequest {
        guard let checkedRequest, checkedRequest.id == request.id else { return request }
        return checkedRequest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Archive this workspace?")
                    .font(.headline)
                Spacer(minLength: 0)
                if request.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(currentRequest.isChecking ? 1 : 0)
                        .accessibilityLabel("Checking for unsaved work")
                        .accessibilityHidden(!currentRequest.isChecking)
                }
            }

            // The safety report can grow after the popover opens. A fixed reading area keeps the
            // arrow, title and buttons still, while long reports remain readable by scrolling.
            ScrollView {
                Text(currentRequest.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: 160)
            .padding(.top, 14)

            Divider()
                .padding(.top, 12)
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(width: 58)
                }
                .buttonStyle(.bordered)
                .focused($focusedButton, equals: .cancel)
                .keyboardShortcut(.cancelAction)
                Button {
                    guard canConfirm else { return }
                    onConfirm(currentRequest)
                } label: {
                    Text(currentRequest.confirmLabel)
                        .frame(width: 196)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .focused($focusedButton, equals: .archive)
                .disabled(!canConfirm)
            }
        }
        .environment(\.backgroundProminence, .standard)
        .environment(\.isOnEmphasizedSelection, false)
        .foregroundStyle(Palette.textPrimary)
        .font(.body)
        .padding(20)
        .frame(width: 380)
        .defaultFocus($focusedButton, .cancel)
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
