import Foundation
import Testing
@testable import BloomCore

@Suite("Edited code blocks")
struct EditedCodeBlockTests {
    @Test("An edited fence is named like a paste and dated to the second")
    func name() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_791_532_744)
        #expect(EditedCodeBlock.filename(language: .swift, at: date, timeZone: utc)
            == "Edited 2026-10-09 at 07.59.04.swift")
    }

    @Test("Every language is written under an extension that reads back as that language")
    func roundTrip() {
        for language in Language.allCases {
            let name = EditedCodeBlock.filename(language: language)
            #expect(Language.detect(path: name) == language, "\(name)")
        }
    }

    @Test("A draft's key is the same on every launch, and tells fences apart by row and by code")
    func draftKey() {
        let key = EditedCodeBlock.draftKey(session: "s1", entry: "row(4)", code: "let a = 1")
        #expect(key == "s1/row(4)/2c07d877ba5b1548307d0bbc")
        #expect(EditedCodeBlock.draftKey(session: "s1", entry: "row(4)", code: "let b = 2") != key)
        #expect(EditedCodeBlock.draftKey(session: "s1", entry: "row(9)", code: "let a = 1") != key)
    }

    @Test("A fence that names its file is attached under that name", arguments: [
        ("swift title=\"Store.swift\"", "Store.swift"),
        ("swift title='My Store.swift'", "My Store.swift"),
        ("php file=app/Models/User.php", "User.php"),
        ("ts src/index.ts", "index.ts"),
        ("swift filename=\"a:b`c.swift\"", "a-b-c.swift"),
    ])
    func named(info: String, expected: String) {
        #expect(EditedCodeBlock.filename(info: info, language: .plainText) == expected)
    }

    @Test("A fence with no name falls back to the dated one", arguments: [
        "", "swift", "js {1,3}", "sh title=\"..\"", "sh highlight_name=x.sh", "sh foo/..",
    ])
    func unnamed(info: String) throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_791_532_744)
        #expect(EditedCodeBlock.filename(info: info, language: .shell, at: date, timeZone: utc)
            == "Edited 2026-10-09 at 07.59.04.sh")
    }
}
