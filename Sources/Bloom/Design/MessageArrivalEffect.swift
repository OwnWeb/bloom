import BloomCore
import SwiftUI

extension View {
    func messageArrival(_ arrival: MessageArrival?) -> some View {
        modifier(MessageArrivalEffect(arrival: arrival))
    }
}

/// Fades a reply in as it starts to stream. Time belongs to the message, not the hosting cell, so
/// a new view for an arrival already under way picks up where it is and survives the handoff from
/// the streaming slot to the stored row.
///
/// One structure and one explicit animation. This was an `if let` around a
/// `TimelineView(.animation)`, which could rebuild the whole reply on its second token while its
/// markdown `VStack` was growing, and crashed inside SwiftUI's stack layout. Explicit, as in
/// `ArrivingRow`, because the cell root clears implicit animation.
private struct MessageArrivalEffect: ViewModifier {
    let arrival: MessageArrival?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Taken once, when this view is made. Reduce Motion is applied in `settle`, because the
    /// environment cannot be read here.
    @State private var opacity: Double

    init(arrival: MessageArrival?) {
        self.arrival = arrival
        _opacity = State(initialValue: Self.opacity(of: arrival, at: Date()))
    }

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onChange(of: arrival, initial: true) { _, arrival in settle(arrival) }
    }

    private func settle(_ arrival: MessageArrival?) {
        // Text the reader can already see is not faded again.
        guard opacity < 1 else { return }
        let remaining = arrival?.remaining(at: Date()) ?? 0
        guard arrival?.style == .reply, !reduceMotion, remaining > 0 else {
            opacity = 1
            return
        }
        // The cubic ease out `MessageArrival.pose` describes.
        withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: remaining)) { opacity = 1 }
    }

    /// Only a reply fades. Sent bubbles already move in behind the composer, and a second fade
    /// made that look disconnected.
    private static func opacity(of arrival: MessageArrival?, at date: Date) -> Double {
        guard let arrival, arrival.style == .reply else { return 1 }
        return arrival.pose(at: date, reduceMotion: false).opacity
    }
}
