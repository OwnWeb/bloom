import BloomClient
import BloomCore
import BloomProtocol
import Foundation

/// Messages from agents on Bloom Cloud machines for workspaces on this Mac, from a live stream or
/// held by runbloom.app while no stream was open.
///
/// The decision is `MacMessageIntake`, in the core and tested; this reads what it needs (who is
/// signed in, which workspaces are here, which ids have gone in) and hands the result to the same
/// delivery `workspace_say` uses, so it arrives as any relayed message does. Nothing is answered:
/// there is no channel back, and what was dropped is said in the log, where the question "why did
/// that never arrive" is asked.
extension AppModel {
    func receiveMacMessage(_ record: MacMessageRecord) async {
        _ = await landMacMessage(record)
    }

    /// What runbloom.app is holding for this Mac, landed and acknowledged. See `MacMessageDrain`
    /// for why only what landed is acknowledged and why a second drain is skipped.
    func drainMacMessages() async {
        guard let userID = cloud.account?.id else { return }
        let api = cloud.api
        await macMessageDrain.drain(
            list: { try await api.macMessages() },
            land: { [weak self] message in
                guard let self else { return .later }
                return await self.landMacMessage(message.record(for: userID), team: message.team?.name, held: true)
            },
            acknowledge: { try await api.acknowledgeMacMessage($0) }
        )
    }

    /// - Parameter held: whether runbloom.app held it, which is when a message for a workspace this
    ///   Mac does not have is told to the person: on a live stream the machine's agent was already
    ///   told the name is the Mac's to resolve, and a held one has waited, possibly for days.
    private func landMacMessage(_ record: MacMessageRecord, team: String? = nil, held: Bool = false) async -> MacMessageDrain.Landing {
        let projects = Dictionary(repos.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        switch MacMessageIntake.decide(
            record,
            signedIn: cloud.account?.id,
            workspaces: workspaces,
            projects: projects,
            seen: macMessagesDelivered.contains(record.id),
            team: team
        ) {
        case .drop(let reason, let kind):
            Log.bridge.notice("\(reason, privacy: .public)")
            switch kind {
            case .duplicate:
                return .settled
            case .noSuchWorkspace:
                guard held else { return .settled }
                // Nobody else can be told, so the person is, with the words, which are gone once
                // this is acknowledged. It stays until dismissed for that reason.
                notice = BloomNotice(
                    message: MacMessageIntake.unplacedSentence(record, team: team),
                    dismissal: .untilDismissed
                )
                return .settled
            case .refused:
                return .later
            }
        case .deliver(let message):
            // Marked before the delivery is awaited, so the same message arriving down a second
            // stream meanwhile is a duplicate, and unmarked if it did not go, so it is tried again.
            macMessagesDelivered.insert(record.id)
            if case .refused(let reason) = await deliverWorkspaceMessage(message) {
                macMessagesDelivered.remove(record.id)
                Log.bridge.notice("mac_message \(record.id, privacy: .public) was not delivered: \(reason, privacy: .public)")
                return .later
            }
            return .settled
        }
    }
}
