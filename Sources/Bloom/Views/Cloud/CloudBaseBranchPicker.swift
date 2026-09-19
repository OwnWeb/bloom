import BloomClient
import BloomCore
import SwiftUI

/// "from main" in the Bloom Cloud create sheet: the branch the new one is cut from, picked from a
/// searchable list, or typed.
///
/// **The local sheet's picker, one route of it.** A Bloom Cloud workspace is always a new branch
/// cut from a base, so there are no tabs and no pull requests; everything else is
/// `WorkspaceSourcePicker`'s: the same button, the same popover width and list height, the same
/// search row, the same "New branch from" rows drawn by `WorkspaceSourceRow`, and the same arrow
/// keys, Return and Escape. The two sheets are meant to feel like one control.
///
/// **Loaded when it opens, searched on runbloom.app's side.** A repository can have thousands of
/// branches and this Mac has no clone of it, so the list asks as the field settles and pages on
/// "Show more". What it offers, and in what order, is `CloudBaseBranches`, in BloomClient where it
/// is tested; a name that is typed and not listed is still a row, because a branch pushed a
/// moment ago may not be listed yet.
struct CloudBaseBranchPicker: View {
    var defaultBranch: String
    /// What is chosen now, which the button reports. Empty is the default branch.
    @Binding var baseBranch: String
    /// One page of branches for a search, from runbloom.app. See `CloudWorkspaces.branches`.
    var load: @MainActor (_ query: String, _ cursor: String?) async throws -> (names: [String], next: String?)

    @State private var isPresented = false
    @State private var query = ""
    @State private var list = CloudBaseBranches(defaultBranch: "")
    @State private var selected: String?

    /// `WorkspaceSourcePicker`'s measures, so the two panels are the same size.
    private static let width: CGFloat = 460
    private static let listHeight: CGFloat = 320

    private var base: String { baseBranch.isEmpty ? defaultBranch : baseBranch }

    var body: some View {
        Button {
            query = ""
            list = CloudBaseBranches(defaultBranch: defaultBranch)
            selected = defaultBranch.isEmpty ? nil : defaultBranch
            isPresented = true
        } label: {
            ComposerControlLabel(
                systemImage: "plus.circle",
                text: "from \(base)",
                isActive: isPresented,
                showsMenuIndicator: true
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose the branch this one is cut from")
        .accessibilityLabel("Base branch")
        .accessibilityValue(base)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            panel
        }
    }

    private var panel: some View {
        let rows = list.rows
        return VStack(alignment: .leading, spacing: 0) {
            Text("The new branch is cut from this one on the machine. Type a name that is not listed to use it anyway.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.spacingWide)
            Hairline()
            searchRow
            Hairline()
            Group {
                if rows.isEmpty {
                    MenuEmptyRow(text: emptyText)
                } else {
                    listView(rows)
                }
            }
            .frame(height: Self.listHeight, alignment: .top)
            if let footer {
                Hairline()
                footer
                    .font(Typo.caption)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.spacingWide)
            }
        }
        .frame(width: Self.width)
        // Asked as the field settles rather than on every keystroke: runbloom.app searches, and
        // it shares a rate limit with the web client. The first ask is the popover opening.
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private var emptyText: String {
        if case .loading = list.load { return "Loading branches…" }
        return query.isEmpty ? "No branches to start from yet" : "Nothing matches \(query)"
    }

    /// The spinner, the reason it could not load, or the way to the next page. Under the list, in
    /// the place the local picker says why there are no pull requests.
    private var footer: AnyView? {
        switch list.load {
        case .loading:
            return AnyView(HStack(spacing: Metrics.spacing) {
                ProgressView().controlSize(.small)
                Text("Loading branches…").foregroundStyle(Palette.textTertiary)
            })
        case .failed(let reason):
            return AnyView(Text("Could not load branches: \(reason)")
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true))
        case .loaded where list.next != nil:
            return AnyView(Button("Show more branches") { Task { await more() } }.linkButton())
        case .idle, .loaded:
            return nil
        }
    }

    private var searchRow: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)
            MenuSearchField(text: $query, placeholder: "Search branches, or type one", onKey: handle(key:))
                .frame(height: Metrics.rowHeight)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingSmall)
    }

    private func listView(_ rows: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.self) { name in
                        WorkspaceSourceRow(
                            source: .newBranch(from: name),
                            isSelected: name == selected,
                            onPick: { pick(name) },
                            onHover: { selected = name }
                        )
                        .help(list.isTyped(name) ? "Not listed on runbloom.app yet. Used as typed." : "")
                        .id(name)
                    }
                }
                .padding(Metrics.spacingSmall)
            }
            .onChange(of: selected) { _, name in
                guard let name else { return }
                proxy.scrollTo(name)
            }
        }
    }

    // MARK: - Loading

    private func search(_ text: String) async {
        list.search(text)
        settleSelection()
        let asked = list.query
        do {
            let page = try await load(asked, nil)
            list.receive(page.names, next: page.next, for: asked)
        } catch {
            list.fail(Self.reason(error), for: asked)
        }
        settleSelection()
    }

    private func more() async {
        let asked = list.query
        let cursor = list.next
        list.loadingMore()
        do {
            let page = try await load(asked, cursor)
            list.receive(page.names, next: page.next, for: asked)
        } catch {
            list.fail(Self.reason(error), for: asked)
        }
    }

    private static func reason(_ error: any Error) -> String {
        (error as? RunbloomRefusal)?.message ?? error.localizedDescription
    }

    /// The highlight stays on its row while that row is listed, and otherwise goes to the first:
    /// a highlight on a row the search took away is a Return that does nothing.
    private func settleSelection() {
        let rows = list.rows
        if let selected, rows.contains(selected) { return }
        selected = rows.first
    }

    // MARK: - Keys

    private func handle(key: ComposerKey) -> Bool {
        let rows = list.rows
        switch key {
        case .up, .down:
            guard !rows.isEmpty else { return true }
            let step = key == .up ? -1 : 1
            let index = selected.flatMap(rows.firstIndex(of:)) ?? (step > 0 ? -1 : rows.count)
            selected = rows[min(max(index + step, 0), rows.count - 1)]
            return true
        case .returnKey, .commandReturn:
            guard let selected else { return false }
            pick(selected)
            return true
        case .escape:
            isPresented = false
            return true
        case .tab:
            return false
        }
    }

    private func pick(_ name: String) {
        isPresented = false
        // The default is stored as empty, so the chip follows the project if it changes.
        baseBranch = name == defaultBranch ? "" : name
    }
}
