import Foundation

/// The wire vocabulary of `grok agent stdio`, which speaks ACP as JSON-RPC 2.0 over stdio.
///
/// ## Why this protocol and not `grok -p --output-format streaming-messages-json`
///
/// Headless `-p` is NDJSON in the Messages API shape Bloom already stores, and looks like a
/// drop-in for `AgentRunner`. It is a trap, measured against grok 1.0.24:
///
///   * **One prompt, then exit.** stdin is not a conversation. Follow-up turns are a new process
///     with `--resume`, which is not how Bloom holds a chat open.
///   * **Read only.** The headless docs say tool approvals and other bidirectional flows use ACP.
///     A permission question has nowhere to land, so the only honest headless mode is
///     `--always-approve`.
///
/// `grok agent --no-leader stdio` is the real interface: `initialize`, `session/new` /
/// `session/resume`, `session/prompt` (held open for the whole turn), `session/update`
/// notifications, and `session/request_permission` as a server-to-client request. `--no-leader`
/// is load-bearing: without it a Bloom chat can attach to the owner's interactive TUI leader.
///
/// Frame classification is the JSON-RPC one, never by id: `method` plus `id` is a request,
/// `method` alone a notification, `result` or `error` a response. Request ids on this wire are
/// numbers Bloom assigns, and the server's permission requests use the same numbering, so a
/// frame is never typed by looking at its id.
public typealias GrokRequestID = ACPRequestID
public typealias GrokRPCError = ACPRPCError
public typealias GrokServerRequest = ACPServerRequest
public typealias GrokServerNotification = ACPServerNotification
public typealias GrokFrame = ACPFrame
public typealias GrokOutgoing = ACPOutgoing
public typealias GrokClientError = ACPClientError
