import Testing
@testable import BloomProtocol

/// What each operation needs from a token, as a table somebody has to change on purpose.
///
/// `WorkspaceOperation.ability` is the only thing between a `view` token and a mutating operation,
/// and it once ended in `default: "view"` (L1 in the review of 19 September 2026). The switch is
/// exhaustive now, so a new case cannot compile without a decision; this makes that decision
/// visible in a diff, and checks it against every kind the vectors hold.
@Suite struct OperationAbilityTests {
    static let table: [String: String] = [
        "workspace": "view", "transcript": "view", "composer": "view", "setup_output": "view",
        "files": "view", "file": "view", "download": "view", "review_snapshot": "view",
        "review_patch": "view", "run_scripts": "view", "quick_prompts": "view", "search_code": "view",
        "history": "view", "commit_files": "view", "commit_patch": "view", "transcript_search": "view",
        "notes": "view", "pull_request": "view", "recently_closed": "view", "mark_read": "view",
        "send": "prompt", "cancel_queued": "prompt", "stop": "prompt", "answer": "prompt",
        "new_chat": "prompt", "close_chat": "prompt", "reopen_chat": "prompt", "rename_chat": "prompt", "set_composer": "prompt",
        "write_file": "files", "upload_file": "files", "commit": "files", "push": "files",
        "create_pull_request": "files", "save_notes": "files", "rename_workspace": "files",
        "run_setup": "files", "stop_setup": "files", "continue_after_merge": "files",
        "revert_file": "files", "discard_hunk": "files",
        "run_script": "terminal", "close_terminal": "terminal",
        "archive": "share", "archive_preview": "share",
    ]

    @Test func everyOperationNeedsWhatTheTableSays() {
        let kinds = Set(WireExamples.operations.map(\.1.kind))
        #expect(kinds == Set(Self.table.keys), "an operation is missing from the table, or the table names one that no longer exists")
        for (name, operation) in WireExamples.operations {
            #expect(operation.ability == Self.table[operation.kind], "\(name)")
        }
    }

    /// The one mutating operation a viewer may run: marking their own place in a chat as read.
    @Test func nothingThatChangesTheWorkspaceIsOpenToAViewer() {
        for (name, operation) in WireExamples.operations where operation.mutates && operation.kind != "mark_read" {
            #expect(operation.ability != "view", "\(name) changes something and asks only for view")
        }
    }
}
