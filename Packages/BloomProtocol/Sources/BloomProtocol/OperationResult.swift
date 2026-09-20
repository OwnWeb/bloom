import Foundation

/// What an operation answers with: one object with a `kind`, the record under a key of the same
/// name (`{"kind": "file", "file": {...}}`), or `{"kind": "accepted"}` for a mutation that has
/// nothing more to say. See `Tagged`.
public enum OperationResult: Codable, Sendable, Hashable {
    case accepted
    case workspace(WorkspaceSnapshotRecord)
    case transcript(TranscriptRecord)
    case composer(ComposerRecord)
    case setupOutput(SetupOutputRecord)
    case files(paths: [String])
    case file(TextFileRecord)
    case download(DownloadRecord)
    case reviewSnapshot(ReviewSnapshotRecord)
    case reviewPatch(PatchSnapshotRecord)
    case runScripts(scripts: [RunScriptRecord])
    case quickPrompts(prompts: [QuickPromptRecord], issues: [SettingsIssueRecord])
    /// `search_code`'s answer. `truncated` says there may be more than were returned.
    case codeMatches(matches: [CodeMatchRecord], truncated: Bool)
    case history(HistoryRecord)
    case commitFiles(files: [ChangedFileRecord])
    case search(SearchRecord)
    case text(String)
    case chat(ChatRecord)
    case recentlyClosed(chats: [ClosedChatRecord])
    /// A `send` that was queued: the prompt's id, which `cancel_queued` names.
    case queued(promptID: String)
    case archivePreview(ArchivePreviewRecord)
    case terminal(TerminalRecord)

    enum Keys: String, CodingKey { case value, paths, scripts, prompts, issues, matches, truncated, files, chats, promptID = "prompt_id" }

    public init(from decoder: any Decoder) throws {
        let kind = try Tagged.kind(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        switch kind {
        case "accepted": self = .accepted
        case "workspace": self = .workspace(try Tagged.record(WorkspaceSnapshotRecord.self, kind: kind, from: decoder))
        case "transcript": self = .transcript(try Tagged.record(TranscriptRecord.self, kind: kind, from: decoder))
        case "composer": self = .composer(try Tagged.record(ComposerRecord.self, kind: kind, from: decoder))
        case "setup_output": self = .setupOutput(try Tagged.record(SetupOutputRecord.self, kind: kind, from: decoder))
        case "files": self = .files(paths: try c.decode([String].self, forKey: .paths))
        case "file": self = .file(try Tagged.record(TextFileRecord.self, kind: kind, from: decoder))
        case "download": self = .download(try Tagged.record(DownloadRecord.self, kind: kind, from: decoder))
        case "review_snapshot": self = .reviewSnapshot(try Tagged.record(ReviewSnapshotRecord.self, kind: kind, from: decoder))
        case "review_patch": self = .reviewPatch(try Tagged.record(PatchSnapshotRecord.self, kind: kind, from: decoder))
        case "run_scripts": self = .runScripts(scripts: try c.decode([RunScriptRecord].self, forKey: .scripts))
        case "quick_prompts":
            self = .quickPrompts(prompts: try c.decode([QuickPromptRecord].self, forKey: .prompts),
                                 issues: try c.decode([SettingsIssueRecord].self, forKey: .issues))
        case "code_matches":
            self = .codeMatches(matches: try c.decode([CodeMatchRecord].self, forKey: .matches), truncated: try c.decode(Bool.self, forKey: .truncated))
        case "history": self = .history(try Tagged.record(HistoryRecord.self, kind: kind, from: decoder))
        case "commit_files": self = .commitFiles(files: try c.decode([ChangedFileRecord].self, forKey: .files))
        case "search": self = .search(try Tagged.record(SearchRecord.self, kind: kind, from: decoder))
        case "text": self = .text(try c.decode(String.self, forKey: .value))
        case "chat": self = .chat(try Tagged.record(ChatRecord.self, kind: kind, from: decoder))
        case "recently_closed": self = .recentlyClosed(chats: try c.decode([ClosedChatRecord].self, forKey: .chats))
        case "queued": self = .queued(promptID: try c.decode(String.self, forKey: .promptID))
        case "archive_preview": self = .archivePreview(try Tagged.record(ArchivePreviewRecord.self, kind: kind, from: decoder))
        case "terminal": self = .terminal(try Tagged.record(TerminalRecord.self, kind: kind, from: decoder))
        default: throw Tagged.unknown(kind, in: decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .accepted: try Tagged.encode(kind: "accepted", to: encoder)
        case .workspace(let value): try Tagged.encode(kind: "workspace", to: encoder, record: value)
        case .transcript(let value): try Tagged.encode(kind: "transcript", to: encoder, record: value)
        case .composer(let value): try Tagged.encode(kind: "composer", to: encoder, record: value)
        case .setupOutput(let value): try Tagged.encode(kind: "setup_output", to: encoder, record: value)
        case .files(let paths): try Tagged.encode(kind: "files", to: encoder); try c.encode(paths, forKey: .paths)
        case .file(let value): try Tagged.encode(kind: "file", to: encoder, record: value)
        case .download(let value): try Tagged.encode(kind: "download", to: encoder, record: value)
        case .reviewSnapshot(let value): try Tagged.encode(kind: "review_snapshot", to: encoder, record: value)
        case .reviewPatch(let value): try Tagged.encode(kind: "review_patch", to: encoder, record: value)
        case .runScripts(let scripts): try Tagged.encode(kind: "run_scripts", to: encoder); try c.encode(scripts, forKey: .scripts)
        case .quickPrompts(let prompts, let issues):
            try Tagged.encode(kind: "quick_prompts", to: encoder)
            try c.encode(prompts, forKey: .prompts); try c.encode(issues, forKey: .issues)
        case .codeMatches(let matches, let truncated):
            try Tagged.encode(kind: "code_matches", to: encoder)
            try c.encode(matches, forKey: .matches); try c.encode(truncated, forKey: .truncated)
        case .history(let value): try Tagged.encode(kind: "history", to: encoder, record: value)
        case .commitFiles(let files): try Tagged.encode(kind: "commit_files", to: encoder); try c.encode(files, forKey: .files)
        case .search(let value): try Tagged.encode(kind: "search", to: encoder, record: value)
        case .text(let value): try Tagged.encode(kind: "text", to: encoder); try c.encode(value, forKey: .value)
        case .chat(let value): try Tagged.encode(kind: "chat", to: encoder, record: value)
        case .recentlyClosed(let chats):
            try Tagged.encode(kind: "recently_closed", to: encoder); try c.encode(chats, forKey: .chats)
        case .queued(let promptID): try Tagged.encode(kind: "queued", to: encoder); try c.encode(promptID, forKey: .promptID)
        case .archivePreview(let value): try Tagged.encode(kind: "archive_preview", to: encoder, record: value)
        case .terminal(let value): try Tagged.encode(kind: "terminal", to: encoder, record: value)
        }
    }
}
