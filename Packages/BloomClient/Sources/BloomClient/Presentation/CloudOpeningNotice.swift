import BloomProtocol
import Foundation

/// What a Cloud workspace says in the middle of its own conversation while its machine is being
/// made, and the first message somebody typed at create is waiting for it.
///
/// **One notice where there were two, and the wrong one of the two was winning.** There was a
/// notice for "setup is running" and another for "a message is waiting", and the second drew
/// whenever the machine had not reported a step yet, which is the whole of the first minute. So
/// the screen somebody meets on their first Cloud workspace had the **queue** as its subject: a
/// clock glyph over "Your first message is waiting", while a machine was being made, a repository
/// cloned and an environment read. The owner read it across the room and said the subject was
/// wrong before he said anything else.
///
/// **The workspace is the subject and the message is a line underneath.** The message is not
/// deleted, because it is the one thing the reader did and it is genuinely useful that it will be
/// sent; it is demoted.
///
/// Here rather than beside the view for the usual reason, and one more: the same three sentences
/// have to be chosen the same way by a client drawing a pane and by one drawing a card, and
/// nothing in them is a decision a `View` should be taking.
public struct CloudOpeningNotice: Equatable, Sendable {
    /// **"your workspace", and this is the one place the house voice is broken on purpose.**
    /// Everywhere else the app says "this Cloud workspace", which is the app talking about its own
    /// filing system; here somebody is waiting on a thing that belongs to them.
    public static let title = "Setting up your workspace"

    /// The line under the title: what the reader did, or what is going to happen.
    public var message: String
    /// The live line, drawn with the spinner. What is happening **now**.
    public var progress: String?

    /// What to draw, or nil where the pane's own words are right.
    ///
    /// - Parameters:
    ///   - setup: the machine's setup record, or nil before it has sent one, which is its own
    ///     answer: a workspace whose machine has not reported yet is a workspace being made.
    ///   - log: the setup log so far, for the machine's own newest sentence.
    ///   - heldPrompt: the message typed at create and not yet sent.
    ///
    /// **Nil once setup has an outcome.** A finished, failed or skipped setup is the transcript
    /// row's business, and a second account of it in the middle of an empty pane is the duplication
    /// this type exists to remove.
    public static func of(setup: SetupRecord?, log: String, heldPrompt: String?) -> CloudOpeningNotice? {
        let state = setup?.state
        let isOpening = state == nil || state == "pending" || state == "running"
        guard isOpening, heldPrompt != nil || state != nil else { return nil }
        // **"a few minutes the first time" is said once, wherever there is room for it.** With a
        // message waiting it goes on the live line, because the message's own sentence has the
        // second line; with no message waiting the second line is free and it goes there, so the
        // live line stays the one thing that changes as the machine works.
        let waiting = heldPrompt.map { "Your first message goes as soon as it is ready: “\($0)”" }
        return CloudOpeningNotice(
            message: waiting ?? Self.firstTime,
            progress: progress(setup: setup, log: log, sayingHowLong: waiting != nil)
        )
    }

    /// How long this is going to take, which is what somebody staring at a spinner wants and the
    /// one thing a client can say honestly: it is slower the first time because the machine is
    /// being made, and nothing here can say how much slower.
    private static let firstTime = "This takes a few minutes the first time."

    /// What is happening now, in the order of what is actually known.
    ///
    /// 1. **The machine's own newest sentence**, where it has said something beyond the step's own
    ///    heading: a run starting again because the machine stopped, or a step that has been quiet
    ///    long enough to be worth explaining. **A client writing a parallel sentence for either
    ///    would be signing up to keep two things in step for ever**, and the machine's is better
    ///    because it knows what happened.
    /// 2. **The step**, as the sentence `CloudSetupStep` gives it. An empty log under a named step
    ///    is the ordinary case rather than a stall: two of the seven steps normally print nothing,
    ///    and the machine sets the step before it does the work, so a named step with no output is
    ///    a promise it has already kept.
    /// 3. **Before the machine has said anything at all**, which is where the owner was, the one
    ///    thing that is certainly true: its machine is being made.
    private static func progress(setup: SetupRecord?, log: String, sayingHowLong: Bool) -> String? {
        let step = CloudSetupStep.sentence(setup?.step)
        let heading = step.map { String($0.prefix(1).uppercased() + $0.dropFirst()) }
        if let note = SetupLogVoice.newestNote(in: log, excluding: heading) { return note }
        if let heading { return heading + "." }
        return sayingHowLong ? "Its machine is being made. " + firstTime : "Its machine is being made."
    }
}
