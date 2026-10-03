import Foundation

/// What the transcript is allowed to animate, and for how long.
///
/// Three different things get called "text appearing in the chat window" and they do not want the
/// same treatment, so the rules for telling them apart live here rather than inside a view where
/// nothing could test them.
///
/// **A row landing in the list fades.** A tool call, a result, a turn footer, a notice. It lands
/// where a "Running Bash" line was and it reads better as a settle than as a pop. `fadesOnArrival`
/// is that rule, and `RowArrival` in the app is the mechanism.
///
/// **A block of streamed prose fades once, when the block first has anything in it.** Not per
/// delta. A delta is a handful of characters arriving many times a second, and a fade started on
/// each one is a shimmer at the tail of the answer, which is a good deal worse than the pop it
/// would be replacing. So the fade belongs to the block rather than to the text, and there is
/// nothing here to decide per delta: see `StreamingRowView`.
///
/// **Keeping up with the end of a running turn is `TranscriptFollow`**, which is a fourth thing
/// and is not here: it is a rule about where the view sits rather than about how a row is drawn,
/// and it has to answer per frame rather than per arrival.
///
/// **A session's history does not fade at all.** Eighty rows fading up as a window opens reads as
/// the app being slow rather than as anything arriving, and it is not work turning up in front of
/// the reader, it is the pane being pointed somewhere else. That rule is `RowArrival.adopt` and
/// `TranscriptListView.arrivalSession`, which is a piece of bookkeeping rather than a decision, so
/// it is not restated here.
public enum TranscriptMotion {
    /// Whether a stored row of this kind is new on the frame it lands, and therefore worth fading.
    ///
    /// Prose and thinking are not. Both are streamed live first and stored afterwards, and the
    /// streaming views are lined up column for column with their stored twins precisely so that
    /// nothing moves when one replaces the other. Fading the stored row in would undo exactly
    /// that: the answer the reader is halfway through would go out and come back over a fifth of a
    /// second, which is the jump those columns exist to avoid.
    ///
    /// Nor is a user turn. The sentence is drawn from the queue the instant Return is pressed and
    /// the stored row replaces it in the same place at the same measure, so fading it in would
    /// take the owner's own message away and bring it back, which is the flicker the instant echo
    /// exists to remove.
    ///
    /// These three use `MessageArrivals` instead: one clock shared across the temporary and
    /// saved drawings, so persisting a message does not restart its effect.
    /// Everything else genuinely arrives.
    ///
    /// **The second list is written out rather than left to a `default`.** The three above are
    /// exceptions earned by a measurement each, so a kind added to `MessageKind` and not thought
    /// about here is a kind given the fade by accident. `.crew` reached this by falling through
    /// when it was added, and it is right, which is the point: it should be right because somebody
    /// said so, not because the `default` said so first.
    public static func fadesOnArrival(_ kind: MessageKind) -> Bool {
        switch kind {
        case .assistantText, .thinking, .user: false
        case .toolUse, .toolResult, .permissionAsk, .result, .error, .system, .notice, .crew: true
        }
    }

    // MARK: - Settling onto the screen

    /// How something that has only just turned up settles onto the screen.
    ///
    /// **Opacity paired with a small rise, rather than opacity alone.** Opacity on its own was
    /// filmed at 58 frames a second against a real streaming turn, and it is there and it is
    /// correct: eleven frames of monotonic ease out over 172ms. It is also 0.27 of one luminance
    /// level deep across the strip it lands in, against 8.65 for the ordinary stream delta that
    /// lands in the same strip half a second later. A settle a thirtieth the weight of the thing
    /// beside it is not a settle anybody sees. A few points of travel costs nothing per frame, it
    /// animates one more attribute of the same one-shot rather than adding a second animation,
    /// and it is what carries the sense of having arrived from somewhere.
    ///
    /// The rise is drawn rather than laid out: nothing below the row moves, nothing reflows, and
    /// the list never learns that anything happened. See `ArrivingRow`.
    ///
    /// Short, and only a little longer than the opacity-only settle it replaces. What is being
    /// marked is a row landing, which is a smaller event than a pane travelling, and a fifth of a
    /// second of it is the difference between reading as a settle and reading as an effect.
    public struct Arrival: Equatable, Sendable {
        /// How long the settle takes.
        public let seconds: Double

        /// How far below its resting place the content starts, in points.
        public let rise: Double
    }

    /// The settle a row or a block gets when it turns up, or nothing at all.
    ///
    /// Reduce Motion drops it rather than slowing it, which is what every other call site in this
    /// app does: the setting is about movement, and there is no slower version of this worth
    /// having. An absence rather than a zero, so that a caller cannot honour half of it. A caller
    /// that kept the zero opacity and dropped the curve would hide the row and never bring it
    /// back, which is exactly the bug the shape of this answer rules out.
    public static func arrival(reduceMotion: Bool) -> Arrival? {
        guard !reduceMotion else { return nil }
        // Was 0.22 and 5 points, which measured as a settle in a capture and read as a pop in
        // use: the owner's report was that rows "appear suddenly", watching real turns on a real
        // machine, which is the measurement that counts. A tool row is only about 28 points tall,
        // so a five point rise was under a fifth of the row and near the floor of what the eye
        // resolves against text that is already moving.
        //
        // **The travel does the work here, not the length.** Ten points is twice the rise and
        // reads as a landing; the length moved only from 0.22 to 0.25, and deliberately no
        // further. Three invariants are chained to this number and the suite holds all three:
        // `TranscriptMotionTests` keeps the travel under twelve points, because past that a
        // settle stops being a landing and becomes a slide; `ProjectVisibilityMotion` is pinned
        // to this length so one confirmation does not read as three apps; and
        // `SubagentRetention.lingerSeconds` has to stay ten times it, so a longer settle would
        // have silently held every finished subagent row on screen for longer. A quarter of a
        // second is the most this can take without dragging that behaviour along with it.
        return Arrival(seconds: 0.25, rise: 10)
    }

    /// How long a row takes to unfold when it is clicked open, and to fold back.
    ///
    /// The same length a row settles in, taken from `arrival` rather than written again, so the
    /// two cannot drift: unfolding a tool result and a tool result landing are both "something
    /// you just did has landed", and this app answers that in one length everywhere. See
    /// `ProjectVisibilityMotion`, which is pinned to the same number for the same reason.
    ///
    /// Nothing under Reduce Motion, and absent rather than zero for the reason `arrival` is: a
    /// caller cannot then honour half of it and leave a row folded open with no height.
    public static func disclosure(reduceMotion: Bool) -> Double? {
        arrival(reduceMotion: reduceMotion)?.seconds
    }
}
