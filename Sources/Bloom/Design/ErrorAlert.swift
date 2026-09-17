import SwiftUI

extension View {
    /// Says that something could not be done, with one OK and nothing else, for as long as a
    /// problem is pending.
    ///
    /// Five places spelled this out as `.alert(title, isPresented: $p.isPresent(), presenting: p)`
    /// with an empty actions builder and a message closure, and the copies had begun to differ in
    /// nothing but their words. The empty actions builder is deliberate rather than an omission: a
    /// single OK that only dismisses is the system default, and spelling one out adds a button
    /// with no job. Dismissing clears the binding through `isPresent()`, so a problem that has been
    /// read does not come back on the next redraw.
    func errorAlert<Item>(
        _ title: String,
        item: Binding<Item?>,
        message: @escaping (Item) -> String
    ) -> some View {
        errorAlert(item: item, title: { _ in title }, message: message)
    }

    /// The same, for a title that names the thing that failed, such as the file a discard was
    /// refused on. The title is read off the pending value rather than off state beside it, so it
    /// cannot describe a different failure from the message under it.
    func errorAlert<Item>(
        item: Binding<Item?>,
        title: @escaping (Item) -> String,
        message: @escaping (Item) -> String
    ) -> some View {
        alert(
            item.wrappedValue.map(title) ?? "",
            isPresented: item.isPresent(),
            presenting: item.wrappedValue
        ) { _ in
        } message: { value in
            Text(message(value))
        }
    }
}
