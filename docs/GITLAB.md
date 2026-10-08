# GitLab

Bloom speaks to GitLab through `glab`, the GitLab CLI, the way it speaks to GitHub through `gh`. A
project on GitLab gets the merge request strip, its pipeline's jobs, a failed job's log handed to
the agent, create, ready, rebase and merge through the agent, and workspaces started from a merge
request, in GitLab's own words. Checked against `glab` 1.92.1 and the REST API v4.

The rule every part of it follows: **nothing changes for a project on GitHub.** The one deliberate
exception is the onboarding checks screen, which shows an optional "GitLab CLI" row to everybody.
It never changes the verdict or its sentence.

## Which forge a project uses

`ForgeRouting.decide`, applied to a directory by `ForgeResolver`. First match wins:

| Situation | Forge |
|---|---|
| `git.forge = "github"` or `"gitlab"` in a settings file | as stated |
| Any remote on a host containing `github` (github.com, Enterprise, an SSH alias) | GitHub |
| Base remote on gitlab.com | GitLab |
| Another host, `glab` installed and `glab auth status --hostname <host>` succeeds | GitLab |
| Anything else, including no remote | GitHub |

The answer is cached per directory until git's config or a settings file is written. Where the
config file's own text settles it, which is every GitHub remote and every machine without `glab`,
no process runs at all. The `glab` probe runs at most once per host at a time, a yes is kept for
the launch and a no for five minutes.

## What runs

Reads go through `glab api --hostname <host>` against the REST API, naming the project rather
than letting `glab` guess it from the remotes. `GitLabReads` shares them: one read in flight per
workspace, `maxAge` honoured as on GitHub, and the jobs of a finished pipeline read once.

| Need | Call |
|---|---|
| Merge requests from a branch | `projects/<path>/merge_requests?source_branch=<branch>&state=all` |
| One merge request | `projects/<path>/merge_requests/<iid>` |
| Its pipeline's jobs | `projects/<head_pipeline.project_id>/pipelines/<id>/jobs`, the source project for a fork |
| A failed job's log | `projects/<job's project>/jobs/<id>/trace` |
| Mark ready | `glab mr update <iid> --ready -R <project URL>` |
| Workspace from a merge request | `glab mr checkout <iid> --branch <name> -R <project URL>` |

Creating, merging, rebasing and resolving conflicts are turns sent to the workspace's agent, as on
GitHub. The steps are `GitLabInstructions`: `glab mr create ... --yes`,
`glab mr merge <iid> --yes --auto-merge=false --sha <head>` (without `--auto-merge=false` glab
sets "merge when the pipeline succeeds" instead of merging), and `glab mr rebase <iid>`.

A merge request is found by its source branch, which GitLab keeps after the branch is deleted, so
no number is recorded and no column was added. A fork's merge request with the same branch name is
ignored unless the worktree was checked out from it.

## What GitLab says that GitHub has no word for

`detailed_merge_status` becomes `PullRequest.blockers`: waiting for approval, unresolved threads,
needs rebase, pipeline must pass, and so on. Any blocker turns the merge button off with GitLab's
reason, and an unknown status is read as a refusal, never as mergeable. Needs rebase offers Rebase.
The GitHub decoder never fills `blockers`.

## Settings

- `git.forge`, in the project's settings screen as "Hosted on" when `glab` is installed.
- `git.branch_prefix_type = "gitlab_username"`, the user `glab` is signed in as on the project's
  host, read once per launch from `glab auth status` and again after a sign in.
- Prompt overrides for GitLab live under `prompts.gitLab.<id>`, edited from the GitLab side of the
  prompt settings. A GitHub override never reaches a GitLab project; prompts with no GitLab
  variant are shared.
- `.bloom/pr-instructions.md` and the other instruction files are shared: they are the team's own
  words, and a project uses one forge.

## What stays GitHub's

Creating a repository, the onboarding verdict, the `gh` row and its sign in, App Intents
identifiers, the sidebar legend (it is not about one project), and the tool descriptions an agent
outside a GitLab workspace sees.

## Tests

`Tests/fixtures/gitlab` holds real REST answers from gitlab.com (`gitlab-org/cli`, 2026-10-08),
trimmed to the fields Bloom reads and with authors anonymised. The texts an agent is told on
GitLab are pinned under `Tests/fixtures/characterisation/gitlab-*`, beside GitHub's.
