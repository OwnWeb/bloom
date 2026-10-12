import Foundation

/// The router's decision, stored as a `.notice` row so it survives a relaunch at the head of the
/// chat. Not drawn as its own row: the session start row reads it, so the model is not named
/// twice. See `TranscriptModel.routeNote(forSessionStartAt:)`. A rung picked by hand writes one
/// too, with no analyser.
public struct ModelRouteNote: Sendable, Hashable {
    public let route: ModelRoute
    /// Nil when the owner picked the rung.
    public let analyser: String?

    public init(route: ModelRoute, analyser: String?) {
        self.route = route
        self.analyser = analyser
    }

    static let subtype = "model_route"
    private static let marker = Data(#""subtype":"model_route""#.utf8)

    private struct Stored: Codable {
        var type = "bloom_note"
        var subtype = ModelRouteNote.subtype
        let complexity: TaskComplexity
        let model: String
        let effort: String
        let reason: String
        let analyser: String?
    }

    public var payload: Data {
        let stored = Stored(
            complexity: route.complexity, model: route.model, effort: route.effort,
            reason: route.reason, analyser: analyser
        )
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    /// Nil when a `.notice` row is something else, such as a rate limit. A byte search first,
    /// because nearly every notice is a rate limit event and this is asked of all of them.
    public init?(note payload: Data) {
        guard payload.range(of: Self.marker) != nil,
              let stored = try? JSONDecoder().decode(Stored.self, from: payload),
              stored.subtype == Self.subtype else { return nil }
        route = ModelRoute(
            complexity: stored.complexity, model: stored.model,
            effort: stored.effort, reason: stored.reason
        )
        analyser = stored.analyser
    }

    public var detail: String {
        guard let analyser else { return "\(route.complexity.label), picked by hand." }
        let chosen = "\(route.complexity.label) task, chosen by \(analyser)."
        return route.reason.isEmpty ? chosen : "\(chosen) \(route.reason)"
    }

    /// Which session start row carries which note, and which one offers Change.
    public struct Placement: Equatable, Sendable {
        /// Keyed by the session start row's seq.
        public var notes: [Int: ModelRouteNote] = [:]
        public var offer: Offer?

        public struct Offer: Equatable, Sendable {
            public var sessionStartSeq: Int
            /// What Change sends again.
            public var opening: String
        }
    }

    /// One pass over the stored rows. A note belongs to the next session start, and a session
    /// start with no note since the previous one carries none. Change is offered on the newest
    /// carrier only, while every user turn is the opening (earlier changes sent the same words)
    /// and nothing waits in the queue: a queued message would otherwise go first, on the new model.
    public static func placement<Rows: Sequence>(in rows: Rows, isQueueEmpty: Bool) -> Placement
    where Rows.Element: ModelRouteNoteRow {
        var placement = Placement()
        var waiting: ModelRouteNote?
        var newestCarrier: Int?
        var opening: String?
        var saidOnlyTheOpening = true
        for row in rows {
            switch row.kind {
            case .notice:
                if let note = ModelRouteNote(note: row.payload) {
                    waiting = note
                    newestCarrier = nil
                }
            case .user where saidOnlyTheOpening:
                let prompt = UserTurnPrompt.text(in: row.payload)
                if opening == nil { opening = prompt } else if prompt != opening { saidOnlyTheOpening = false }
            default:
                if let note = waiting, TranscriptRowInk.isSessionStart(kind: row.kind, payload: row.payload) {
                    placement.notes[row.seq] = note
                    newestCarrier = row.seq
                    waiting = nil
                }
            }
        }
        if let newestCarrier, let opening, saidOnlyTheOpening, isQueueEmpty {
            placement.offer = Placement.Offer(sessionStartSeq: newestCarrier, opening: opening)
        }
        return placement
    }

    /// Narrowed the way the router's own answer was, so a pick by hand lands on a model the account
    /// can run.
    public static func choices(
        table: ModelRouterTable,
        backend: AgentKind,
        current: String,
        models: [AgentModel]
    ) -> [ModelRoute] {
        TaskComplexity.allCases.map { rung in
            ModelRouting.route(
                ModelRouterAnswer(complexity: rung, reason: ""),
                table: table, backend: backend, current: current, models: models
            )
        }
    }
}

/// A stored row, as `ModelRouteNote.placement` reads it.
public protocol ModelRouteNoteRow {
    var seq: Int { get }
    var kind: MessageKind { get }
    var payload: Data { get }
}
