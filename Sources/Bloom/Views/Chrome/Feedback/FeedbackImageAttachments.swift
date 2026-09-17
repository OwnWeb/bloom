import AppKit
import SwiftUI
import BloomCore

/// The pictures on both Help menu sheets: the chips that list them, the button that picks them,
/// and the one path a drop, a paste or a pick goes through to become one.
///
/// Shared rather than written twice because the prompt sheet grew attachments after the feedback
/// sheet had them, and the two go to the same application under the same limits. A second copy
/// of the reading and the limit sentences would be a second place for them to disagree.
extension FeedbackImages {
    /// The open panel, as a sheet rather than `runModal()`, which stops the run loop and with it
    /// every transcript streaming in the window behind this one. See `PanelPresentation`. Nil when
    /// the panel was cancelled.
    @MainActor
    static func pick() async -> [AttachmentSource]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Attach"

        guard await panel.present() == .OK else { return nil }
        return panel.urls.map { .file($0) }
    }

    /// Reads `sources` off the main actor and appends what can go to `images`, or leaves `images`
    /// alone and returns the sentence saying why not. Nil means it worked, which is also what
    /// clears a warning left by the attempt before.
    ///
    /// What is already attached is read when this is called rather than when the read finishes,
    /// so the limits are checked against what the person could see when they dropped.
    @MainActor
    static func add(_ sources: [AttachmentSource], to images: Binding<[FeedbackImage]>) async -> String? {
        let existing = images.wrappedValue
        do {
            let read = try await Task.detached(priority: .userInitiated) {
                try FeedbackImages.read(sources, existing: existing)
            }.value
            images.wrappedValue += read
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The attached pictures as chips, and the sentence about the last one that could not go.
/// Draws nothing at all when there is neither, so a sheet with no pictures has no gap for them.
struct FeedbackImageList: View {
    @Binding var images: [FeedbackImage]
    @Binding var problem: String?

    var body: some View {
        if !images.isEmpty {
            ChipFlow(spacing: Metrics.spacing, lineSpacing: Metrics.spacing) {
                ForEach(images) { image in
                    FeedbackImageChip(image: image) {
                        images.removeAll { $0.id == image.id }
                        problem = nil
                    }
                }
            }
        }

        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.caption)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Attach images, greyed once the sheet holds as many as one submission carries.
struct FeedbackAttachButton: View {
    var count: Int
    var isSending: Bool
    var action: @MainActor () -> Void

    var body: some View {
        Button(Feedback.Copy.attachImages, systemImage: "photo.on.rectangle", action: action)
            .disabled(count >= Feedback.maxImages || isSending)
            .help("Up to \(Feedback.maxImages) pictures. You can also paste or drop one on the box above.")
    }
}

/// One attached picture: what it is called and how big it is, with a way to take it off again.
///
/// A chip rather than a thumbnail. The composer says an attachment with an icon and a name, so
/// this says it the same way, and it costs nothing per keystroke: decoding a two megabyte PNG to
/// draw a forty point square would be paid for on every redraw of a sheet somebody is typing into.
struct FeedbackImageChip: View {
    var image: FeedbackImage
    var onRemove: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Image(systemName: "photo")
                .font(.system(size: Metrics.glyph - 2))
                .foregroundStyle(Palette.textSecondary)

            Text(image.filename)
                .font(Typo.caption)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file))
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: Metrics.glyph - 4, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textTertiary)
            .help("Take this image off")
            .accessibilityLabel("Remove \(image.filename)")
        }
        .padding(.horizontal, Metrics.spacing)
        .padding(.vertical, Metrics.spacingSmall)
        .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        )
        .frame(maxWidth: 260, alignment: .leading)
    }
}
