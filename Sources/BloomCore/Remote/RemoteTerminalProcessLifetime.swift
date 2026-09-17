import Foundation

/// A cancelled stream iterator does not reap its child. Both terminal owners, the tmux daemon and
/// each attachment's control client, keep this task until the process has exited, with an
/// escalation to SIGKILL that does not depend on whether the caller was cancelled.
enum RemoteTerminalProcessLifetime {
    static func stop(_ process: StreamingProcess) -> Task<Void, Never> {
        process.terminate()
        return Task.detached {
            let escalation = Task.detached {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                process.kill()
            }
            defer { escalation.cancel() }
            _ = await process.exitStatus
        }
    }
}
