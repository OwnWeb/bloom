import Observation

/// Whether a retained workspace column is the one in front.
///
/// An object rather than an environment Boolean so only the narrow lifecycle helpers that read
/// `isActive` are invalidated when the selected workspace changes. The transcript rows beneath
/// them keep their existing SwiftUI graph and AppKit cells.
@MainActor
@Observable
final class WorkspaceColumnActivity {
    var isActive: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }
}
