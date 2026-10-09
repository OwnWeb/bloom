import Testing
@testable import BloomCore

@Suite("Code block versions")
struct CodeBlockVersionsTests {
    @Test("An untouched edit can be discarded freely and not attached")
    func untouched() {
        var versions = CodeBlockVersions(original: "a")
        versions.edit()
        #expect(versions.draft == "a")
        #expect(!versions.hasUnattachedChanges)
        #expect(!versions.hasEdits)
        #expect(versions.showsEditor(original: true))
    }

    @Test("An attached edit stays in front, and editing again starts from it")
    func attachThenEditAgain() {
        var versions = CodeBlockVersions(original: "a")
        versions.edit()
        versions.draft = "b"
        #expect(versions.hasUnattachedChanges)
        #expect(!versions.showsEditor(original: true))

        versions.attach()
        #expect(versions == CodeBlockVersions(original: "a", attached: "b"))
        #expect(versions.shown(original: false) == "b")
        #expect(versions.shown(original: true) == "a")
        #expect(versions.hasEdits)

        versions.edit()
        #expect(versions.draft == "b")
        #expect(!versions.hasUnattachedChanges)

        versions.draft = "c"
        versions.discard()
        #expect(versions.shown(original: false) == "b")
    }

    @Test("Reverting shows the agent's code again, and attaching it back keeps nothing")
    func revertAndAttachOriginal() {
        var versions = CodeBlockVersions(original: "a", attached: "b")
        versions.revert()
        #expect(versions == CodeBlockVersions(original: "a"))

        versions = CodeBlockVersions(original: "a", attached: "b")
        versions.edit()
        versions.draft = "a"
        #expect(versions.hasUnattachedChanges)
        versions.attach()
        #expect(versions == CodeBlockVersions(original: "a"))
    }
}
