import Foundation

/// What a machine's setup step is called, in the two registers a client needs.
///
/// **One table, because there were two and they had already drifted.** The transcript row said
/// "starting the project's services" and the sidebar said "starting services", which is survivable,
/// and they disagreed about something that is not: **what to do with a step this version has never
/// heard of.** One said it as it stands and the other fell back to a bare "Setting up", so a
/// machine running a newer runner would have named its step in the conversation and gone quiet in
/// the sidebar. The machine gained two steps the evening this was written, `environment` and `git`,
/// which is exactly the case that would have shown it.
///
/// **Two registers rather than one, and that is deliberate.** A transcript row has the width for
/// "cloning the repository" and a sidebar subtitle reads "Setting up: cloning", where the longer
/// form truncates. They are two forms of one fact, so they live on one row of one table and a new
/// step is one line rather than two edits in two files.
///
/// **An unknown step is said as it stands, in both.** A newer runner naming a step this client has
/// never seen is still telling somebody what it is doing, and the raw word is nearly always
/// readable. Silence is the one answer that is certainly wrong.
public enum CloudSetupStep {
    /// The long form, for a sentence or a transcript row: "cloning the repository".
    public static func sentence(_ step: String?) -> String? {
        guard let step = named(step) else { return nil }
        return names[step]?.long ?? step
    }

    /// The short form, for a subtitle with a heading already on it: "cloning".
    public static func short(_ step: String?) -> String? {
        guard let step = named(step) else { return nil }
        return names[step]?.short ?? step
    }

    private static func named(_ step: String?) -> String? {
        guard let step, !step.isEmpty else { return nil }
        return step
    }

    /// The steps a machine runs, in the order it runs them. `environment` and `git` are the two
    /// that were invisible: a new workspace used to sit in `pending` through a call to runbloom.app
    /// and the whole of the git configuration, which is where a measured eighteen minute hang sat.
    ///
    /// **The long form is the machine's own heading, word for word**, and that is a requirement
    /// rather than a nicety. The machine writes a `[bloom] ` line per step, and a client showing
    /// the newest of those under a row already naming the step has to recognise the two as the
    /// same sentence or it says the same thing twice. Three of these were guessed before they were
    /// asked for, and all three guesses were wrong: "preparing the machine", "running the project's
    /// setup" and "resuming", against the machine's three `script` headings. They were the two
    /// longest steps and the one that runs on every wake, which is to say the three somebody is
    /// most likely to be watching. `CloudSetupStepTests` pins all seven against the literals, so a
    /// change on either side fails a suite rather than a person.
    private static let names: [String: (short: String, long: String)] = [
        "environment": ("reading the environment", "reading the team's environment"),
        "git": ("configuring git", "configuring git"),
        "clone": ("cloning", "cloning the repository"),
        "prepare": ("preparing", "running the prepare script"),
        "setup": ("running setup", "running the setup script"),
        "resume": ("resuming", "running the resume script"),
        "services": ("starting services", "starting the project's services"),
    ]
}
