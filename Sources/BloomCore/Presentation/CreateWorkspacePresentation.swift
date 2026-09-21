/// The one New Workspace sheet the main window may present.
///
/// Repeated asks keep the request's identity, so SwiftUI updates the sheet that is already up
/// rather than dismissing and presenting another one. A named project replaces the current
/// project, while an unnamed ask leaves the sheet where the person has navigated. Pull-request
/// asks carry a revision rather than a Boolean, so each menu action can focus the reference field
/// without leaving a flag behind for the next opening.
public struct CreateWorkspacePresentation: Sendable {
    public struct Request: Identifiable, Equatable, Sendable {
        public let id: UInt64
        public fileprivate(set) var repoID: RepoID?
        public fileprivate(set) var pullRequestRevision: UInt64
    }

    public private(set) var request: Request?
    private var nextID: UInt64 = 0

    public init() {}

    public mutating func present(repoID: RepoID?, asksForPullRequest: Bool = false) {
        if var request {
            if let repoID { request.repoID = repoID }
            if asksForPullRequest { request.pullRequestRevision &+= 1 }
            self.request = request
            return
        }

        nextID &+= 1
        request = Request(
            id: nextID,
            repoID: repoID,
            pullRequestRevision: asksForPullRequest ? 1 : 0
        )
    }

    public mutating func dismiss() {
        request = nil
    }
}
