import BloomCore
import Foundation
import Synchronization
import Testing
@testable import BloomRunner

/// Who may be addressed, and the three answers the machine has to keep apart.
@Suite("The team this machine knows about")
struct MachineMembersTests {
    private static let seb = WorkspaceMember(userID: "user-seb", name: "Sebastian", handle: "sebdd")

    /// A clock and a counter the test owns, since a `Mutex` cannot be passed as an argument.
    private final class Rig: Sendable {
        let clock = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let asked = Mutex(0)

        var now: Date { clock.withLock { $0 } }
        var asks: Int { asked.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { clock.withLock { $0 = $0.addingTimeInterval(seconds) } }

        func members(_ answer: @escaping @Sendable () throws -> [WorkspaceMember]) -> MachineMembers {
            MachineMembers(now: { self.clock.withLock { $0 } }) {
                self.asked.withLock { $0 += 1 }
                return try answer()
            }
        }
    }

    /// **Never having been told is not the same as being told no.** A machine that collapsed them
    /// would refuse everybody identically the first time runbloom.app was unreachable.
    @Test("an unreachable server answers unknown, not not-a-member")
    func unreachableIsUnknown() async {
        let members = Rig().members { throw RunbloomError.unreachable("no") }

        #expect(await members.look(up: "user-seb") == .unknown)
    }

    @Test("somebody in the list is a member, and somebody who is not is refused")
    func memberOrNot() async {
        let members = Rig().members { [Self.seb] }

        #expect(await members.look(up: "user-seb") == .member(Self.seb))
        #expect(await members.look(up: "user-nobody") == .notAMember)
    }

    /// The case the pull exists for: a colleague who joined after the machine last asked.
    @Test("a miss asks again, so somebody who joined this morning is addressable this afternoon")
    func aMissRefetches() async {
        let rig = Rig()
        let joined = Mutex(false)
        let members = rig.members { joined.withLock { $0 } ? [Self.seb] : [] }

        #expect(await members.look(up: "user-seb") == .notAMember)
        joined.withLock { $0 = true }
        // Inside the cooldown, the machine does not ask again: a mistyped handle is a miss too, and
        // a request per keystroke is what this is protecting the server from.
        #expect(await members.look(up: "user-seb") == .notAMember)
        #expect(rig.asks == 1)

        rig.advance(MachineMembers.cooldown + 1)
        #expect(await members.look(up: "user-seb") == .member(Self.seb))
        #expect(rig.asks == 2)
    }

    /// Somebody who has left has to stop being addressable, which a merge would never allow.
    @Test("a fresh list replaces the old one rather than adding to it")
    func leaversGo() async {
        let rig = Rig()
        let present = Mutex(true)
        let members = rig.members { present.withLock { $0 } ? [Self.seb] : [] }

        #expect(await members.look(up: "user-seb") == .member(Self.seb))
        present.withLock { $0 = false }
        rig.advance(MachineMembers.cooldown + 1)
        // The miss that refetches is for somebody else; the answer about Seb comes from the new list.
        #expect(await members.look(up: "user-nobody") == .notAMember)
        #expect(await members.look(up: "user-seb") == .notAMember)
    }
}
