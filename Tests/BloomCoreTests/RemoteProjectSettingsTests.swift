import Foundation
import Testing
@testable import BloomCore

@Suite("RemoteProjectSettings", .scratchDirectory)
struct RemoteProjectSettingsTests {
    private func repo(_ files: [String: String]) throws -> String {
        let root = TestScratch.unique("remote-settings")
        for (path, contents) in files {
            let full = (root as NSString).appendingPathComponent(path)
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func readsTheDocumentedExample() throws {
        let root = try repo([
            ".bloom/prepare.sh": "#!/bin/sh\napt-get install -y php\n",
            ".bloom/settings.toml": """
            [scripts]
            prepare_file = ".bloom/prepare.sh"
            setup = "composer install"
            resume = "php artisan config:clear"

            [[services]]
            name = "app"
            command = "php artisan octane:start --port=$BLOOM_APP_PORT"
            http = true
            ready = "http:/up"

            [[services]]
            name = "vite"
            command = "npm run dev"
            depends_on = ["app"]

            [remote]
            size = "default"
            """,
        ])
        let settings = RemoteProjectSettings.load(repo: root)
        #expect(settings.problems.isEmpty)
        #expect(settings.prepareScript == "#!/bin/sh\napt-get install -y php\n")
        #expect(settings.prepareFile == ScriptFile(path: ".bloom/prepare.sh", isMissing: false))
        #expect(settings.resumeScript == "php artisan config:clear")
        #expect(settings.resumeFile == nil)
        #expect(settings.size == "default")
        #expect(settings.services == [
            .init(name: "app", command: "php artisan octane:start --port=$BLOOM_APP_PORT", http: true, ready: "http:/up"),
            .init(name: "vite", command: "npm run dev", dependsOn: ["app"]),
        ])
        #expect(settings.httpService?.name == "app")
    }

    @Test func aNamedFileWinsOverTheInlineScriptAndAMissingOneIsReported() throws {
        let root = try repo([".bloom/settings.toml": """
            [scripts]
            resume = "inline"
            resume_file = ".bloom/missing.sh"
            prepare = ""
            """])
        let settings = RemoteProjectSettings.load(repo: root)
        #expect(settings.resumeScript == nil)
        #expect(settings.resumeFile == ScriptFile(path: ".bloom/missing.sh", isMissing: true))
        #expect(settings.prepareScript == nil)
    }

    @Test func aLaterFileReplacesScriptsAndTheWholeServiceList() throws {
        let root = try repo([
            ".conductor/settings.toml": """
            [scripts]
            prepare = "from conductor"
            resume = "kept"

            [[services]]
            name = "old"
            command = "old"
            """,
            ".bloom/settings.local.toml": """
            [scripts]
            prepare = "from local"

            [[services]]
            name = "new"
            command = "new"
            """,
        ])
        let settings = RemoteProjectSettings.load(repo: root)
        #expect(settings.prepareScript == "from local")
        #expect(settings.resumeScript == "kept")
        #expect(settings.services.map(\.name) == ["new"])
    }

    @Test func servicesAreValidatedIntoSentences() {
        let services: [RemoteProjectSettings.Service] = [
            .init(name: "", command: "a"),
            .init(name: "app", command: "a", http: true),
            .init(name: "app", command: "b", http: true),
            .init(name: "worker", command: "c", dependsOn: ["queue"]),
        ]
        let problems = RemoteProjectSettings.validate(services)
        #expect(problems == [
            "A service has no name. Give every [[services]] entry a name.",
            "More than one service is called \"app\". Service names have to be unique.",
            "\"worker\" depends on \"queue\", which is not a service.",
            "Only one service can set http = true, and 2 do: app, app.",
        ])
    }

    @Test func dependencyCyclesAreNamedInOrder() {
        let services: [RemoteProjectSettings.Service] = [
            .init(name: "web", command: "a", dependsOn: ["api"]),
            .init(name: "api", command: "b", dependsOn: ["db"]),
            .init(name: "db", command: "c", dependsOn: ["api"]),
            .init(name: "solo", command: "d", dependsOn: ["solo"]),
        ]
        let problems = RemoteProjectSettings.validate(services)
        #expect(problems == [
            "\"solo\" depends on itself.",
            "These services depend on each other in a circle: api -> db -> api.",
        ])
        #expect(RemoteProjectSettings.validate([.init(name: "a", command: "a"), .init(name: "b", command: "b", dependsOn: ["a"])]).isEmpty)
    }

    @Test func wrongTypesAreReportedAndTheRestIsStillRead() throws {
        let root = try repo([".bloom/settings.toml": """
            [remote]
            size = 4

            [[services]]
            name = "app"
            command = "serve"
            http = "yes"
            ready = "tcp:8000"
            depends_on = "db"

            [[services]]
            name = "empty"
            """])
        let settings = RemoteProjectSettings.load(repo: root)
        let source = root + "/.bloom/settings.toml"
        #expect(settings.services == [.init(name: "app", command: "serve")])
        #expect(settings.size == nil)
        #expect(settings.problems == [
            "\(source): remote.size has to be a string.",
            "\(source): service 1: http has to be true or false.",
            "\(source): service 1: ready has to be a path to wait for, written like \"http:/up\".",
            "\(source): service 1: depends_on has to be a list of service names.",
            "\(source): service 2 has no command, so it was left out.",
        ])
    }

    @Test func anUnreadableFileIsSkippedWithASentence() throws {
        let root = try repo([".bloom/settings.toml": "[scripts\nprepare = 1"])
        let settings = RemoteProjectSettings.load(repo: root)
        #expect(settings.problems.count == 1)
        #expect(settings.problems.first?.contains("was skipped: line 1") == true)
    }
}
