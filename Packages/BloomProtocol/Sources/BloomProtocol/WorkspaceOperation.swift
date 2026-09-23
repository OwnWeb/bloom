import Foundation

/// Everything a client can ask of the one workspace this server holds.
///
/// **No workspace id anywhere,** because a machine holds exactly one workspace and the token
/// already names it. What #163 needed for a server with many projects on it (the catalogue,
/// project settings, creating a workspace, storage, skills, diagnostics, Docker) is not here:
/// creation is the machine's bootstrap, and the rest has no meaning on a machine of its own.
///
/// Encoded as one object with a `kind` and the operation's own fields beside it. An operation's
/// fields are named here and none is called `kind`, so nothing can collide with the tag.
public enum WorkspaceOperation: Codable, Sendable, Hashable {
    // Reading the workspace
    case workspace
    case transcript(chatID: String, afterSeq: Int, limit: Int?)
    /// A chat's composer, or with no `chat_id` what a chat that does not exist yet would start
    /// with, together with the choices a client can offer before making one.
    case composer(chatID: String?)
    case setupOutput
    case files
    case file(path: String)
    case download(path: String)
    case reviewSnapshot(scope: DiffScope, knownRevision: String?, wait: Bool)
    case reviewPatch(path: String, scope: DiffScope, knownRevision: String?)
    case runScripts
    /// The project's quick prompts, read off the checkout on this call. See `QuickPromptRecord`.
    case quickPrompts
    /// The workspace's code searched for `query`, case-insensitively, over what `files` lists.
    case searchCode(query: String, limit: Int?)
    /// The branch's commits, newest first. `before` is a sha to page from, exclusive.
    case history(limit: Int?, before: String?)
    /// One commit's changed files, for a History row somebody opened.
    case commitFiles(sha: String)
    /// One file's diff inside one commit, answered as `review_patch` answers the other scopes.
    case commitPatch(sha: String, path: String)
    /// The workspace's transcripts, searched on the machine that holds them.
    case transcriptSearch(query: String, limit: Int?)
    case notes
    case pullRequest
    case archivePreview
    /// At most ten top-level chats, newest closure first. The server owns the bound so every
    /// client sees the same list and cannot turn this menu-sized read into an archive browser.
    case recentlyClosed

    // Conversations
    case newChat(controls: ComposerControlsRecord)
    case renameChat(chatID: String, title: String)
    case closeChat(chatID: String)
    case reopenChat(chatID: String)
    case markRead(chatID: String, seq: Int)
    case setComposer(chatID: String, controls: ComposerControlsRecord)
    /// `via` says an agent wrote it on the person's behalf. See `ViaRecord`.
    case send(chatID: String, text: String, audience: AudienceRecord? = nil, via: ViaRecord? = nil)
    case cancelQueued(chatID: String, promptID: String)
    case stop(chatID: String)
    case answer(chatID: String, requestID: String, answer: Answer)

    // The worktree
    case writeFile(path: String, text: String, revision: String)
    case uploadFile(name: String, data: Data)
    case commit(message: String)
    case push
    case createPullRequest(title: String, body: String, draft: Bool)
    case saveNotes(text: String)
    /// Puts a file back to the review's baseline, and one hunk of it back, as the diff gutter does.
    case revertFile(path: String, scope: DiffScope)
    case discardHunk(path: String, scope: DiffScope, patch: String)
    case renameWorkspace(name: String)
    case runSetup
    /// Stops the setup running now, whether the machine's own or one run by hand. See `stop_setup`
    /// in docs/WORKSPACE-PROTOCOL.md.
    case stopSetup
    /// After the pull request merged: a new branch cut from the base in this same worktree, and the
    /// agent told, in `chat_id` or the most recent chat. Answers `text` with the new branch.
    case continueAfterMerge(chatID: String?)
    case runScript(id: String)
    case closeTerminal(name: String)
    case archive(confirmationID: String)
    /// What is listening inside the workspace, for the ports a person can forward to their Mac.
    case listeningPorts

    /// Whether the server journals this command so a retry is answered from its record.
    public var mutates: Bool {
        switch self {
        case .workspace, .transcript, .composer, .setupOutput, .files, .file, .download, .reviewSnapshot, .reviewPatch,
             .runScripts, .quickPrompts, .searchCode, .history, .commitFiles, .commitPatch, .transcriptSearch, .notes, .pullRequest,
             .archivePreview, .recentlyClosed, .listeningPorts: false
        default: true
        }
    }

    /// The token ability this operation needs. Every operation needs `view` as well.
    ///
    /// **Every case is named, and there is no `default`.** It ended in `default: "view"`, so an
    /// operation added later, however much it changed, was open to anybody who could look; the
    /// security review of 19 September 2026 found it as L1. Now a new case does not compile until
    /// somebody decides what it needs, and `OperationAbilityTests` pins the whole table.
    public var ability: String {
        switch self {
        case .workspace, .transcript, .composer, .setupOutput, .files, .file, .download, .reviewSnapshot, .reviewPatch,
             .runScripts, .quickPrompts, .searchCode, .history, .commitFiles, .commitPatch, .transcriptSearch, .notes,
             .pullRequest, .recentlyClosed, .markRead: "view"
        case .send, .cancelQueued, .stop, .answer, .newChat, .closeChat, .reopenChat, .renameChat, .setComposer: "prompt"
        case .writeFile, .uploadFile, .commit, .push, .createPullRequest, .saveNotes, .renameWorkspace, .runSetup, .stopSetup, .continueAfterMerge,
             .revertFile, .discardHunk: "files"
        // **A forwarded port is as much reach into the machine as a shell**, so the list that
        // offers one is behind the same ability rather than behind `view`. Somebody who may look
        // at a workspace is not thereby allowed to open its database on their own Mac.
        case .runScript, .closeTerminal, .listeningPorts: "terminal"
        case .archive, .archivePreview: "share"
        }
    }

    /// Whether this operation is human input for the presence lease. Reading is not.
    public var isHumanInput: Bool { mutates && !isMarkRead }

    private var isMarkRead: Bool {
        if case .markRead = self { true } else { false }
    }

    public var kind: String {
        switch self {
        case .workspace: "workspace"
        case .transcript: "transcript"
        case .composer: "composer"
        case .setupOutput: "setup_output"
        case .files: "files"
        case .history: "history"
        case .commitFiles: "commit_files"
        case .commitPatch: "commit_patch"
        case .transcriptSearch: "transcript_search"
        case .file: "file"
        case .download: "download"
        case .reviewSnapshot: "review_snapshot"
        case .reviewPatch: "review_patch"
        case .runScripts: "run_scripts"
        case .listeningPorts: "listening_ports"
        case .quickPrompts: "quick_prompts"
        case .searchCode: "search_code"
        case .notes: "notes"
        case .pullRequest: "pull_request"
        case .archivePreview: "archive_preview"
        case .recentlyClosed: "recently_closed"
        case .newChat: "new_chat"
        case .renameChat: "rename_chat"
        case .closeChat: "close_chat"
        case .reopenChat: "reopen_chat"
        case .markRead: "mark_read"
        case .setComposer: "set_composer"
        case .send: "send"
        case .cancelQueued: "cancel_queued"
        case .stop: "stop"
        case .answer: "answer"
        case .writeFile: "write_file"
        case .uploadFile: "upload_file"
        case .commit: "commit"
        case .push: "push"
        case .createPullRequest: "create_pull_request"
        case .saveNotes: "save_notes"
        case .revertFile: "revert_file"
        case .discardHunk: "discard_hunk"
        case .renameWorkspace: "rename_workspace"
        case .runSetup: "run_setup"
        case .stopSetup: "stop_setup"
        case .continueAfterMerge: "continue_after_merge"
        case .runScript: "run_script"
        case .closeTerminal: "close_terminal"
        case .archive: "archive"
        }
    }

    enum Keys: String, CodingKey {
        case chatID = "chat_id", afterSeq = "after_seq", limit, path, scope, knownRevision = "known_revision", wait
        case controls, title, seq, text, promptID = "prompt_id", requestID = "request_id", answer, before, sha, patch, query
        case revision, name, data, message, body, draft, id, confirmationID = "confirmation_id", audience, via
    }

    public init(from decoder: any Decoder) throws {
        let kind = try Tagged.kind(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        switch kind {
        case "workspace": self = .workspace
        case "transcript":
            self = .transcript(chatID: try c.decode(String.self, forKey: .chatID), afterSeq: try c.decodeIfPresent(Int.self, forKey: .afterSeq) ?? -1,
                               limit: try c.decodeIfPresent(Int.self, forKey: .limit))
        case "composer": self = .composer(chatID: try c.decodeIfPresent(String.self, forKey: .chatID))
        case "setup_output": self = .setupOutput
        case "files": self = .files
        case "history":
            self = .history(limit: try c.decodeIfPresent(Int.self, forKey: .limit), before: try c.decodeIfPresent(String.self, forKey: .before))
        case "commit_files": self = .commitFiles(sha: try c.decode(String.self, forKey: .sha))
        case "commit_patch":
            self = .commitPatch(sha: try c.decode(String.self, forKey: .sha), path: try c.decode(String.self, forKey: .path))
        case "transcript_search":
            self = .transcriptSearch(query: try c.decode(String.self, forKey: .query), limit: try c.decodeIfPresent(Int.self, forKey: .limit))
        case "file": self = .file(path: try c.decode(String.self, forKey: .path))
        case "download": self = .download(path: try c.decode(String.self, forKey: .path))
        case "review_snapshot":
            self = .reviewSnapshot(scope: try c.decode(DiffScope.self, forKey: .scope), knownRevision: try c.decodeIfPresent(String.self, forKey: .knownRevision),
                                   wait: try c.decodeIfPresent(Bool.self, forKey: .wait) ?? false)
        case "review_patch":
            self = .reviewPatch(path: try c.decode(String.self, forKey: .path), scope: try c.decode(DiffScope.self, forKey: .scope),
                                knownRevision: try c.decodeIfPresent(String.self, forKey: .knownRevision))
        case "run_scripts": self = .runScripts
        case "listening_ports": self = .listeningPorts
        case "quick_prompts": self = .quickPrompts
        case "search_code":
            self = .searchCode(query: try c.decode(String.self, forKey: .query), limit: try c.decodeIfPresent(Int.self, forKey: .limit))
        case "notes": self = .notes
        case "pull_request": self = .pullRequest
        case "archive_preview": self = .archivePreview
        case "recently_closed": self = .recentlyClosed
        case "new_chat": self = .newChat(controls: try c.decode(ComposerControlsRecord.self, forKey: .controls))
        case "rename_chat": self = .renameChat(chatID: try c.decode(String.self, forKey: .chatID), title: try c.decode(String.self, forKey: .title))
        case "close_chat": self = .closeChat(chatID: try c.decode(String.self, forKey: .chatID))
        case "reopen_chat": self = .reopenChat(chatID: try c.decode(String.self, forKey: .chatID))
        case "mark_read": self = .markRead(chatID: try c.decode(String.self, forKey: .chatID), seq: try c.decode(Int.self, forKey: .seq))
        case "set_composer":
            self = .setComposer(chatID: try c.decode(String.self, forKey: .chatID), controls: try c.decode(ComposerControlsRecord.self, forKey: .controls))
        case "send":
            self = .send(chatID: try c.decode(String.self, forKey: .chatID), text: try c.decode(String.self, forKey: .text),
                         audience: try c.decodeIfPresent(AudienceRecord.self, forKey: .audience),
                         via: try c.decodeIfPresent(ViaRecord.self, forKey: .via))
        case "cancel_queued": self = .cancelQueued(chatID: try c.decode(String.self, forKey: .chatID), promptID: try c.decode(String.self, forKey: .promptID))
        case "stop": self = .stop(chatID: try c.decode(String.self, forKey: .chatID))
        case "answer":
            self = .answer(chatID: try c.decode(String.self, forKey: .chatID), requestID: try c.decode(String.self, forKey: .requestID),
                           answer: try c.decode(Answer.self, forKey: .answer))
        case "write_file":
            self = .writeFile(path: try c.decode(String.self, forKey: .path), text: try c.decode(String.self, forKey: .text),
                              revision: try c.decode(String.self, forKey: .revision))
        case "upload_file": self = .uploadFile(name: try c.decode(String.self, forKey: .name), data: try c.decode(Data.self, forKey: .data))
        case "commit": self = .commit(message: try c.decode(String.self, forKey: .message))
        case "push": self = .push
        case "create_pull_request":
            self = .createPullRequest(title: try c.decode(String.self, forKey: .title), body: try c.decodeIfPresent(String.self, forKey: .body) ?? "",
                                      draft: try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false)
        case "save_notes": self = .saveNotes(text: try c.decode(String.self, forKey: .text))
        case "revert_file":
            self = .revertFile(path: try c.decode(String.self, forKey: .path), scope: try c.decode(DiffScope.self, forKey: .scope))
        case "discard_hunk":
            self = .discardHunk(path: try c.decode(String.self, forKey: .path), scope: try c.decode(DiffScope.self, forKey: .scope),
                                patch: try c.decode(String.self, forKey: .patch))
        case "rename_workspace": self = .renameWorkspace(name: try c.decode(String.self, forKey: .name))
        case "run_setup": self = .runSetup
        case "stop_setup": self = .stopSetup
        case "continue_after_merge": self = .continueAfterMerge(chatID: try c.decodeIfPresent(String.self, forKey: .chatID))
        case "run_script": self = .runScript(id: try c.decode(String.self, forKey: .id))
        case "close_terminal": self = .closeTerminal(name: try c.decode(String.self, forKey: .name))
        case "archive": self = .archive(confirmationID: try c.decode(String.self, forKey: .confirmationID))
        default: throw Tagged.unknown(kind, in: decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try Tagged.encode(kind: kind, to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .workspace, .setupOutput, .files, .runScripts, .quickPrompts, .notes, .pullRequest, .archivePreview, .recentlyClosed, .listeningPorts,
             .push, .runSetup, .stopSetup: break
        case .transcript(let chatID, let afterSeq, let limit):
            try c.encode(chatID, forKey: .chatID); try c.encode(afterSeq, forKey: .afterSeq); try c.encodeIfPresent(limit, forKey: .limit)
        case .composer(let chatID), .continueAfterMerge(let chatID): try c.encodeIfPresent(chatID, forKey: .chatID)
        case .closeChat(let chatID), .reopenChat(let chatID), .stop(let chatID): try c.encode(chatID, forKey: .chatID)
        case .file(let path), .download(let path): try c.encode(path, forKey: .path)
        case .history(let limit, let before):
            try c.encodeIfPresent(limit, forKey: .limit); try c.encodeIfPresent(before, forKey: .before)
        case .commitFiles(let sha): try c.encode(sha, forKey: .sha)
        case .commitPatch(let sha, let path): try c.encode(sha, forKey: .sha); try c.encode(path, forKey: .path)
        case .transcriptSearch(let query, let limit), .searchCode(let query, let limit):
            try c.encode(query, forKey: .query); try c.encodeIfPresent(limit, forKey: .limit)
        case .revertFile(let path, let scope): try c.encode(path, forKey: .path); try c.encode(scope, forKey: .scope)
        case .discardHunk(let path, let scope, let patch):
            try c.encode(path, forKey: .path); try c.encode(scope, forKey: .scope); try c.encode(patch, forKey: .patch)
        case .reviewSnapshot(let scope, let knownRevision, let wait):
            try c.encode(scope, forKey: .scope); try c.encodeIfPresent(knownRevision, forKey: .knownRevision); try c.encode(wait, forKey: .wait)
        case .reviewPatch(let path, let scope, let knownRevision):
            try c.encode(path, forKey: .path); try c.encode(scope, forKey: .scope); try c.encodeIfPresent(knownRevision, forKey: .knownRevision)
        case .newChat(let controls): try c.encode(controls, forKey: .controls)
        case .renameChat(let chatID, let title): try c.encode(chatID, forKey: .chatID); try c.encode(title, forKey: .title)
        case .markRead(let chatID, let seq): try c.encode(chatID, forKey: .chatID); try c.encode(seq, forKey: .seq)
        case .setComposer(let chatID, let controls): try c.encode(chatID, forKey: .chatID); try c.encode(controls, forKey: .controls)
        case .send(let chatID, let text, let audience, let via):
            try c.encode(chatID, forKey: .chatID); try c.encode(text, forKey: .text)
            try c.encodeIfPresent(audience, forKey: .audience); try c.encodeIfPresent(via, forKey: .via)
        case .cancelQueued(let chatID, let promptID): try c.encode(chatID, forKey: .chatID); try c.encode(promptID, forKey: .promptID)
        case .answer(let chatID, let requestID, let answer):
            try c.encode(chatID, forKey: .chatID); try c.encode(requestID, forKey: .requestID); try c.encode(answer, forKey: .answer)
        case .writeFile(let path, let text, let revision):
            try c.encode(path, forKey: .path); try c.encode(text, forKey: .text); try c.encode(revision, forKey: .revision)
        case .uploadFile(let name, let data): try c.encode(name, forKey: .name); try c.encode(data, forKey: .data)
        case .commit(let message): try c.encode(message, forKey: .message)
        case .createPullRequest(let title, let body, let draft):
            try c.encode(title, forKey: .title); try c.encode(body, forKey: .body); try c.encode(draft, forKey: .draft)
        case .saveNotes(let text): try c.encode(text, forKey: .text)
        case .renameWorkspace(let name), .closeTerminal(let name): try c.encode(name, forKey: .name)
        case .runScript(let id): try c.encode(id, forKey: .id)
        case .archive(let confirmationID): try c.encode(confirmationID, forKey: .confirmationID)
        }
    }
}

/// Which changes a review shows: everything on the branch since it left its base, or only what
/// has not been committed.
public enum DiffScope: String, Codable, Sendable, Hashable, CaseIterable {
    case branch
    /// Everything not committed, staged and unstaged together, measured against HEAD.
    case uncommitted
    /// HEAD to the index: what a commit would take.
    case staged
    /// The index to the worktree: what a commit would leave behind.
    case unstaged
}

/// An answer to a permission prompt, a question or a plan.
public enum Answer: Codable, Sendable, Hashable {
    case allowOnce
    case allowSession
    case allowProject
    case deny(message: String?, endsTurn: Bool)
    case approvePlan(permissionMode: String)
    case question(input: WireValue)

    enum Keys: String, CodingKey { case message, endsTurn = "ends_turn", permissionMode = "permission_mode", input }

    public init(from decoder: any Decoder) throws {
        let kind = try Tagged.kind(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        switch kind {
        case "allow_once": self = .allowOnce
        case "allow_session": self = .allowSession
        case "allow_project": self = .allowProject
        case "deny": self = .deny(message: try c.decodeIfPresent(String.self, forKey: .message), endsTurn: try c.decodeIfPresent(Bool.self, forKey: .endsTurn) ?? false)
        case "approve_plan": self = .approvePlan(permissionMode: try c.decode(String.self, forKey: .permissionMode))
        case "question": self = .question(input: try c.decode(WireValue.self, forKey: .input))
        default: throw Tagged.unknown(kind, in: decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .allowOnce: try Tagged.encode(kind: "allow_once", to: encoder)
        case .allowSession: try Tagged.encode(kind: "allow_session", to: encoder)
        case .allowProject: try Tagged.encode(kind: "allow_project", to: encoder)
        case .deny(let message, let endsTurn):
            try Tagged.encode(kind: "deny", to: encoder)
            try c.encodeIfPresent(message, forKey: .message); try c.encode(endsTurn, forKey: .endsTurn)
        case .approvePlan(let mode):
            try Tagged.encode(kind: "approve_plan", to: encoder)
            try c.encode(mode, forKey: .permissionMode)
        case .question(let input):
            try Tagged.encode(kind: "question", to: encoder)
            try c.encode(input, forKey: .input)
        }
    }
}
