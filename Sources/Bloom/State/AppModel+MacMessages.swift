import BloomCore
import BloomProtocol
import Foundation

/// Messages from agents on Bloom Cloud machines for workspaces on this Mac.
///
/// The decision is `MacMessageIntake`, in the core and tested; this reads what it needs (who is
/// signed in, which workspaces are here, which ids have gone in) and hands the result to the same
/// delivery `workspace_say` uses, so it arrives as any relayed message does. Nothing is answered:
/// there is no channel back, and what was dropped is said in the log, where the question "why did
/// that never arrive" is asked.
extension AppModel {
    func receiveMacMessage(_ record: MacMessageRecord) async {
        let projects = Dictionary(repos.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        switch MacMessageIntake.decide(
            record,
            signedIn: cloud.account?.id,
            workspaces: workspaces,
            projects: projects,
            seen: macMessagesDelivered.contains(record.id)
        ) {
        case .drop(let reason):
            Log.bridge.notice("\(reason, privacy: .public)")
        case .deliver(let message):
            macMessagesDelivered.insert(record.id)
            if case .refused(let reason) = await deliverWorkspaceMessage(message) {
                Log.bridge.notice("mac_message \(record.id, privacy: .public) was not delivered: \(reason, privacy: .public)")
            }
        }
    }
}
