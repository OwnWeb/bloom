import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// What is inside the window that starts a Cloud workspace. The window, and why it is one, is
/// `CreateCloudWorkspaceWindow`.
///
/// **It is `CreateWorkspaceView` for a machine, and the resemblance is the feature.** Read that
/// file first: every argument it makes about being the composer rather than a form holds here word
/// for word, and the parts are in the same places so that starting work does not feel like two
/// different applications depending on where the work is going to run. The band across the top is
/// the project and the base branch, the segmented control says what you are starting with, the
/// question is the same question, and the box under it is the composer with its own controls and
/// its own Create.
///
/// Four things differ, and each is a difference in the truth rather than in the design.
///
/// **There is no `Open existing branch…`.** runbloom.app creates a workspace from a base branch and
/// nothing else, so the space beside the base is left empty rather than filled with a control that
/// would have to refuse.
///
/// **`Start with` offers Chat alone.** A machine has no browser tab of this Mac's and its terminal
/// is the workspace's own rather than something to start in, so the two other segments would be
/// greyed for ever. The `+` menu already leaves out what a Cloud workspace has no answer to; this
/// is the same rule in the same words.
///
/// **The name and the branch are derived rather than demanded.** The form asked for both before
/// anybody had said what they wanted. They come from the first line of the task now, by the rule
/// the local namer falls back to (`Git.title`), with the branch from the same `Git.branchStem` a
/// local workspace's comes from, under the account's GitHub login. A local workspace wears a sea while a model thinks of
/// something better and renames itself a moment later; a Cloud workspace's name lives on
/// runbloom.app, so it is named once, here, out of the same sentence the agent is about to be given.
///
/// **And the one sentence a local workspace has no equivalent for**: the machine has to be made and
/// set up, which takes minutes, and the first message waits for it. That is said under the box,
/// where the local window says what it is about to cut.
struct CreateCloudWorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var teamID: String?
    /// The team's projects as one value rather than a list beside a spinner beside a sentence.
    /// Loading with an old list still on screen, and failed with projects showing, were states
    /// three flags could describe and the window could not draw.
    private enum Projects {
        case loading
        case ready([RunbloomProject])
        case failed(String)

        var all: [RunbloomProject] {
            if case .ready(let projects) = self { projects } else { [] }
        }

        var problem: String? {
            if case .failed(let message) = self { message } else { nil }
        }

        var isLoading: Bool {
            if case .loading = self { true } else { false }
        }
    }

    @State private var projectsState = Projects.loading
    @State private var projectID: String?
    @State private var prompt = ""
    @State private var caret = 0
    @State private var isFocused = false
    @State private var contentHeight = ComposerTextEditor.lineHeight
    @State private var controls = ComposerControls()
    @State private var loadedControls = false
    /// Whether the controls below the box were changed by the person rather than resolved for
    /// them. **This is what the machine's own defaults are weighed against.** No machine exists
    /// while this window is open, so what it shows is this Mac's choice; the machine answers a
    /// better one a couple of minutes later, having read the repository's settings file and the
    /// agents in its image. A value nobody touched should give way to that. A value somebody
    /// picked should not. See `PendingOpeningPrompt.controls`.
    @State private var controlsWereChosen = false
    /// Empty for the project's own default, which is what the chip says when nothing is typed.
    @State private var baseBranch = ""
    @State private var isEditingBase = false
    /// Whether the machine runs the project's setup. The same choice the local window offers, in
    /// the same words, with the same default.
    @State private var runsSetup = true
    @State private var isCreating = false
    @State private var failure: String?
    /// The draft this window's prompt and its files are keyed by.
    ///
    /// The files are staged under it, laid out as a worktree is, and they cross to the machine when
    /// the opening prompt does, because there is no machine to upload them to while this window is
    /// open. See `PendingOpeningPrompt.stagingDraftID`.
    @State private var draftID = PromptAttachments.newShortID()
    /// Set when the workspace was made, so closing this window leaves the staged files where the
    /// prompt that names them can still find them. Everything else is an abandoned draft and is
    /// taken away.
    @State private var handedOver = false

    /// The same width as the local window, for the same reason: the footer's labelled controls.
    /// See `CreateWorkspaceView.width`, which measured it control by control.
    private static let width: CGFloat = 760
    private static let minEditorLines: CGFloat = 5

    private var cloud: CloudWorkspaces { app.cloud }
    private var teams: [RunbloomTeam] { cloud.account?.cloudTeams ?? [] }
    private var team: RunbloomTeam? { teams.first { $0.id == teamID } }
    private var projects: [RunbloomProject] { projectsState.all }
    private var project: RunbloomProject? { projects.first { $0.id == projectID } }

    /// What the chosen team still needs before it can create anything.
    private var teamNotice: TeamSetupNotice? {
        team.flatMap { TeamSetupNotice(team: $0, environment: cloud.environment) }
    }

    private var task: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The base the branch is cut from, which is the project's default until somebody says
    /// otherwise.
    private var base: String {
        baseBranch.isEmpty ? (project?.defaultBranch ?? "main") : baseBranch
    }

    /// What this workspace will be called: the first line of the task, by the rule the local
    /// namer falls back to when no model answers. See the head of this file.
    private var derivedName: String { Git.title(from: task) }

    /// And its branch, by **the same function a local workspace's branch comes from**, under this
    /// account's GitHub login rather than the project's prefix. No login, no prefix, never the
    /// display name.
    ///
    /// `Git.branchStem` and not a slug of the name, which is what it was, and the difference is
    /// what the owner met: a name is a sentence and a branch is not, so slugging the name gave him
    /// `freekmurze/show-me-the-homepage-in-a-pane-next-to-this-chat`. The shared function drops the
    /// stop words, keeps five, caps the whole at sixty and each word at twenty four, and keeps the
    /// file a prompt names so two workspaces about two files do not collide. A Cloud branch is read
    /// in the same places a local one is, so it is the same rule rather than a second one.
    private var derivedBranch: String {
        Git.branchStem(prompt: task, prefix: cloud.account?.branchPrefix)
    }

    private var canCreate: Bool {
        team != nil && teamNotice == nil && project != nil && !task.isEmpty
            && cloud.account?.githubConnected != false
            && CloudBranchName.problem(derivedBranch) == nil && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            if let blocked {
                blocked
                    .padding(Metrics.gutter)
            } else {
                composer
                // The local window's own control, drawn where it draws it: under the box and above
                // the sentence. Shown always rather than only for a project with a setup script,
                // because this Mac cannot see the repository to know whether there is one.
                WorkspaceSetupOption(isEnabled: $runsSetup)
                    .disabled(isCreating)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, Metrics.spacingWide)
                consequence
            }
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .onAppear {
            if teamID == nil {
                teamID = teams.first { $0.id == cloud.account?.currentTeamID }?.id ?? teams.first?.id
            }
        }
        .task(id: teamID) { await loadProjects() }
        // The controls a first turn on a machine would run with, resolved once. They are this
        // Mac's own defaults for a new chat, clamped to what a Cloud workspace can run, which is
        // the same answer `CloudWorkspaces.openingControls` gives when nobody has chosen.
        .task {
            guard !loadedControls else { return }
            controls = await cloud.openingControls()
            loadedControls = true
        }
        .onDisappear(perform: discardDraft)
    }

    // MARK: - The bar above the box

    /// The project and the base, which are the two choices that are about the workspace rather
    /// than about the turn. The local window's band, with its third control left out: see the head
    /// of this file for why there is no `Open existing branch…` here.
    private var header: some View {
        HStack(spacing: Metrics.spacingSmall) {
            projectControl

            if project != nil {
                baseControl
            }

            Spacer(minLength: 0)

            if projectsState.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading projects")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
    }

    /// The same chip as the local window's, over runbloom.app's projects rather than this Mac's.
    /// A team with one project still says which, for the reason that one does: a window that makes
    /// a machine without naming the repository is asking for trust it has not earned.
    @ViewBuilder
    private var projectControl: some View {
        let label = ComposerControlLabel(
            text: project?.repository ?? (projectsState.isLoading ? "Loading…" : "Choose a project"),
            tint: Palette.textPrimary,
            showsMenuIndicator: projects.count > 1 || teams.count > 1
        ) {
            Image(systemName: "cloud")
        }

        if projects.count > 1 || teams.count > 1 {
            Menu {
                if teams.count > 1 {
                    Picker("Team", selection: $teamID) {
                        ForEach(teams) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                }
                Picker("Project", selection: $projectID) {
                    ForEach(projects) { Text($0.repository).tag(Optional($0.id)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose the project")
            .accessibilityLabel("Project")
            .accessibilityValue(project?.repository ?? "")
        } else {
            label
        }
    }

    /// `from main`, in the place the local window's source picker stands.
    ///
    /// A button with a field behind it rather than a menu, because runbloom.app lists a project's
    /// default branch and nothing else: there is no list of branches to choose from, and a menu
    /// with one item in it that cannot be changed would be a control that lies about what it does.
    /// Typing is how another base is named, and the chip says what will happen when nobody types.
    private var baseControl: some View {
        Button {
            isEditingBase = true
        } label: {
            ComposerControlLabel(text: "from \(base)", showsMenuIndicator: true) {
                Image(systemName: "plus.circle")
            }
        }
        .buttonStyle(.plain)
        .help("Choose the branch this one is cut from")
        .accessibilityLabel("Base branch")
        .accessibilityValue(base)
        .popover(isPresented: $isEditingBase, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                Text("Cut the new branch from")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                TextField(project?.defaultBranch ?? "main", text: $baseBranch)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 260)
                    .onSubmit { isEditingBase = false }
            }
            .padding(Metrics.gutter)
        }
    }

    // MARK: - The choice, and then the box

    private var composer: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            modePicker

            Text("What do you want to work on?")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)

            chatBox

            statusRow
        }
        .padding(Metrics.gutter)
    }

    /// One segment, and drawn rather than left out, so the window has the same parts in the same
    /// places as the local one. Two greyed segments would be two promises this cannot keep; see
    /// the head of this file.
    private var modePicker: some View {
        Picker("Start with", selection: .constant(WorkspaceStartMode.chat)) {
            Text("Chat").tag(WorkspaceStartMode.chat)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .tint(Palette.controlAccent)
        .help("A Bloom Cloud workspace starts with a chat. Its terminal is a tab of the workspace itself.")
    }

    private var chatBox: some View {
        ComposerPrompt(
            text: $prompt,
            caret: $caret,
            isFocused: $isFocused,
            // No worktree on this Mac, so there are no files for `@` to offer. The machine's own
            // files are not on this Mac to be completed against.
            mentionRoot: "",
            attachmentRoot: AttachmentStaging.directory(draftID: draftID),
            attachmentKey: draftID,
            placeholder: "Describe the task for the agent on the machine",
            editorHeight: max(contentHeight, ComposerTextEditor.lineHeight * Self.minEditorLines),
            onContentHeightChange: { contentHeight = $0 },
            onKey: handle(key:),
            onOpenAttachment: { _ in }
        ) { actions in
            ComposerFooterView(
                controls: controls,
                onChange: {
                    controls = $0
                    controlsWereChosen = true
                },
                canSend: canCreate,
                intent: .create,
                // Fixed width, chosen for this row with its words on. See `width`.
                adaptsToWidth: false,
                onAttach: actions.attach,
                onQuickPrompt: actions.insert,
                onSend: create
            )
        }
    }

    /// What is worth saying under the box: why Create failed, or that the team has no key for the
    /// agent its first turn would run with.
    ///
    /// **Not the derived name and branch any more.** They were drawn here as two lines of text the
    /// moment anything was typed, on the argument that a Cloud workspace does not rename itself
    /// afterwards, and what the owner saw was a workspace name and a branch built out of a half
    /// typed sentence running off both edges of the sheet. He asked for it to go. The local sheet
    /// never had this line: it draws a branch chip where a name is being derived and deliberately
    /// nothing where a model will write the name.
    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: Metrics.spacingSmall) {
            if let failure {
                Text(failure)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !task.isEmpty, let problem = CloudBranchName.problem(derivedBranch) {
                // The one job the removed preview did that is still worth doing: Create is off
                // while the branch this message would make is not a branch git accepts, and a
                // button that is off for no reason on screen reads as broken. Said only when it is
                // the case, which a message of ordinary words never is.
                Text(problem)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            } else if task.isEmpty, let notice = agentKeyNotice {
                Text(notice)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// The team has no key for the agent a turn would run with, which does not stop a workspace
    /// being made and does stop its first turn. Said here rather than in a section of its own.
    private var agentKeyNotice: String? {
        guard let team, !cloud.hasAnyAgentKey(team: team.id) else { return nil }
        return "This team has no Claude Code or Codex API key yet, so the first turn could not start."
    }

    /// What pressing Create does, in the place the local window says what it cuts, and the one
    /// sentence a local workspace has no equivalent for.
    private var consequence: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingTight) {
            // **What it does and what to expect, and not how it is built.** It said "on a machine
            // runbloom.app runs" and "the machine is made and set up first", which is Bloom
            // describing its own plumbing to somebody who wanted to make a workspace. What is left
            // is what they will see: how long, and that the message they typed is not lost.
            Text("Creates a Bloom Cloud workspace.")
            Text(runsSetup
                 ? "Your first message goes as soon as it is ready, which takes a few minutes."
                 : "It is ready in about a minute, without running the project's setup.")
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, Metrics.gutter)
    }

    // MARK: - What stands in the composer's place

    /// The state that stops this window being a composer at all, drawn where the local window
    /// draws "no projects yet". Nil when there is a workspace to be made.
    @ViewBuilder
    private var blocked: (some View)? {
        if !cloud.isSignedIn {
            CloudEmptyStateView(state: cloud.emptyState)
        } else if teams.isEmpty {
            noTeams
        } else if let teamNotice {
            TeamSetupNoticeView(notice: teamNotice, environment: cloud.environment)
        } else if cloud.account?.githubConnected == false {
            step(
                "Connect GitHub before creating one. A Bloom Cloud workspace clones the repository and pushes as you.",
                action: .connectGitHub
            )
        } else if let problem = projectsState.problem {
            EmptyStateView(glyph: "exclamationmark.triangle", title: "Could not read your projects", message: problem)
        } else if !projectsState.isLoading, projects.isEmpty {
            step(
                "This team has no projects yet. A project is a GitHub repository a Bloom Cloud workspace can be created for.",
                action: .addProject
            )
        }
    }

    private var noTeams: some View {
        let notices = (cloud.account?.teams ?? []).compactMap {
            TeamSetupNotice(team: $0, environment: cloud.environment)
        }
        return VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            if notices.isEmpty {
                Text("Bloom Cloud workspaces are in early access, and none of your teams is in it yet.")
                    .foregroundStyle(Palette.textSecondary)
            }
            ForEach(notices, id: \.self) { TeamSetupNoticeView(notice: $0, environment: cloud.environment) }
        }
    }

    /// A sentence and the button that answers it, rather than a sentence in grey. This is where a
    /// first run stops, and it used to stop with nothing to press.
    private func step(_ sentence: String, action: TeamSetupStep) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(sentence).fixedSize(horizontal: false, vertical: true)
            Button(action.buttonTitle) { open(action) }
        }
    }

    /// runbloom.app's page for one step of a team's setup.
    private func open(_ step: TeamSetupStep) {
        let page = team?.setup?.setupPage(on: cloud.environment, for: step)
        NSWorkspace.shared.open(page ?? cloud.environment.teamPage)
    }

    // MARK: - Actions

    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .returnKey, .commandReturn:
            create()
            return true
        case .escape:
            dismiss()
            return true
        case .up, .down, .tab:
            return false
        }
    }

    private func loadProjects() async {
        guard let teamID else { return }
        projectsState = .loading
        do {
            let projects = try await cloud.projects(team: teamID)
            projectsState = .ready(projects)
            if !projects.contains(where: { $0.id == projectID }) { projectID = projects.first?.id }
        } catch let refusal as RunbloomRefusal {
            projectsState = .failed(refusal.message)
        } catch {
            projectsState = .failed("runbloom.app could not be reached. \(error.localizedDescription)")
        }
    }

    private func create() {
        guard let team, let project, canCreate else { return }
        isCreating = true
        failure = nil
        let request = CloudWorkspaces.CreateRequest(
            team: team, project: project, name: derivedName, branch: derivedBranch,
            baseBranch: base, prompt: prompt, runSetup: runsSetup,
            controls: controlsWereChosen ? controls : nil,
            stagingDraftID: PromptAttachmentStore.shared.attachments(for: draftID).isEmpty ? nil : draftID
        )
        Task {
            defer { isCreating = false }
            do {
                _ = try await cloud.create(request)
                handedOver = request.stagingDraftID != nil
                dismiss()
                // The window this one is not attached to. Creating selects the new workspace in
                // the main window, which can be behind this one or closed altogether. The local
                // create window does the same and for the same reason.
                openWindow(id: BloomApp.mainWindowID)
            } catch let refusal as RunbloomRefusal {
                failure = LimitNotice(refusal: refusal).map { "\($0.message) \($0.detail)" } ?? refusal.message
            } catch {
                failure = "runbloom.app could not be reached. \(error.localizedDescription)"
            }
        }
    }

    private func discardDraft() {
        // The files went with the workspace. Taking them away here would delete what the held
        // prompt is about to upload, which on a slow machine is minutes after this window closed.
        guard !handedOver else { return }
        let id = draftID
        PromptAttachmentStore.shared.clear(sessionID: id)
        Task.detached(priority: .utility) {
            AttachmentStaging.discard(draftID: id)
        }
    }
}
