# Browser client contract

Bloom Dev's browser client is another view of the running Mac app. The Mac process owns the store, worktrees, agents, and permissions.

Use **File > Open Bloom in Browser** or the button in Settings > Browser Access on this Mac. Bloom opens the current port with a one-use link, exchanges it for the current access code, and removes the link from the browser address bar. The manual address and code remain in Settings for other browsers.

## Shared decisions

| Behaviour | Source used by both clients |
| --- | --- |
| Project validation | `ProjectTargetVerdict`, `NewProjectStarter`, `ProjectAddTool` |
| Workspace creation | `WorkspaceStartTool` and `AppModel.startWorkspaceForBridge` |
| Workspace chat creation | `ChatCreateTool` and `AppModel.createChatForBridge` |
| Standalone conversations | `AskModel` |
| Transcript interpretation | `TranscriptClientRow`, `MarkdownHTML`, `TranscriptPresenter` |
| File references | `SourceReference`, `FileChipTarget`, `ContainedPath` |
| Colours and reading font | `ColourThemePreference`; layout measurements from `Metrics` |
| Changed files | `Git.changedFiles` with the workspace's base branch |

Keep new provider parsing and state rules in BloomCore. The HTTP routes should validate input, call the same command as the Mac app, and return small client models. Transcript pages carry a schema version. Avoid teaching JavaScript how to parse agent event payloads.

## Parity check for changes

When a Mac change affects the sidebar, transcript, composer, or inspector, check the browser at desktop and phone widths. Verify project creation, workspace creation, chat creation, standalone conversations, prompts, file references, and changed files. Add a BloomCore projection test for each new transcript row or reference type. CI parses the embedded browser JavaScript and checks the one-use connection flow. The app must also pass `make build`, `make lint`, and `make swiftlint`.

The browser currently previews text and common image files, shows changed file summaries, and answers ordinary permission requests once or denies them. The Mac app still has richer native diff review, attachment staging, plan and question responses, terminal panes, and browser panes. Those should be added through shared commands or client models before claiming full feature parity.
