import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Checks that ticking a file in the all-files review folds it, in an invisible window against a
/// disposable repository.
///
/// The reader says "done with this one" and the diff gets out of the way; taking the tick off
/// brings it back. Measured on the drawn height of that file's own diff, because a read file
/// keeping its six hundred points of scrolling is the complaint, and by four captures for the eye.
///
/// **The resize between the ticks is the part worth keeping.** A rule of "folded if viewed" would
/// also pass every check above it and then slam a hand opened file shut on the next diff stat
/// poll, so the probe re-lays the whole review out twice with nothing about the ticks moving and
/// insists nothing about the folding moved either. The hand opened case itself is
/// `ReviewCollapseTests`, over the rule this view calls.
///
/// **Why the document's height is not what is measured, which cost three agents an hour each.**
/// The first tick used to be checked by reading the height of the whole review document either
/// side of it and insisting it fell by forty points. That check was green on every Mac anybody ran
/// it on and roughly a coin toss on GitHub's macOS runners: in one night it failed three branches
/// and passed twice, on commits with nothing in common, one of them touching no application code
/// at all.
///
/// The document's height is not the fold. The review is a lazy stack whose sections reserve their
/// height through `ReviewDiffBlock`, so the number is the real height of the sections something
/// has laid out plus SwiftUI's estimate for every section it has not, and that estimate moves as
/// sections materialise. Dumping every text view in the hierarchy at each measurement says so
/// plainly: on this Mac the expanded document is 2,100 points with exactly one file's body drawn
/// at a time, while the runner read the same document as 1,380, 1,380 and 1,320 on the three
/// failures. The check was therefore reading the fold minus whatever else happened to lay out in
/// the same nine hundred milliseconds, and on a headless runner that second term is the larger
/// one. The third failure is that in the open: the document grew by forty seven points with the
/// fold having worked perfectly.
///
/// **What replaces it still measures the drawing, because that is what the number was for.**
/// Asking the view which files it has folded, which `ReviewFoldReport` exists for, cannot see the
/// bug the height check was put there to catch: the fold state moving while the drawing does not.
/// So `drawnHeight(of:in:)` walks the hosted AppKit hierarchy for the text views carrying one
/// file's diff and reports how tall they stand, which is six hundred odd points for a drawn diff
/// and nothing at all for a folded one, and which depends on no other section of the document.
/// Both halves are asserted next to each other: the view says README is folded, and README's own
/// six hundred points have left the window.
///
/// **And `settle` now waits for the drawing to stop moving** rather than for a fixed nine hundred
/// milliseconds. A number read while sections are still materialising describes a document half
/// way through being laid out, and on a runner with no display and eight other jobs on the machine
/// half way is where nine hundred milliseconds lands. A settle that never comes to rest says so
/// and fails, rather than handing back a number nobody should believe.
///
/// The last capture is taken with every file ticked, so all four header rows stack and the row
/// controls can be read down one column: the preview button is drawn for the two Markdown files
/// and for neither of the others, and it leads the cluster so the tick and the overflow menu are
/// in the same place on all four.
@MainActor
enum ReviewFoldProbe {
    /// A line only the rewritten README carries, so the text views holding its diff can be told
    /// from every other file's in the hierarchy. `seed` writes it.
    private static let readmeMarker = "Line 0 of the readme, rewritten."

    /// The heights the checks were made of, put in the probe's result so that every run prints
    /// them, passing or failing.
    ///
    /// **A green job can say nothing at all, and this check is where that was learned.** The run
    /// that taught us most about it was a pass: ten green attempts on one runner, whose expanded
    /// documents came out anywhere between 2,669 and 1,400 points, two of them clearing the old
    /// forty point threshold by two. The run that verified the fix under it was ten green attempts
    /// as well and its log says nothing whatever, because this line was not in it yet. So every
    /// run reports the numbers now, and the next person to suspect this check starts with the
    /// readings from every run since rather than with none, which is where tonight started.
    ///
    /// The document's heights are in it although nothing is asserted on them any more. They are
    /// the number that was lying, and the spread across runs is the only reason any of this was
    /// understood.
    private(set) static var summary = "the fold probe took no measurement"

    /// The longest any one settle took to come to rest, for that same line.
    private static var slowestSettle: Double = 0

    static func run(directory: String, check: (Bool, String) -> Void) async {
        // The store lives in the throwaway probe root, named before anything opens it. Without it
        // the model has no store, `setViewed` writes nowhere, and the probe would pass by
        // measuring nothing.
        setenv("BLOOM_DB_PATH", directory + "/fold.sqlite", 1)
        let app = AppModel()
        await app.bootstrap()
        guard let store = app.store else {
            check(false, "the fold probe could not open its own database")
            return
        }

        let model: WorkspaceModel
        do {
            model = try await seed(directory: directory, app: app, store: store)
        } catch {
            check(false, "fold fixture failed: \(error)")
            return
        }
        await model.refreshChanges()
        await model.reloadViewedFiles()
        check(model.reviewFiles.count == 4, "fold fixture loaded \(model.reviewFiles.count) files, expected four")
        let previewable = model.reviewFiles.filter { $0.path.hasSuffix(".md") }
        check(previewable.count == 2 && model.reviewFiles.count - previewable.count == 2,
              "fold fixture is not the mix of previewable and plain files the capture needs")
        guard let readme = model.reviewFiles.first(where: { $0.path == "README.md" }),
              let checkout = model.reviewFiles.first(where: { $0.path == "Sources/Checkout.swift" }) else {
            check(false, "fold fixture is missing the files the checks are about")
            return
        }

        model.selectedFilePath = readme.path
        let tab = CenterTabStore.shared.showReview(path: readme.path, workspaceID: model.workspace.id)
        CenterTabStore.shared.setShowsAllFiles(true, for: tab)
        let host = NSHostingView(rootView: Fixture(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        // The diffs are read off disk after the window is up, so this one waits for the file being
        // measured to arrive rather than only for the drawing to hold still: an empty document
        // holds perfectly still.
        let drewReadme = await settle(window, until: { drawnHeight(of: readmeMarker, in: host) > 0 })
        save(host, at: directory + "/fold-expanded.png")
        let expandedDocument = documentHeight(in: host)
        check(expandedDocument > 0, "the review drew no document to measure")
        check(drewReadme, "the review never came to rest with README's diff drawn, so nothing below is a settled number")
        let expandedDiff = drawnHeight(of: readmeMarker, in: host)
        check(expandedDiff > 400,
              "the review drew \(expandedDiff) points of README's diff, so a fold would have nothing to take away")

        await model.setViewed(true, file: readme)
        let restedAfterTick = await settle(window)
        check(restedAfterTick, "the review never stopped moving after the tick, so no number read here is settled")
        check(model.isViewed(readme), "the tick did not reach the model, so nothing below means anything")
        save(host, at: directory + "/fold-viewed.png")
        let foldedDocument = documentHeight(in: host)
        // Both halves, because either alone is a bug that passes. A view that folds in its own
        // bookkeeping and keeps drawing the diff is the complaint this probe was written for, and
        // the height of the document cannot see it: see the note above this type for the three
        // nights that proved so.
        check(ReviewFoldReport.collapsed.contains(readme.path),
              "ticking a file did not fold it: \(ReviewFoldReport.collapsed)")
        let foldedDiff = drawnHeight(of: readmeMarker, in: host)
        check(foldedDiff == 0,
              "ticking README left \(foldedDiff) points of its diff drawn, from \(expandedDiff): "
              + "the fold moved the state and not the drawing")

        // A neighbour's tick folds its own file and leaves the one already folded alone.
        //
        // **Asked of the view rather than measured off it, unlike the check above.** README's diff
        // is on screen, so it can be watched to leave the window. The second file's is below the
        // viewport and a lazy stack may never have drawn it at all, so there is nothing there to
        // watch go. What this check is about is which files are folded, and the view says so.
        await model.setViewed(true, file: checkout)
        await settle(window)
        check(ReviewFoldReport.collapsed.contains(checkout.path),
              "ticking a second file did not fold it as well: \(ReviewFoldReport.collapsed)")
        check(ReviewFoldReport.collapsed.contains(readme.path),
              "ticking a second file unfolded the first: \(ReviewFoldReport.collapsed)")

        // The re-render case: nothing about the ticks moves, so nothing about the folding may.
        let foldedPaths = ReviewFoldReport.collapsed
        window.setContentSize(NSSize(width: 980, height: 760))
        await settle(window)
        window.setContentSize(NSSize(width: 1120, height: 760))
        await settle(window)
        check(ReviewFoldReport.collapsed == foldedPaths,
              "a resize moved the folding: \(ReviewFoldReport.collapsed), from \(foldedPaths)")

        // The one place the document's height is still the right number: with every file folded
        // there is no section left for a lazy stack to estimate, so this is four header rows
        // measured rather than four guessed at.
        for file in model.reviewFiles { await model.setViewed(true, file: file) }
        await settle(window)
        save(host, at: directory + "/fold-all-viewed.png")
        let allFolded = documentHeight(in: host)
        check(allFolded < InspectorLayout.reviewHeaderHeight * CGFloat(model.reviewFiles.count) + 4,
              "four ticked files came to \(allFolded), which is more than four header rows")

        for file in model.reviewFiles { await model.setViewed(false, file: file) }
        let drewAgain = await settle(window, until: { drawnHeight(of: readmeMarker, in: host) > 0 })
        save(host, at: directory + "/fold-unviewed.png")
        // On README's own diff rather than on the document, for the reason the first tick is:
        // what is asked here is whether the diff came back, and the document's height answers a
        // question about every other section as well.
        check(drewAgain, "the review never came to rest with README's diff drawn again after the ticks came off")
        let reopenedDiff = drawnHeight(of: readmeMarker, in: host)
        check(reopenedDiff > 400,
              "taking every tick off left README's diff at \(reopenedDiff) points drawn: it did not come back")

        check(!window.isVisible && !window.isKeyWindow, "fold probe activated its window")
        summary = "README drawn \(expandedDiff) expanded, \(foldedDiff) folded, \(reopenedDiff) reopened; "
            + "document \(expandedDocument), \(foldedDocument), \(allFolded) with every file folded; "
            + "slowest settle \(String(format: "%.2f", slowestSettle))s"
        window.contentView = nil
        withExtendedLifetime(app) {}
    }

    private static func documentHeight(in view: NSView) -> CGFloat {
        scrollView(in: view)?.documentView?.bounds.height ?? 0
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private static func save(_ host: NSView, at path: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Lays the window out until the drawing stops moving and `condition` holds, and says whether
    /// it got there.
    ///
    /// The fixed nine hundred milliseconds this replaces is half of why the first tick was a coin
    /// toss on the runner. A number read while the lazy stack is still materialising sections
    /// describes a document half way through being laid out, and on a machine with no display and
    /// several jobs on it half way is where nine hundred milliseconds lands.
    ///
    /// What is watched is the whole drawn hierarchy rather than the document's height, because the
    /// height is the number that was lying: it holds still perfectly well while a section below
    /// the viewport is still being built.
    ///
    /// False means it never came to rest, which is a finding for the caller to report rather than
    /// a licence to measure anyway.
    @discardableResult
    private static func settle(_ window: NSWindow, until condition: () -> Bool = { true }) async -> Bool {
        let started = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            slowestSettle = max(slowestSettle, seconds)
        }
        var last: String?
        var stillFor = 0
        for _ in 0..<200 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
            guard let view = window.contentView else { return false }
            let drawing = drawing(of: view)
            stillFor = drawing == last ? stillFor + 1 : 0
            last = drawing
            if stillFor >= 10, condition() { return true }
        }
        return false
    }

    /// Everything the checks read, as one string: the document's height, and the frame and opening
    /// line of every piece of text drawn inside it. Two of these being equal is what `settle`
    /// means by the drawing having stopped moving.
    private static func drawing(of host: NSView) -> String {
        var parts = ["\(documentHeight(in: host))"]
        forEachText(in: host) { text, frame in
            parts.append("\(Int(frame.minY)):\(Int(frame.height)):\(text.prefix(40))")
        }
        return parts.joined(separator: "|")
    }

    /// How tall the text views carrying one file's diff stand in the window: six hundred odd
    /// points for a drawn diff, and nothing at all once it is folded, because folding takes the
    /// body out of the hierarchy rather than merely shrinking it.
    ///
    /// The union of their frames rather than the sum of their heights, since a diff drawn as old
    /// beside new is one region of the document covered twice.
    private static func drawnHeight(of marker: String, in host: NSView) -> CGFloat {
        var region: CGRect?
        forEachText(in: host) { text, frame in
            guard text.contains(marker) else { return }
            region = region.map { $0.union(frame) } ?? frame
        }
        return region?.height ?? 0
    }

    private static func forEachText(in host: NSView, _ body: (String, CGRect) -> Void) {
        func walk(_ view: NSView) {
            if let text = view as? NSTextView { body(text.string, view.convert(view.bounds, to: host)) }
            for subview in view.subviews { walk(subview) }
        }
        walk(host)
    }

    /// A real worktree with rows in the store behind it. The rows are the part that is easy to
    /// skip and cannot be: `reviewed_files` references `workspaces(id)`, so a tick against a
    /// workspace nobody wrote is refused by SQLite and the model quietly keeps its old answer.
    ///
    /// Two files something can be previewed from and two that cannot, which is the mix the
    /// capture needs and the shape of any real branch.
    private static func seed(directory: String, app: AppModel, store: Store) async throws -> WorkspaceModel {
        let origin = directory + "/fold-repo"
        let worktree = directory + "/fold"
        try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
        func git(_ arguments: [String], cwd: String = origin) async throws {
            try await Shell.check("git", ["-c", "commit.gpgsign=false", "-c", "user.name=Fold Probe",
                                          "-c", "user.email=fold@example.test"] + arguments, cwd: cwd)
        }
        func write(_ name: String, _ body: String, in root: String) throws {
            let path = root + "/" + name
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try await git(["init", "-q", "-b", "main"])
        try write("README.md", "# Checkout\n\nShipping costs 4.95 for every order.\n", in: origin)
        try write("Docs/notes.md", "# Notes\n\n- One.\n", in: origin)
        try write("Config/features.json", "{\"free_shipping\": false}\n", in: origin)
        try write("Sources/Checkout.swift", "struct Checkout {\n    var shipping: Decimal { 4.95 }\n}\n", in: origin)
        try await git(["add", "."])
        try await git(["commit", "-qm", "Baseline"])
        try await git(["worktree", "add", "-qb", "fold", worktree])
        // Forty lines nothing else in the fixture writes, so `readmeMarker` finds this file's diff
        // in the hierarchy and no other.
        try write("README.md", (0..<40).map { "Line \($0) of the readme, rewritten.\n" }.joined(), in: worktree)
        try write("Docs/notes.md", "# Notes\n\n- One.\n- Two.\n- Three.\n", in: worktree)
        try write("Config/features.json", "{\"free_shipping\": true, \"threshold\": 50}\n", in: worktree)
        try write("Sources/Checkout.swift", (0..<40).map { "let checkoutLine\($0) = \($0)\n" }.joined(), in: worktree)

        let repo = try await store.upsert(Repo(name: "Fold probe", path: origin))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Fold", branch: "fold", path: worktree, baseBranch: "main"
        ))
        await app.reload()
        return WorkspaceModel(workspace: workspace, app: app)
    }

    private struct Fixture: View {
        let model: WorkspaceModel

        var body: some View {
            if let tab = CenterTabStore.shared.review(for: model.workspace.id) {
                AllFilesReviewView(model: model, selectedPath: tab.path,
                                   navigationRevision: tab.reviewNavigationRevision)
            }
        }
    }
}
#endif
