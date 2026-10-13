import AppKit
import SwiftUI
import BloomCore

/// A browser in a project-free conversation. It keeps the same BrowserSession and web view across
/// tab switches, while its last address is part of the conversation's saved pane layout.
struct ConversationBrowserPane: View {
    let state: ConversationPaneState
    let tabID: ConversationPaneID
    let pane: ConversationLayout.Pane
    let isSplit: Bool

    @Environment(AppModel.self) private var app
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private var session: BrowserSession? { state.browser(for: pane.id) }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    HStack(spacing: Metrics.spacingSmall) {
                        Button("Back", systemImage: "chevron.left") { session.goBack() }
                            .disabled(!session.canGoBack)
                        Button("Forward", systemImage: "chevron.right") { session.goForward() }
                            .disabled(!session.canGoForward)
                        TextField("Address", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .focused($addressFocused)
                            .onSubmit {
                                session.load(address)
                                addressFocused = false
                            }
                        Button(session.isLoading ? "Stop" : "Reload",
                               systemImage: session.isLoading ? "xmark" : "arrow.clockwise") {
                            if session.isLoading {
                                session.webView.stopLoading()
                            } else {
                                session.reload()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Metrics.spacingWide)
                    .frame(height: Metrics.barHeight)
                    Hairline()
                    ZStack {
                        BrowserViewportView(
                            session: session,
                            paneMenu: hostedMenu,
                            host: BrowserPaneHost(
                                openTab: { state.open(.browser, url: $0.absoluteString) },
                                report: { app.alert = BloomAlert(title: $0.title, message: $0.message) }
                            )
                        )
                        if let failure = session.failure {
                            EmptyStateView(
                                glyph: "exclamationmark.triangle",
                                title: failure.title,
                                message: failure.message,
                                actionTitle: "Try again",
                                action: { session.reload() }
                            )
                            .background(Palette.surface)
                        } else if session.currentURL == nil {
                            EmptyStateView(
                                glyph: "globe",
                                title: "No page yet",
                                message: "Type an address above."
                            )
                            .background(Palette.surface)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onChange(of: session.page, initial: true) { _, page in
                    state.updatePage(page, paneID: pane.id, tabID: tabID)
                    if !addressFocused { address = session.displayAddress }
                }
            } else {
                LoadingView("Opening a browser")
                    .task(id: pane.id) { state.prepareBrowser(pane) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }

    private func hostedMenu() -> NSMenu {
        NSHostingMenu(rootView: CenterPaneMenu(
            isSplit: isSplit,
            split: { axis, kind in
                state.split(tabID: tabID, paneID: pane.id, axis: axis, kind: kind.conversationKind)
            },
            close: { state.closePane(tabID: tabID, paneID: pane.id) }
        ))
    }
}

extension PaneKind {
    var conversationKind: ConversationLayout.Kind {
        switch self {
        case .chat: .chat
        case .terminal: .terminal
        case .browser: .browser
        }
    }
}
