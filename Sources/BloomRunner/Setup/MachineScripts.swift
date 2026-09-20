import BloomCore
import Foundation

/// The scripts and services a checkout asks for, read from the repository's own settings files.
///
/// **`scripts.setup` is read here rather than through `SettingsLoader.load`,** because that loader
/// layers the home directory's settings files under the repository's, and on a machine the home
/// directory belongs to the machine, not to anybody's preferences. `RemoteProjectSettings` makes
/// the same choice for `prepare`, `resume` and the services; this applies the rule it applies
/// (a named file wins over inline text in the same file, an empty string states "no script", a
/// later file replaces an earlier one) to the one script it does not carry.
struct MachineScripts {
    var prepare: ScriptLaunch?
    var setup: ScriptLaunch?
    var resume: ScriptLaunch?
    var services: [RemoteProjectSettings.Service]
    var problems: [String]
    /// Whether anything here was written for a Cloud workspace: a `.bloom` settings file, or
    /// `prepare`, `resume` or `[[services]]`, none of which the Mac reads. A repository with none
    /// of them still gets its `setup` script run, but somebody is told first.
    var hasCloudSetup: Bool

    static func load(repo: String) -> MachineScripts {
        let remote = RemoteProjectSettings.load(repo: repo)
        let setup = setupScript(repo: repo)
        let bloomFiles = SettingsLoader.repoPaths(repo: repo)
            .filter { $0.contains("/.bloom/") && FileManager.default.fileExists(atPath: $0) }
        return MachineScripts(
            prepare: ScriptLaunch.resolve(text: remote.prepareScript, file: remote.prepareFile, repo: repo),
            setup: ScriptLaunch.resolve(text: setup.text, file: setup.file, repo: repo),
            resume: ScriptLaunch.resolve(text: remote.resumeScript, file: remote.resumeFile, repo: repo),
            services: remote.services,
            problems: remote.problems,
            hasCloudSetup: !bloomFiles.isEmpty || remote.prepareScript != nil || remote.prepareFile != nil
                || remote.resumeScript != nil || remote.resumeFile != nil || !remote.services.isEmpty
        )
    }

    private static func setupScript(repo: String) -> (text: String?, file: ScriptFile?) {
        var found: (text: String?, file: ScriptFile?) = (nil, nil)
        for path in SettingsLoader.repoPaths(repo: repo) {
            // A file that does not parse is reported by `RemoteProjectSettings.problems` already.
            guard let toml = try? TOML.parse(contentsOf: path) else { continue }
            if let stated = toml["scripts.setup_file"]?.stringValue, !stated.isEmpty {
                let full = SettingsLoader.resolve(stated, repo: repo)
                if let text = try? String(contentsOfFile: full, encoding: .utf8) {
                    let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    found = (hasContent ? text : nil, ScriptFile(path: stated, isMissing: false))
                } else {
                    found = (nil, ScriptFile(path: stated, isMissing: true))
                }
            } else if let text = toml["scripts.setup"]?.stringValue {
                found = (text.isEmpty ? nil : text, nil)
            }
        }
        return found
    }

    /// What to spawn for a script: the file itself when it can introduce itself with a shebang,
    /// otherwise its text through a bash login shell.
    ///
    /// bash rather than `ScriptLaunch.executable`'s zsh, because the machine is Ubuntu and has no
    /// zsh, and a login shell because runtimes installed by `prepare` (nvm, rbenv, a PATH line in
    /// `~/.profile`) announce themselves in the profile files and nowhere else. Nil for a missing
    /// file, which the caller reports instead of running.
    static func command(for launch: ScriptLaunch) -> (executable: String, arguments: [String])? {
        switch launch {
        case .executable(let path): (path, [])
        case .source(let text): ("/bin/bash", ["-lc", text])
        case .missing: nil
        }
    }
}
