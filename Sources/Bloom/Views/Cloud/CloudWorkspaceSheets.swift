import BloomCore
import SwiftUI

/// The window's Cloud workspace sheets, in one modifier so `RootView`'s chain grows by one line.
struct CloudWorkspaceSheets: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var cloud = app.cloud
        content
            .sheet(isPresented: $cloud.isCreating) {
                CreateCloudWorkspaceSheet()
            }
            .sheet(isPresented: Binding(
                get: { cloud.archiving != nil },
                set: { if !$0 { cloud.archiving = nil } }
            )) {
                if let id = cloud.archiving { CloudArchiveSheet(id: id) }
            }
    }
}
