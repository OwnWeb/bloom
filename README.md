# Bloom

Bloom is a native macOS app for working with coding agents in Git worktrees. Each workspace has its
own branch and directory. The app puts conversations, terminals, a browser, changed files and pull
requests in one window.

[![Tests](https://github.com/spatie/bloom/actions/workflows/test.yml/badge.svg)](https://github.com/spatie/bloom/actions/workflows/test.yml)
[![Latest release](https://img.shields.io/badge/dynamic/xml?url=https%3A%2F%2Fdownloads.runbloom.app%2Fappcast.xml&query=%2F%2Fitem%5B1%5D%2Ftitle&label=release&style=flat-square)](https://runbloom.app/download)

## Install

Bloom requires macOS 26 or later. Install the signed and notarised app with Homebrew:

```bash
brew install --cask spatie/bloom/spatie-bloom
```

Or [download the disk image](https://runbloom.app/download) and drag Bloom to Applications. Sparkle
checks for updates from inside the app.

Install at least one supported agent CLI on your Mac: [Claude Code](https://claude.com/claude-code)
(`claude`), [Codex](https://developers.openai.com/codex/cli) (`codex`), or Grok (`grok`). Bloom uses
the CLI you choose for each conversation. Git is required; [GitHub CLI](https://cli.github.com)
(`gh`) enables pull request and checks features. Cursor and OpenCode can be detected in Settings but
cannot run conversations yet.

Bloom keeps its workspaces and conversation database on your Mac. It does not require a Bloom
account. Agent CLIs use their own authentication and provider connections.

## Work with Bloom

1. Add a Git repository as a project.
2. Create a workspace for a task. Bloom creates a branch and worktree, copies configured files, runs
   the project's setup script and starts the chosen agent. You can also open an existing branch or
   pull request, or start with a terminal.
3. Follow the conversation, inspect changed files and review the diff against the merge base. Open a
   terminal or browser beside the chat when you need one.
4. Create or merge a pull request from the workspace. Archive the workspace when the work is
   finished.

Workspaces live under `~/bloom/workspaces.noindex` by default. The `.noindex` suffix keeps Spotlight
from indexing every worktree. Bloom also supports multiple chats in one workspace, reusable quick
prompts and subagents that work in the same branch. **Ask Bloom** is a separate conversation area
for questions that do not need a worktree.

Useful shortcuts include Cmd+N for a new workspace, Cmd+P to search files in the current workspace
and Cmd+T for a new conversation. See [the menu reference](docs/MENUS.md) for the full list.

### Repository settings

Configure a project in `.bloom/settings.toml`. Put machine specific values in
`.bloom/settings.local.toml`. Both can be edited from the project's settings screen. Supported
settings include setup and archive scripts, named run scripts, files to copy, branch naming, the
browser address and default models.

```toml
[scripts]
setup_file = ".bloom/setup.sh"
archive_file = ".bloom/archive.sh"

[browser]
url = "http://localhost:$BLOOM_PORT"
```

A script named by `setup_file` or `archive_file` runs in the worktree. Setup runs after creation;
archive must succeed before Bloom removes the worktree. Inline `scripts.setup` and `scripts.archive`
are also supported. Bloom supplies `BLOOM_WORKSPACE_ID`, `BLOOM_WORKSPACE_PATH`, `BLOOM_ROOT_PATH`,
`BLOOM_DEFAULT_BRANCH`, `BLOOM_PORT` and other [workspace variables](Sources/BloomCore/Workspace/WorkspaceScriptVariables.swift).

A browser pane normally opens `http://localhost:$BLOOM_PORT`. Set `browser.url` as above or write an
address to the file named by `BLOOM_URL_FILE` from your setup script. The file is ignored by Git and
read when a browser pane opens.

### Agent bridge

Workspace agents can ask Bloom to open panes, read the browser or terminal, show media, manage
subagents and work with projects and workspaces through an MCP bridge. The bridge scopes a workspace
agent to its own worktree. You can also register it in your own MCP client from Settings. See [the bridge reference](docs/BRIDGE.md) for tools and permissions.

## Build from source

Install Xcode 26 and an agent CLI, then clone the repository:

```bash
git clone https://github.com/spatie/bloom.git
cd bloom
make dev-fast
```

This installs `~/Applications/Bloom Dev.app`. The dev app has its own database, preferences and URL
scheme, so it can run beside a released copy. `make dev-fast` builds current edits; `make dev`
builds committed `HEAD`. Use `./Tools/dev-build.sh --fast --no-install` to compile without
installing or launching.

`Package.swift` is the Xcode entry point. There is no Xcode project. The [architecture guide](docs/ARCHITECTURE.md) explains the `BloomCore`, `Bloom` and bridge targets.
[AGENTS.md](AGENTS.md) indexes the project skills and [CLAUDE.md](CLAUDE.md) contains the
development rules shared by agents and contributors.

```bash
make build       # Compile all targets with warnings treated as errors
make lint        # Check project rules
make swiftlint   # Check Swift style
```

The core tests run through `./Tools/test-core.sh <filter>` or `make test`. They do not compile the
app target, so also run `make build` when changing code. Follow the local test guidance in
[CLAUDE.md](CLAUDE.md) when working on the owner's machine.

## Documentation

- [Architecture and contributing](docs/ARCHITECTURE.md)
- [Agent integration](docs/AGENTS-INTEGRATION.md)
- [Claude Code protocol](docs/PROTOCOL.md), [Codex protocol](docs/CODEX.md), [Grok protocol](docs/GROK.md)
- [MCP bridge](docs/BRIDGE.md)
- [Release process](RELEASING.md)

## Support and licence

Bloom is free, open source and postcardware. If you use it, [send us a postcard](https://spatie.be/about-us) from your hometown and tell us what you are building. We share
them on our [postcard wall](https://spatie.be/open-source/postcards). You can also [support Spatie's open source work](https://spatie.be/open-source/support-us).

See [CONTRIBUTING](https://github.com/spatie/.github/blob/main/CONTRIBUTING.md) to contribute.
Report security issues to [security@spatie.be](mailto:security@spatie.be). Bloom is licensed under
[MIT](LICENSE.md).
