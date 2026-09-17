import BloomClient
import BloomCore
import SwiftUI

/// Creating a Cloud workspace: a team, one of its GitHub projects, a name, a branch, and the first
/// message for the agent.
///
/// The first message is kept on this Mac and sent once the machine has started, a couple of
/// minutes later, because runbloom.app's create takes none. See `PendingOpeningPrompt`.
struct CreateCloudWorkspaceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var teamID: String?
    @State private var projects: [RunbloomProject] = []
    @State private var projectID: String?
    @State private var projectsProblem: String?
    @State private var isLoadingProjects = false
    @State private var name = ""
    @State private var branch = ""
    @State private var branchWasEdited = false
    @State private var baseBranch = ""
    @State private var prompt = ""
    @State private var isCreating = false
    @State private var failure: String?

    private var cloud: CloudWorkspaces { app.cloud }
    private var teams: [RunbloomTeam] { cloud.account?.cloudTeams ?? [] }
    private var team: RunbloomTeam? { teams.first { $0.id == teamID } }
    private var project: RunbloomProject? { projects.first { $0.id == projectID } }
    private var branchProblem: String? { branch.isEmpty ? nil : CloudBranchName.problem(branch) }

    /// What the chosen team still needs, when it cannot create a Cloud workspace yet.
    private var teamNotice: TeamSetupNotice? {
        team.flatMap { TeamSetupNotice(team: $0, environment: cloud.environment) }
    }

    private var canCreate: Bool {
        team != nil && teamNotice == nil && project != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && CloudBranchName.problem(branch) == nil && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if teams.isEmpty {
                    // No team in early access. Each team says why, and where to go next, rather
                    // than the sheet ending at a sentence with nothing to press.
                    let notices = (cloud.account?.teams ?? []).compactMap { TeamSetupNotice(team: $0, environment: cloud.environment) }
                    Section {
                        if notices.isEmpty {
                            Text("Cloud workspaces are in early access, and none of your teams is in it yet.")
                                .foregroundStyle(Palette.textSecondary)
                        }
                        ForEach(notices, id: \.self) { TeamSetupNoticeView(notice: $0) }
                    }
                } else {
                    Section {
                        if teams.count > 1 {
                            Picker("Team", selection: $teamID) {
                                ForEach(teams) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        Picker("Project", selection: $projectID) {
                            if projects.isEmpty { Text(isLoadingProjects ? "Loading…" : "No projects").tag(String?.none) }
                            ForEach(projects) { Text($0.repository).tag(Optional($0.id)) }
                        }
                        .disabled(projects.isEmpty)
                        if let teamNotice {
                            TeamSetupNoticeView(notice: teamNotice)
                        } else if let projectsProblem {
                            Text(projectsProblem).foregroundStyle(Palette.negative)
                        }
                    } footer: {
                        if teamNotice == nil, !isLoadingProjects, projects.isEmpty, projectsProblem == nil {
                            Text("Add a GitHub repository to the team on runbloom.app to create Cloud workspaces for it.")
                        }
                    }
                    Section {
                        TextField("Name", text: $name, prompt: Text("Queue retries"))
                        TextField("Branch", text: $branch, prompt: Text("freek/queue-retries"))
                            .font(.body.monospaced())
                            .onChange(of: branch) { _, new in
                                if new != suggestedBranch { branchWasEdited = true }
                            }
                        if let branchProblem {
                            Text(branchProblem).foregroundStyle(Palette.negative)
                        }
                        TextField("From", text: $baseBranch, prompt: Text(project?.defaultBranch ?? "main"))
                            .font(.body.monospaced())
                    }
                    Section {
                        TextEditor(text: $prompt)
                            .font(.body)
                            .frame(minHeight: 90)
                    } header: {
                        Text("First message")
                    } footer: {
                        Text("Sent to the agent once the Cloud workspace has finished starting, which takes a few minutes.")
                    }
                    if cloud.account?.githubConnected == false {
                        Section {
                            Label("Connect GitHub on runbloom.app first. Cloud workspaces push as you.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Palette.warning)
                        }
                    }
                }
            }
            .settingsForm()

            HStack {
                if let failure {
                    Text(failure)
                        .foregroundStyle(Palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Creating…" : "Create Cloud Workspace") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(Metrics.gutter)
        }
        .frame(width: 520, height: 560)
        .navigationTitle("New Cloud Workspace")
        .onAppear {
            if teamID == nil { teamID = teams.first { $0.id == cloud.account?.currentTeamID }?.id ?? teams.first?.id }
        }
        .task(id: teamID) { await loadProjects() }
        .onChange(of: name) { _, _ in
            if !branchWasEdited || branch.isEmpty {
                branch = suggestedBranch
                branchWasEdited = false
            }
        }
    }

    private var suggestedBranch: String {
        let first = cloud.account?.name.split(separator: " ").first.map { $0.lowercased() }
        return CloudBranchName.suggestion(for: name, prefix: first)
    }

    private func loadProjects() async {
        guard let teamID else { return }
        isLoadingProjects = true
        defer { isLoadingProjects = false }
        do {
            projects = try await cloud.projects(team: teamID)
            projectsProblem = nil
            if !projects.contains(where: { $0.id == projectID }) { projectID = projects.first?.id }
        } catch let refusal as RunbloomRefusal {
            projects = []
            projectsProblem = refusal.message
        } catch {
            projects = []
            projectsProblem = "runbloom.app could not be reached. \(error.localizedDescription)"
        }
    }

    private func create() {
        guard let team, let project else { return }
        isCreating = true
        failure = nil
        let request = CloudWorkspaces.CreateRequest(
            team: team, project: project, name: name.trimmingCharacters(in: .whitespaces), branch: branch,
            baseBranch: baseBranch.trimmingCharacters(in: .whitespaces), prompt: prompt
        )
        Task {
            defer { isCreating = false }
            do {
                _ = try await cloud.create(request)
                dismiss()
            } catch let refusal as RunbloomRefusal {
                failure = LimitNotice(refusal: refusal).map { "\($0.message) \($0.detail)" } ?? refusal.message
            } catch {
                failure = "runbloom.app could not be reached. \(error.localizedDescription)"
            }
        }
    }
}
