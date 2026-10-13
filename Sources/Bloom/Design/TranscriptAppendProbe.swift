import AppKit
import BloomCore
import QuartzCore
import SwiftUI

/// Profiles the actual transcript view while stored rows arrive into an already long session.
/// The window and messages exist only in memory, so the probe has no workspace or display to touch.
@MainActor
enum TranscriptAppendProbe {
    private static let harness = ProbeHarness(subject: "transcript-append")
    static var isRequested: Bool { harness.isRequested }

    static func schedule() { Task { @MainActor in await run() } }

    private static func run() async {
        let app = AppModel()
        let workspace = Workspace(
            repoID: RepoID(UUID().uuidString), name: "Append probe", branch: "probe",
            path: "/nonexistent-bloom-append-probe", baseBranch: "main"
        )
        let session = Session(workspaceID: workspace.id, title: "Append probe", lastReadSeq: Int.max)
        let transcript = TranscriptModel(session: session, workspace: workspace, app: app)
        let initial = ProbeHarness.count("--append-rows", or: 5_000)
        let arrivals = ProbeHarness.count("--append-count", or: 200)
        let payload = Data("{}".utf8)
        func message(_ seq: Int) -> Message {
            Message(
                id: Int64(seq + 1), sessionID: session.id, seq: seq,
                kind: seq.isMultiple(of: 20) ? .result : .assistantText, payload: payload
            )
        }
        transcript.seedRowsForProbe((0..<initial).map(message))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
            styleMask: [], backing: .buffered, defer: false
        )
        let host = NSHostingView(rootView: TranscriptView(transcript: transcript).environment(app))
        window.contentView = host
        window.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(3))
        window.layoutIfNeeded()
        guard let hold = TranscriptStateDump.holdView(in: host),
              let table = hold.scroll.documentView as? NSTableView,
              table.numberOfRows > 0 else {
            harness.fail("transcript table did not render")
        }
        let startingTableRows = table.numberOfRows

        harness.markStarted()
        let started = CACurrentMediaTime()
        let cpuStarted = ProbeHarness.mainThreadCPUSeconds()
        for offset in 0..<arrivals {
            transcript.appendRowForProbe(message(initial + offset))
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let wallSeconds = CACurrentMediaTime() - started
        let mainThreadCpuMs = (ProbeHarness.mainThreadCPUSeconds() - cpuStarted) * 1_000
        let appendedTableRows = table.numberOfRows
        var returnFacts: [String: JSONValue] = [:]
        if ProbeHarness.isPresent("--append-return-probe"),
           let coordinator = hold.delegate as? TranscriptTable.Coordinator {
            coordinator.releaseEnd()
            hold.scroll.contentView.scroll(to: .zero)
            hold.scroll.reflectScrolledClipView(hold.scroll.contentView)
            try? await Task.sleep(for: .seconds(2))
            returnFacts["historyTableRows"] = .integer(table.numberOfRows)
            coordinator.goToEnd()
            try? await Task.sleep(for: .seconds(1))
            returnFacts["returnedTableRows"] = .integer(table.numberOfRows)
            returnFacts["returnedToEnd"] = .bool(hold.scroll.isAtEnd)
        }
        harness.write(.object([
            "initialRows": .integer(initial), "appendedRows": .integer(arrivals),
            "finalRows": .integer(transcript.rows.count),
            "startingTableRows": .integer(startingTableRows),
            "tableRows": .integer(appendedTableRows),
            "wallSeconds": .number(wallSeconds),
            "mainThreadCpuMs": .number(mainThreadCpuMs),
        ].merging(returnFacts) { mine, _ in mine }))
        exit(0)
    }
}
