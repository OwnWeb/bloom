import BloomProtocol
import Foundation

enum Records {
    static let date = Date(timeIntervalSince1970: 1_789_000_000)

    static func chat(_ id: String = "c1", state: String = "idle", lastSeq: Int = 0) -> ChatRecord {
        ChatRecord(id: id, title: "Chat", agent: "claude", model: "claude-opus-5", effort: "high", permissionMode: "acceptEdits",
                   interactionMode: "build", state: state, lastSeq: lastSeq, createdAt: date, updatedAt: date)
    }

    static func message(_ seq: Int, chat: String = "c1", cursor: Int64? = nil, kind: String = "assistantText", text: String = "hi") -> MessageRecord {
        MessageRecord(cursor: cursor ?? Int64(seq * 10), chatID: chat, seq: seq, kind: kind, payload: .object(["text": .string(text)]), createdAt: date)
    }

    static func page(_ messages: [MessageRecord], chat: ChatRecord = chat(), hasMore: Bool = false, busy: Bool = false, streaming: String = "") -> TranscriptRecord {
        TranscriptRecord(chat: chat, messages: messages, hasMore: hasMore, questions: [], busy: busy, streamingText: streaming, queue: QueueRecord(chatID: chat.id, prompts: []))
    }

    static func workspace(cursor: Int64 = 0, chats: [ChatRecord] = [chat()]) -> WorkspaceSnapshotRecord {
        WorkspaceSnapshotRecord(
            workspace: WorkspaceRecord(id: "01k5ws", name: "Queue retries", branch: "freek/queue-retries", baseBranch: "main", setup: SetupRecord(state: "succeeded")),
            chats: chats, presence: [], cursor: cursor
        )
    }

    static func json(_ value: some Encodable) -> String {
        String(decoding: (try? WireJSON.encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }
}
