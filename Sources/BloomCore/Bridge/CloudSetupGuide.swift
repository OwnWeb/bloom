import Foundation

/// What an agent is told when it is asked to make a project work on a Cloud workspace.
///
/// **Every section here was paid for.** A project collided with Bloom Runner's own port and
/// crash-looped for an afternoon in a log nobody was reading; a service waited for ever on a
/// dependency that never became ready, never failing and never restarting; a preview showed a white
/// rectangle because the app served a port the preview does not read. None of it was deducible, and
/// all of it was known to the machine. The briefing in `BridgeBriefing` closed the same gap for
/// panes; this closes it for setup.
///
/// **Written as what somebody needs, not as an answer to anybody else's list.** The test it is held
/// to: an agent handed a project that has never run on a machine reads this and makes it work
/// without discovering anything by collision.
public enum CloudSetupGuide {
    public static let text = """
        # Making a project work on a Bloom Cloud workspace

        **A project can be perfectly happy on a Mac and collide on its first machine.** Locally the \
        ports are free, there are no services, and nothing enforces any of this. **The cheapest \
        moment to get it right is before the first machine exists**, which is where this is worth \
        most; the second cheapest is on the machine, with a terminal open.

        Everything below is `.bloom/settings.toml` in the repository: `[scripts]` with `prepare`, \
        `setup` and `resume` (or `prepare_file`, `setup_file`, `resume_file` naming a script in the \
        repository), and `[[services]]`.

        ## There are two lifecycles, not three

        `prepare`, `setup` and `resume` read like three stages. **`prepare` and `setup` run once, in \
        that order. `resume` runs at every start, for ever**, including after every sleep, wake and \
        restart, and the services start after the last step on every start.

        "Once" means once per *completed* sequence: **a machine stopped in the middle of setup runs \
        the whole sequence again at its next start**, `prepare` included.

        The split between `prepare` and `setup` is by subject rather than by lifetime: what the \
        machine needs installed, then what this project needs doing. **The one that matters is \
        `resume`**, because it is on the path of every wake. Anything that installs belongs one line \
        up from it.

        ## Setup is written for a second run you will not witness

        Not "ideally idempotent": a machine restarted mid-setup does it all again, against a \
        filesystem where half of it already happened. `mkdir` without `-p`, a migration that assumes \
        an empty database, a clone into a directory that now exists. **Write it so the second run is \
        as correct as the first**, and check by running it twice rather than by reading it twice.

        ## Ports

        **Serve on `$BLOOM_APP_PORT`, never a literal.** That is the port the preview reads, and it \
        is the only one a person sees.

        **`$BLOOM_RESERVED_PORTS` lists what is already taken on the machine**: 8080 is the preview \
        proxy and 8081 is the server you are talking to. A project that asks for one of those dies \
        with `Address already in use`, restarts a second later, and does it for ever in a service log \
        nobody is reading. If the project needs more than one port, none of them may be those.

        ## Anything long-running is a service, not a script

        A command that does not return belongs in `[[services]]`. In `setup` it would hold the step \
        until the step's timeout and then be killed.

        A service has a stable lowercase `id`, a display `name`, a `command`, an optional `ready` \
        and an optional `depends_on` containing service ids. \
        **`http = true` marks the one the preview routes to**. `ready` is what decides that a service \
        counts as up, such as `http:/up`.

        **If you write `depends_on`, write a `ready` that can actually pass.** A service starts only \
        once everything it depends on is *ready*, not merely launched, so **a service whose \
        dependency never passes its check is never started, never fails and never restarts.** It \
        waits, silently, for as long as the machine lives.

        ## Nothing has a terminal, and nothing may ask a question

        No TTY, no person at the other end, and git is told never to prompt. **An interactive prompt \
        is not an error here, it is a step that hangs** until its timeout: an hour for `prepare` and \
        `setup`, ten minutes for `resume`, thirty for the clone. **A step that hangs looks exactly \
        like a step that is working.**

        ## The environment is in the process, not on disk

        Team and project variables are handed to every script and service and **are never written to \
        a file**. A project that expects a `.env` has to write one from what it was given.

        Beside them: `BLOOM_APP_PORT`, `BLOOM_PUBLIC_URL`, `BLOOM_PUBLIC_HOST`, \
        `BLOOM_RESERVED_PORTS`, `BLOOM_WORKSPACE_ID`, `BLOOM_BRANCH`, `BLOOM_REPOSITORY`, \
        `BLOOM_DATA_DIR`, and the ones a Mac workspace also gets: `BLOOM_IS_LOCAL` (`0` on a \
        machine), `BLOOM_ROOT_PATH`, `BLOOM_WORKSPACE_PATH`, `BLOOM_WORKSPACE_NAME`, \
        `BLOOM_PROJECT_NAME`, `BLOOM_DEFAULT_BRANCH`, `BLOOM_PORT`.

        **`BLOOM_PUBLIC_HOST` is the one people miss.** A dev server that allow-lists hosts, as Vite \
        does, shows nothing at all until the machine's own host is on that list.

        ## The setup log is a page, and everybody with access reads it

        It is what somebody watches while the workspace is being made, and a failed run's last lines \
        are shown beside the workspace. **Anything echoed into it has been shared with the team**, so \
        nothing prints a token, and no authentication of yours belongs in a setup script.

        ## A fix on this branch fixes this workspace and nobody else's

        The settings are read from the worktree, which is **this workspace's branch**, and there is \
        no override outside the repository. So **a new workspace starts from what the base branch \
        has: nothing is fixed for anybody else until it is merged.** An agent that iterates happily \
        on its own branch and reports the project "working on Cloud" has fixed it for one workspace.

        The useful half of the same fact: a change committed here takes effect at this machine's next \
        start, so the scripts can be got right against the real thing before the merge.

        ## A workspace can be created with setup turned off

        Then the repository is cloned and nothing else runs: no scripts, no services, and the \
        workspace says `skipped` rather than going quiet. **That is somebody's choice, not a \
        failure.** Do not quietly run setup by hand to "fix" it.

        ## How to check, rather than guess

        - **Run setup again** and watch the log. This is the check that matters, for the reason above.
        - **Open a terminal.** It is a real login shell on this machine, with the same environment.
        - `curl 127.0.0.1:$BLOOM_APP_PORT` to see what the preview will see.
        - **Open the preview when it is blank**: the page lists every service with its state, and \
        says when nothing is listening on the app port.

        ## How long it takes

        There is no target. A real project measured **485 seconds** for a first setup on a cold \
        machine, and that was healthy: packages, three installs and a database. **The only number \
        worth optimising is `resume`**, because it runs on every wake. A first setup takes as long as \
        the project takes.
        """
}
