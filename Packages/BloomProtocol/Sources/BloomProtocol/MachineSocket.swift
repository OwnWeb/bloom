/// The largest frame on the machine's WebSockets, the terminal and the port forward, either way.
///
/// **A client frame larger than this closes the socket.** Hummingbird's WebSocket server refuses a
/// frame over its `maxFrameSize` with 1009 and drops the connection, and its default is 16 KiB.
/// Nothing said so, and the first port forward sent whatever one read of its local socket
/// returned, up to 64 KiB, so any INSERT or upload larger than 16 KiB ended the forward it went
/// through. A terminal paste of the same size ended the shell's connection the same way. The
/// server now names this number rather than inheriting it, and every client splits its writes by
/// it, so the two cannot drift. The proxy splits what it sends by it as well, because a client
/// built on the same library holds the same limit the other way.
public enum MachineSocket {
    public static let maximumFrame = 1 << 14
}
