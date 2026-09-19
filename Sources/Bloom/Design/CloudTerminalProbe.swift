import AppKit
import SwiftTerm

#if DEBUG
/// What a Cloud terminal shows after the machine reattaches it.
///
/// **A reattach is not a continuation, it is a redraw.** Asked for a terminal by name, the machine
/// answers with one frame that begins clear screen, cursor home, and then the pane's contents as
/// they were: 167 bytes in the run this was written from. So the correct handling is to feed that
/// frame to the emulator as it stands and never to append it to what the client was showing, and
/// this drives exactly that sequence through the app's own view and reads the screen back.
///
/// It also settles where a sentence about the join can live. A rule and a line used to be written
/// into the stream before reconnecting, so that a new shell's first prompt could not be read as the
/// old one carrying on. The clear screen arrives immediately afterwards, and this measures what
/// becomes of it: off the screen and out of the scrollback, every time. The same clear is why
/// nothing needs saying there at all, and the pane's own strip is where it is said instead.
@MainActor
enum CloudTerminalProbe {
    /// What the screen held at each step, for the report.
    private(set) static var summary = ""

    /// The measured opening of a reattach frame. Everything after it is the pane as it was.
    private static let reattach = "\u{1B}[2J\u{1B}[H"

    static func run(check: (Bool, String) -> Void) async {
        let view = CloudTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        let terminal = view.getTerminal()
        terminal.resize(cols: 80, rows: 24)

        // A shell somebody has been working in, then the socket goes away without a close frame,
        // which is a laptop closing rather than a tidy disconnect.
        feed(view, "first line\r\nsecond line\r\n")
        let before = screen(of: terminal)
        check(before.contains("first line"), "the terminal did not draw what the shell wrote")

        // A line written into the stream just before reconnecting, which is what the pane used to
        // do. Drawn as its own thing rather than by calling the app, because the app does not write
        // one any more: what is under test is what happens to anything written here.
        feed(view, "\r\n\u{1B}[2mWhat follows is a new shell.\u{1B}[0m\r\n")
        let noted = screen(of: terminal)
        check(noted.contains("What follows is a new shell"), "the boundary line was not drawn at all")

        // And the machine's answer, which is a redraw of the pane as it was.
        feed(view, reattach + "first line\r\nsecond line\r\nreader@machine:~$ ")
        let after = screen(of: terminal)

        // The whole of the first question: fed as it stands, the frame replaces the picture rather
        // than being added to it. A client that appended would have two of every line here.
        check(
            after.components(separatedBy: "first line").count == 2,
            "the reattach frame was added to the stale screen rather than replacing it"
        )
        check(after.contains("reader@machine:~$"), "the reattached shell's prompt is not on screen")

        // And the second, which is the awkward one. The note is off the screen, so the question is
        // whether the clear scrolled it into the history above or threw it away: the whole buffer,
        // scrollback included, is what says which.
        let onScreen = after.contains("What follows is a new shell")
        let history = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        let kept = history.replacingOccurrences(of: "\n", with: "").contains("What follows is a new shell")
        check(!onScreen, "the boundary line survived a clear screen, so this probe's reading of the frame is wrong")

        let batching = measureBatching(check: check)
        summary = "after the reattach the screen holds one copy of each line and the new prompt; "
            + "the boundary line is \(onScreen ? "on screen" : "off the screen") and "
            + "\(kept ? "kept in the scrollback" : "gone from the buffer altogether"); "
            + batching
    }

    /// What batching a burst saves, measured through the app's own view: `seq 1 5000` fed as the
    /// 849 frames tmux's control mode cut it into on this Mac, and then fed once, as
    /// `TerminalOutputBatch` does per display refresh. The screens have to come out identical; the
    /// times are reported, not asserted, because they describe the machine this ran on.
    static func measureBatching(check: (Bool, String) -> Void) -> String {
        let bytes = Array((1...5_000).map { "\($0)\r\n" }.joined().utf8)
        let frameCount = 849
        let step = (bytes.count + frameCount - 1) / frameCount
        let frames = stride(from: 0, to: bytes.count, by: step).map { bytes[$0..<min($0 + step, bytes.count)] }

        let separate = CloudTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        separate.getTerminal().resize(cols: 80, rows: 24)
        let clock = ContinuousClock()
        let eachStart = clock.now
        for frame in frames { separate.feed(byteArray: frame) }
        let each = clock.now - eachStart

        let batched = CloudTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        batched.getTerminal().resize(cols: 80, rows: 24)
        let onceStart = clock.now
        batched.feed(byteArray: ArraySlice(bytes))
        let once = clock.now - onceStart

        check(
            screen(of: separate.getTerminal()) == screen(of: batched.getTerminal()),
            "feeding the burst once drew a different screen from feeding it frame by frame"
        )
        let format: (Duration) -> String = { $0.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))) }
        return "seq 1 5000 as \(frames.count) feeds took \(format(each)), as one feed \(format(once))"
    }

    private static func feed(_ view: CloudTerminalView, _ text: String) {
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
    }

    /// The visible screen as one string, every row at its full width and no separator between them.
    ///
    /// Read a character at a time because that is what SwiftTerm makes public, and run together
    /// because the sentence being looked for is 83 characters and the screen is 80 wide: it wraps,
    /// and a row separator would put a break through the middle of it. Rows that do not fill their
    /// width are separated by their own trailing spaces.
    private static func screen(of terminal: Terminal) -> String {
        var text = ""
        for row in 0..<terminal.rows {
            for column in 0..<terminal.cols {
                text.append(terminal.getCharacter(col: column, row: row) ?? " ")
            }
        }
        return text
    }
}
#endif
