import Foundation

/// The moment a conversation's history was summarised away, and everything the CLI says about it.
///
/// **The bug: a minute and a half of silence drawn as an agent thinking.** When the window fills,
/// the CLI summarises the history and starts again from the summary. It announces this with a
/// `status` line carrying the single word `compacting`, which Bloom drew in the working row's own
/// slot, beside the running dot, and then nothing arrived for between ninety seconds and two and a
/// half minutes. Measured on this machine across three real compactions: 1m 33s, 2m 05s, 2m 23s.
/// A blue dot that says "Working" for two and a half minutes is indistinguishable from a hang.
///
/// **And the line that says what happened was being thrown away.** When it finishes, the CLI
/// writes a `compact_boundary` carrying the figures, and until now that fell to `AgentEvent`'s
/// `.unknown` and was stored as bytes nobody read. Those figures are the only account of what the
/// model can still remember, which is the one thing a person scrolling back needs to know.
///
/// The stream form, as the CLI's own schema declares it. Only `trigger` and `pre_tokens` are
/// promised; everything under them is optional and a compaction that reports none of them still
/// draws:
///
///     {"type":"system","subtype":"compact_boundary","session_id":"…","uuid":"…",
///      "compact_metadata":{"trigger":"auto","pre_tokens":1000608,"post_tokens":14428,
///                          "cumulative_dropped_tokens":986180,"duration_ms":92822}}
///
/// **The session file on disk spells the same object differently**, in camel case under
/// `compactMetadata`, because the CLI converts between the two shapes on the way in and out. Bloom
/// reads the stream, so the stream's spelling is the one that matters, but both are accepted here:
/// it costs one fallback per field and it means a line lifted out of `~/.claude/projects` for a
/// test decodes the same way as one off the wire.
public struct ContextCompaction: Sendable, Equatable {
    /// Whether the window filled up or somebody typed `/compact`.
    public enum Trigger: String, Sendable, Equatable {
        case auto
        case manual
    }

    public var trigger: Trigger
    /// What was in the window before. The one figure the CLI always sends.
    public var preTokens: Int
    /// What survived, or nil where the line did not say.
    public var postTokens: Int?
    /// Everything compaction has dropped from this chat, this one included, across every
    /// compaction it has done. The CLI's own word for it is cumulative, and it is worth keeping
    /// apart from this compaction's own loss: a chat on its fourth compaction has dropped three
    /// million tokens and this row only moved one.
    public var cumulativeDroppedTokens: Int?
    public var durationMS: Int?
    public var raw: Data
    public var uuid: String?
    public var sessionID: String?

    public init(
        trigger: Trigger,
        preTokens: Int,
        postTokens: Int? = nil,
        cumulativeDroppedTokens: Int? = nil,
        durationMS: Int? = nil,
        raw: Data = Data(),
        uuid: String? = nil,
        sessionID: String? = nil
    ) {
        self.trigger = trigger
        self.preTokens = preTokens
        self.postTokens = postTokens
        self.cumulativeDroppedTokens = cumulativeDroppedTokens
        self.durationMS = durationMS
        self.raw = raw
        self.uuid = uuid
        self.sessionID = sessionID
    }

    // MARK: Decoding

    /// Read a `compact_boundary` line. Nil when the metadata object is missing entirely, which is
    /// the one case the CLI itself refuses: its own adapter logs "Dropping compact_boundary frame
    /// without compact_metadata" and emits nothing. A frame with no figures is a row that would
    /// say a compaction happened and nothing else, and the `.unknown` it falls back to keeps the
    /// bytes for anybody who wants to look.
    public static func decode(_ json: JSONValue, raw: Data) -> ContextCompaction? {
        guard let metadata = json["compact_metadata"] ?? json["compactMetadata"] else { return nil }

        let trigger = metadata["trigger"]?.stringValue.flatMap(Trigger.init(rawValue:)) ?? .auto
        // Nought rather than nil for the one field the schema promises, so a malformed line is a
        // compaction with nothing to say about its size rather than no compaction at all.
        let pre = metadata["pre_tokens"]?.intValue ?? metadata["preTokens"]?.intValue ?? 0

        return ContextCompaction(
            trigger: trigger,
            preTokens: pre,
            postTokens: metadata["post_tokens"]?.intValue ?? metadata["postTokens"]?.intValue,
            cumulativeDroppedTokens: metadata["cumulative_dropped_tokens"]?.intValue
                ?? metadata["cumulativeDroppedTokens"]?.intValue,
            durationMS: metadata["duration_ms"]?.intValue ?? metadata["durationMs"]?.intValue,
            raw: raw,
            uuid: json["uuid"]?.stringValue,
            sessionID: json["session_id"]?.stringValue
        )
    }

    // MARK: Which rows

    private static let probeLength = 256
    private static let marker = Data("\"subtype\":\"compact_boundary\"".utf8)

    /// Whether a stored row is one of these, by its first bytes. `TranscriptRowInk` asks it once
    /// per row per pass, which is why it is a sniff rather than a decode. Same argument, and the
    /// same shape, as `BackgroundWake.isRow`.
    public static func isRow(kind: MessageKind, payload: Data) -> Bool {
        kind == .system && payload.prefix(probeLength).range(of: marker) != nil
    }

    /// Whether the word on a `status` line is the CLI saying it has started compacting.
    ///
    /// The CLI's status enum is `compacting`, `requesting`, or a free string, and Bloom
    /// capitalises whatever arrives before showing it, so this is asked of the label the row is
    /// about to draw rather than of the raw value. Case and surrounding space are ignored for
    /// that reason: `TranscriptModel` has already been at the string by this point.
    public static func isCompacting(status: String) -> Bool {
        status.trimmingCharacters(in: .whitespaces).lowercased() == "compacting"
    }

    // MARK: What the row says

    /// The whole sentence, for VoiceOver and for the one place that wants it in a line.
    public func summary(locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["Compacted"]
        if let size = sizeLabel(locale: locale) { parts.append(size) }
        if let duration = durationLabel { parts.append("in \(duration)") }
        return parts.joined(separator: " ")
    }

    /// `1.0M → 14.4k tokens`, or `1.0M tokens` where the line did not say what survived, or
    /// nothing at all where it did not say what went in either.
    public func sizeLabel(locale: Locale = .autoupdatingCurrent) -> String? {
        guard preTokens > 0 else { return nil }
        let before = Self.tokens(preTokens, locale: locale)
        guard let postTokens else { return "\(before) tokens" }
        return "\(before) → \(Self.tokens(postTokens, locale: locale)) tokens"
    }

    /// The turn footer's own form, so a compaction that took 93 seconds reads the way a turn that
    /// took 93 seconds does.
    public var durationLabel: String? {
        guard let durationMS, durationMS > 0 else { return nil }
        return TurnDuration.wholeSeconds(durationMS)
    }

    /// A token count at a glance: `1.0M`, `14.4k`, `986k`, `620`.
    ///
    /// One decimal is kept below a hundred thousand and dropped above it, because the row is a
    /// boundary rather than a receipt: the reader wants to see that a million became fourteen
    /// thousand, and `986.2k` spends four characters saying nothing they would act on.
    ///
    /// The locale is a parameter with the right default rather than something read inside, for
    /// the reason written at the head of `TurnDuration`: a suite that leaves it to the machine
    /// passes in Brussels and fails in Boston over a comma.
    public static func tokens(_ count: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let value = max(0, count)
        let tenths = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(1))
            .locale(locale)

        if value >= 1_000_000 {
            return "\((Double(value) / 1_000_000).formatted(tenths))M"
        }
        if value >= 100_000 {
            return "\(Int((Double(value) / 1000).rounded()))k"
        }
        if value >= 1000 {
            return "\((Double(value) / 1000).formatted(tenths))k"
        }
        return "\(value)"
    }
}
