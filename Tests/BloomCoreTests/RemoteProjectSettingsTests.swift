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
            id = "app"
            name = "app"
            command = "php artisan octane:start --port=$BLOOM_APP_PORT"
            http = true
            ready = "http:/up"

            [[services]]
            id = "vite"
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
            .init(id: "app", name: "app", command: "php artisan octane:start --port=$BLOOM_APP_PORT", http: true, ready: "http:/up"),
            .init(id: "vite", name: "vite", command: "npm run dev", dependsOn: ["app"]),
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
            id = "old"
            name = "old"
            command = "old"
            """,
            ".bloom/settings.local.toml": """
            [scripts]
            prepare = "from local"

            [[services]]
            id = "new"
            name = "new"
            command = "new"
            """,
        ])
        let settings = RemoteProjectSettings.load(repo: root)
        #expect(settings.prepareScript == "from local")
        #expect(settings.resumeScript == "kept")
        #expect(settings.services.map(\.name) == ["new"])
    }

    @Test func aServiceWithoutAnIdTakesOneFromItsName() throws {
        // **This is what stopped a Cloud workspace setting up.** Every service is registered with
        // runbloom.app as an identity before any of the repository's own scripts run, an empty id
        // is refused there, and the whole setup stopped after the clone having run nothing. These
        // settings are what a repository looked like before ids existed.
        let root = try repo([".bloom/settings.toml": """
        [[services]]
        name = "app"
        command = ".bloom/cloud/service app"

        [[services]]
        name = "Vite Dev Server"
        command = ".bloom/cloud/service vite"

        [[services]]
        id = "chosen"
        name = "proxy"
        command = ".bloom/cloud/service proxy"
        """])
        let settings = RemoteProjectSettings.load(repo: root)

        #expect(settings.services.map(\.id) == ["app", "vite-dev-server", "chosen"])
        #expect(settings.services.allSatisfy { RemoteProjectSettings.validServiceID($0.id) })
        #expect(RemoteProjectSettings.validate(settings.services).isEmpty, "\(RemoteProjectSettings.validate(settings.services))")
    }

    @Test func aDerivedIdIsAlwaysOneTheWireAccepts() {
        // Leading punctuation is trimmed because an id has to start with a letter or a digit, and
        // the length is cut because the wire refuses more than sixty-four bytes.
        #expect(RemoteProjectSettings.serviceID(fromName: "  Web/App (staging) ") == "web-app--staging--")
        #expect(RemoteProjectSettings.serviceID(fromName: "-leading") == "leading")
        #expect(RemoteProjectSettings.serviceID(fromName: String(repeating: "a", count: 200)).utf8.count == 64)
        for name in ["app", "Vite Dev Server", "queue_worker", "api.v2", "-leading", "Web/App (staging)"] {
            #expect(RemoteProjectSettings.validServiceID(RemoteProjectSettings.serviceID(fromName: name)),
                    "\(name) derived an id the wire would refuse")
        }
    }

    @Test func servicesAreValidatedIntoSentences() {
        let services: [RemoteProjectSettings.Service] = [
            .init(id: "", name: "", command: "a"),
            .init(id: "app", name: "app", command: "a", http: true),
            .init(id: "app", name: "app", command: "b", http: true),
            .init(id: "worker", name: "worker", command: "c", dependsOn: ["queue"]),
        ]
        let problems = RemoteProjectSettings.validate(services)
        #expect(problems == [
            "A service has a missing or invalid id. Use lowercase letters, numbers, dots, underscores or hyphens.",
            "A service has no name. Give every [[services]] entry a name.",
            "More than one service has id \"app\". Service ids have to be unique.",
            "More than one service is called \"app\". Service names have to be unique.",
            "\"worker\" depends on \"queue\", which is not a service.",
            "Only one service can set http = true, and 2 do: app, app.",
        ])
    }

    @Test func dependencyCyclesAreNamedInOrder() {
        let services: [RemoteProjectSettings.Service] = [
            .init(id: "web", name: "web", command: "a", dependsOn: ["api"]),
            .init(id: "api", name: "api", command: "b", dependsOn: ["db"]),
            .init(id: "db", name: "db", command: "c", dependsOn: ["api"]),
            .init(id: "solo", name: "solo", command: "d", dependsOn: ["solo"]),
        ]
        let problems = RemoteProjectSettings.validate(services)
        #expect(problems == [
            "\"solo\" depends on itself.",
            "These services depend on each other in a circle: api -> db -> api.",
        ])
        #expect(RemoteProjectSettings.validate([.init(id: "a", name: "a", command: "a"), .init(id: "b", name: "b", command: "b", dependsOn: ["a"])]).isEmpty)
    }

    @Test func wrongTypesAreReportedAndTheRestIsStillRead() throws {
        let root = try repo([".bloom/settings.toml": """
            [remote]
            size = 4

            [[services]]
            id = "app"
            name = "app"
            command = "serve"
            http = "yes"
            ready = "tcp:8000"
            depends_on = "db"

            [[services]]
            id = "empty"
            name = "empty"
            """])
        let settings = RemoteProjectSettings.load(repo: root)
        let source = root + "/.bloom/settings.toml"
        #expect(settings.services == [.init(id: "app", name: "app", command: "serve")])
        #expect(settings.size == nil)
        #expect(settings.problems == [
            "\(source): remote.size has to be a string.",
            "\(source): service 1: http has to be true or false.",
            "\(source): service 1: ready has to be a path to wait for, written like \"http:/up\".",
            "\(source): service 1: depends_on has to be a list of service ids.",
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
