import BloomProtocol
import Foundation

/// What a new Cloud workspace shows while it is being built: a short list of steps with the
/// current one alive, what that step is doing right now, and how a failure ended.
///
/// **One account of the whole wait, from the first second.** The window used to draw three
/// different things for it, one after another. A centred hammer and a banner said the same
/// sentence twice while the machine was being made; the pane then went blank for a moment; and
/// what replaced it was the raw setup log with a small grey step name above it, which grew, turned
/// into a grey card half way through and began losing its first lines. Recorded end to end it was
/// four and a half minutes in which nothing said how far along the workspace was. runbloom.app
/// draws the same wait as a list of phases, and the owner put the two side by side.
///
/// **Five steps rather than the machine's seven**, because a list somebody reads at a glance
/// wants the phases a person would name. The machine's own steps are kept, one level down: the
/// line under the current step is the newest heading in the log, so "Running the setup script"
/// says "Installing system packages" and then "Migrating and seeding the database" rather than
/// spinning for two and a half minutes over one label. A step that long with nothing moving under
/// it is what makes a wait feel stuck.
///
/// **`resume` belongs to the last step.** A first run ends with the resume script, which starts
/// the databases and the app, and it ran for a minute in the recording after the setup script had
/// already printed that the project was set up. Leaving it out of the list made the list look as
/// though it had lied; "Starting services" is what it is doing.
///
/// Nil once setup has an outcome that is not a failure: a finished, skipped or ignored setup is the
/// transcript row's business, one line at the head of the conversation.
public struct CloudSetupProgress: Equatable, Sendable {
    public enum StepID: String, CaseIterable, Sendable, Hashable {
        case machine
        case connect
        case clone
        case setup
        case services
    }

    public enum StepState: Equatable, Sendable {
        case done
        case current
        case failed
        case todo
    }

    public struct Step: Equatable, Sendable, Identifiable {
        public var id: StepID
        public var label: String
        public var state: StepState
    }

    public enum Kind: Equatable, Sendable {
        case building
        case failed
    }

    public var kind: Kind
    public var steps: [Step]
    /// What the current step is doing now, in the machine's or the script's own heading: "Installing
    /// system packages". Nil where nothing beyond the step's own label has been said.
    public var activity: String?
    /// The newest line a script printed, as it printed it, so that something visibly moves while a
    /// step works. Nil before anything has been printed in this step.
    public var lastOutput: String?
    /// What went wrong, in the machine's words where it gave any. Only on a failure.
    public var failureNote: String?

    /// The step that is running or that failed.
    public var activeStep: StepID? {
        steps.first { $0.state == .current || $0.state == .failed }?.id
    }

    public var isBuilding: Bool { kind == .building }
    /// Stop is for a run that is going, and a run is only going once the machine has started one.
    public var canStop: Bool
    /// Running again is the way out of a failure, except one a new run cannot fix.
    public var canRunAgain: Bool
    /// A failure is the case where the log IS the message, so its log is open before anybody asks.
    public var opensLogAtFirst: Bool { kind == .failed }

    /// - Parameters:
    ///   - setup: the machine's setup record, or nil before the machine has sent one.
    ///   - log: everything setup has printed so far.
    ///   - isConnected: whether the connection to the machine is up. Before it is, with no setup
    ///     record, the machine is still being made.
    ///   - repository: `owner/name`, for the clone step's label.
    ///   - machineNote: runbloom.app's reason the machine is taking a while, drawn under "Creating
    ///     the machine". Three minutes of that step with nothing under it, while the provider
    ///     refused the create twice, read as a workspace that had stuck.
    public static func of(
        setup: SetupRecord?, log: String, isConnected: Bool, repository: String?, machineNote: String? = nil
    ) -> CloudSetupProgress? {
        guard let setup else {
            return building(
                current: isConnected ? .connect : .machine, includesScripts: true,
                repository: repository, activity: isConnected ? nil : machineNote, lastOutput: nil, canStop: false
            )
        }
        switch setup.state {
        case "pending":
            // The machine has answered and has not said what it is doing yet: it is getting ready to
            // start, which to the person waiting is still connecting to it.
            return building(
                current: .connect, includesScripts: setup.isEnabled,
                repository: repository, activity: nil, lastOutput: nil, canStop: false
            )
        case "running":
            let current = stepID(of: setup.step) ?? .clone
            let recent = SetupLogReading.recent(in: log)
            return building(
                current: current, includesScripts: setup.isEnabled, repository: repository,
                activity: activity(heading: recent.heading, step: setup.step),
                lastOutput: recent.output, canStop: true
            )
        case "failed":
            let failed = stepID(of: setup.step ?? CloudSetupStep.step(forHeading: SetupLogReading.recent(in: log).stepHeading))
            return CloudSetupProgress(
                kind: .failed,
                // A failure with no step to pin it to marks nothing done that may not have happened.
                steps: steps(
                    current: failed ?? .machine, state: failed == nil ? .todo : .failed,
                    includesScripts: setup.isEnabled, repository: repository
                ),
                activity: nil, lastOutput: nil,
                failureNote: failureNote(setup: setup, log: log),
                canStop: false,
                // A clone that failed left nothing to run a script in, so running setup again
                // cannot help; and a machine that says it needs replacing means exactly that.
                canRunAgain: failed != .clone && setup.failureCode != Self.needsFreshMachine
            )
        default:
            return nil
        }
    }

    /// The card's heading: what is happening while it is being built, and the step that failed
    /// once it has, because that is the first thing somebody needs to know next.
    ///
    /// Not the workspace's name. It was "Setting up \(name)", directly under a window title that
    /// already says the name, and a name in the middle of a sentence read as a stray capital
    /// ("Setting up This is a test").
    public var title: String {
        guard kind == .failed else { return "Setting up the workspace" }
        switch activeStep {
        case .clone: return "Cloning failed"
        case .setup: return "The setup script failed"
        case .services: return "Starting services failed"
        default: return "Setup failed"
        }
    }

    /// The code the machine sends when only a brand new machine can run setup again.
    public static let needsFreshMachine = "setup_needs_fresh_machine"

    /// Which of the five steps each of the machine's steps belongs to. An unknown step is a
    /// project's script by elimination: the machine's own steps are the ones before it.
    public static func stepID(of machineStep: String?) -> StepID? {
        guard let machineStep, !machineStep.isEmpty else { return nil }
        switch machineStep {
        case "environment", "git", "clone": return .clone
        case "prepare", "setup": return .setup
        case "resume", "services": return .services
        default: return .setup
        }
    }

    public static func label(of id: StepID, repository: String?) -> String {
        switch id {
        case .machine: "Creating the machine"
        case .connect: "Connecting to the machine"
        case .clone: repository.map { "Cloning \($0)" } ?? "Cloning the repository"
        case .setup: "Running the setup script"
        case .services: "Starting services"
        }
    }

    // MARK: - Building it

    private static func building(
        current: StepID, includesScripts: Bool, repository: String?,
        activity: String?, lastOutput: String?, canStop: Bool
    ) -> CloudSetupProgress {
        CloudSetupProgress(
            kind: .building,
            steps: steps(current: current, state: .current, includesScripts: includesScripts, repository: repository),
            activity: activity, lastOutput: lastOutput, failureNote: nil,
            canStop: canStop, canRunAgain: false
        )
    }

    /// The steps that are real for this workspace, the one at `current` in `state`, those before it
    /// done and those after it still to come. A workspace created without setup has no scripts to
    /// run, so it has neither of the last two steps.
    private static func steps(current: StepID, state: StepState, includesScripts: Bool, repository: String?) -> [Step] {
        let ids = StepID.allCases.filter { includesScripts || ($0 != .setup && $0 != .services) }
        let at = ids.firstIndex(of: current) ?? 0
        return ids.enumerated().map { index, id in
            Step(
                id: id, label: label(of: id, repository: repository),
                state: index < at ? .done : index == at ? state : .todo
            )
        }
    }

    /// The line under the current step, unless it only repeats the step's own label. "Cloning the
    /// repository" under "Cloning spatie/there-there" says it twice; "Running the prepare script"
    /// under "Running the setup script" does not, because prepare is a script of its own.
    private static func activity(heading: String?, step: String?) -> String? {
        guard let heading else { return nil }
        let repeats: Set<String> = ["clone", "setup", "services"]
        if let step, repeats.contains(step), let own = CloudSetupStep.sentence(step),
           SetupLogReading.plain(heading) == SetupLogReading.plain(own) {
            return nil
        }
        return heading
    }

    /// The machine's own account of a failure where it sent one, and otherwise the last line of
    /// the log that is not blank, which is where a script's error nearly always is.
    private static func failureNote(setup: SetupRecord, log: String) -> String? {
        if let note = setup.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note.replacingOccurrences(of: " (\(needsFreshMachine))", with: "")
        }
        let recent = SetupLogReading.recent(in: log)
        return recent.output ?? recent.heading
    }
}

/// What the newest lines of a setup log say, read from the end.
///
/// Three things, all taken in one pass backwards and each only from the current step: the newest
/// heading, which is a `[bloom] ` sentence or a script's own `==> ` line; the newest line of plain
/// output; and the newest step heading of the machine's, which is where a failure without a step
/// on the record stopped.
enum SetupLogReading {
    struct Recent: Equatable {
        var heading: String?
        var output: String?
        var stepHeading: String?
    }

    /// What a script puts in front of a heading of its own. Homebrew's convention, which setup
    /// scripts written in its style follow, and the one the recorded project's script used.
    static let scriptHeading = "==> "

    static func recent(in log: String, limit: Int = 400) -> Recent {
        var recent = Recent()
        var seen = 0
        // Split on every kind of line end, a bare carriage return included: a progress bar redraws
        // itself with those, and read from the end its last drawing comes first, which is what a
        // terminal would be showing. `"\r\n"` is one `Character` in Swift, so splitting on `"\n"`
        // alone would leave a log with Windows line ends in one piece.
        for raw in log.split(whereSeparator: \.isNewline).reversed() {
            seen += 1
            if seen > limit { break }
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if SetupLogVoice.isBloom(line) {
                let said = sentence(SetupLogVoice.spoken(line))
                if CloudSetupStep.step(forHeading: said) != nil {
                    // A step heading ends the current step, reading backwards: nothing above it
                    // belongs to what is running now.
                    recent.stepHeading = said
                    if recent.heading == nil { recent.heading = said }
                    break
                }
                if recent.heading == nil { recent.heading = said }
            } else if trimmed.hasPrefix(scriptHeading) {
                if recent.heading == nil {
                    recent.heading = sentence(String(trimmed.dropFirst(scriptHeading.count)))
                }
            } else if recent.output == nil, recent.heading == nil {
                recent.output = trimmed
            }
        }
        return recent
    }

    /// A heading as a label: its surrounding space and its full stop taken off.
    static func sentence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    static func plain(_ text: String) -> String {
        sentence(text).lowercased()
    }
}
