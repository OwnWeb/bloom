import SwiftUI

/// Lets a root view opt into deep links while keeping URL parsing out of feature views.
struct BloomURLHandler: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        content
            // AppKit's URL and open-documents callbacks are the primary routes. SwiftUI can still
            // see the same event, particularly during launch, so it feeds the shared coordinator
            // rather than handling either kind for a second time.
            .onOpenURL { url in
                BloomOpenCoordinator.shared.attach(app)
                BloomOpenCoordinator.shared.receive(url)
            }
            // The delegate attaches as soon as the window exists, which can be before database
            // bootstrap has made project addition available. This second attach is the readiness
            // edge that releases anything macOS delivered during that cold-launch interval.
            .onChange(of: app.isLoaded, initial: true) { _, isLoaded in
                if isLoaded { BloomOpenCoordinator.shared.attach(app) }
            }
    }
}

extension View {
    func handlesBloomURLs(using app: AppModel) -> some View {
        modifier(BloomURLHandler(app: app))
    }
}
