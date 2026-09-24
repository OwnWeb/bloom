import Foundation

/// The two pages the preview draws itself, rather than the project's app: the one Caddy shows in
/// place of its own 502, and the one a missing or expired preview cookie gets.
///
/// **HTML, and self-contained.** They were plain text, which a browser sets in its default
/// monospace on a white page, and that read as a server that had fallen over rather than as Bloom
/// saying the app is still starting. There is nothing here to fetch: no font, no script, no image.
/// The page is served on the app's own origin, and the `Content-Security-Policy` beside it says so,
/// allowing inline style and nothing else.
///
/// **Printed in the brand's fixed colours, in both appearances**, for the reason `Brand` gives in
/// the app target: the mark was drawn for a deep ground. Fathom `#123B57` down to Abyss `#061420`,
/// Foam `#E9F7F4` for type, `--mist-dim` `#8AA0AB` for a spec line, and the two pools, Shallow
/// `#9BE9DC` and Current `#2AA3B4`. `public/brand/PALETTE.md` in the runbloom.app repository is
/// where they are from.
///
/// **Everything a project supplies is escaped.** A service's name comes from the project's own
/// settings file and its message can quote a process's output, so either could carry markup.
enum PreviewPage {
    /// One service, as the page draws it.
    struct Service: Equatable {
        var name: String
        var state: String
        var restarts: Int
        var message: String?
    }

    /// How long the empty preview waits before asking again. Reloading lands on the app itself the
    /// moment it answers, so somebody who opened the preview a little early does not have to know
    /// to press reload.
    static let retrySeconds = 5

    static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

    static func unavailable(advice: [String], services: [Service]?) -> String {
        var body = """
        <p class="eyebrow"><span class="pulse"></span>Bloom Cloud preview</p>
        <h1>The app is not answering yet</h1>
        <p class="lede">This workspace is up, but the app it runs has not answered the preview.</p>
        """
        let advice = advice.filter { !$0.isEmpty }
        if !advice.isEmpty {
            body += "<div class=\"notice\">" + advice.map { "<p>\(escaped($0))</p>" }.joined() + "</div>"
        }
        switch services {
        case nil:
            break
        case let services? where services.isEmpty:
            body += """
            <p class="empty">No services are configured in <code>.bloom/settings.toml</code>, so nothing was started for it.</p>
            """
        case let services?:
            body += "<ul class=\"services\">" + services.map(row).joined() + "</ul>"
        }
        body += "<p class=\"foot\">Trying again every \(retrySeconds) seconds.</p>"
        return document(title: "Not answering yet", refresh: retrySeconds, body: body)
    }

    static func notAllowed() -> String {
        document(title: "Open this preview from Bloom", refresh: nil, body: """
        <p class="eyebrow">Bloom Cloud preview</p>
        <h1>Open this preview from Bloom</h1>
        <p class="lede">A preview can only be entered through Bloom. If you had it open, it has expired: open it again from Bloom.</p>
        """)
    }

    private static func row(_ service: Service) -> String {
        let restarts = service.restarts > 0 ? "<span class=\"restarts\">\(service.restarts) restart\(service.restarts == 1 ? "" : "s")</span>" : ""
        let message = service.message.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        return """
        <li><div class="line"><span class="name">\(escaped(service.name))</span>\
        <span class="state \(tone(service.state))">\(escaped(service.state.replacingOccurrences(of: "_", with: " ")))</span>\
        \(restarts)</div>\(message.map { "<p class=\"message\">\(escaped($0))</p>" } ?? "")</li>
        """
    }

    /// Which colour a state's pill is drawn in. A class name, never the state itself, so nothing
    /// a supervisor reports can reach the markup unescaped.
    private static func tone(_ state: String) -> String {
        switch state {
        case "running": "good"
        case "crashed", "not_ready": "bad"
        case "stopped": "quiet"
        default: "busy"
        }
    }

    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    private static func document(title: String, refresh: Int?, body: String) -> String {
        let meta = refresh.map { "<meta http-equiv=\"refresh\" content=\"\($0)\">" } ?? ""
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="dark">
        <meta name="robots" content="noindex">
        \(meta)
        <title>\(escaped(title)) · Bloom</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        \(mark)
        \(body)
        </main>
        </body>
        </html>

        """
    }

    /// The mark, drawn small: the lit disc and the dark disc crossing it, from
    /// `Resources/BloomMark.svg` without the tile or the blurs, which at forty points are mud.
    private static let mark = """
    <svg class="mark" viewBox="200 200 636 636" aria-hidden="true">\
    <defs><linearGradient id="lit" x1="0.06" y1="0.02" x2="0.92" y2="0.98">\
    <stop offset="0" stop-color="#F6FEFB"/><stop offset="0.30" stop-color="#7FE8D6"/>\
    <stop offset="0.68" stop-color="#2E9FB6"/><stop offset="1" stop-color="#175F80"/></linearGradient>\
    <clipPath id="disc"><circle cx="518" cy="518" r="290"/></clipPath></defs>\
    <circle cx="518" cy="518" r="290" fill="url(#lit)"/>\
    <g clip-path="url(#disc)"><circle cx="792" cy="812" r="330" fill="#061620"/>\
    <circle cx="792" cy="812" r="330" fill="none" stroke="#9BE9DC" stroke-width="12" opacity="0.8"/></g></svg>
    """

    private static let style = """
    *{box-sizing:border-box;margin:0}
    html{min-height:100%;background:#061420}
    body{min-height:100vh;display:grid;place-items:center;padding:48px 24px;color:#E9F7F4;
    font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
    background:radial-gradient(60vmax 45vmax at 18% 12%,rgba(155,233,220,.10),transparent 70%),
    radial-gradient(55vmax 50vmax at 85% 90%,rgba(42,163,180,.14),transparent 70%),
    linear-gradient(#123B57,#061420) fixed}
    main{width:100%;max-width:560px}
    .mark{width:44px;height:44px;display:block;margin-bottom:28px;filter:drop-shadow(0 0 18px rgba(127,232,214,.35))}
    .eyebrow{font:500 12px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.08em;text-transform:uppercase;
    color:#8AA0AB;display:flex;align-items:center;gap:10px;margin-bottom:14px}
    .pulse{width:8px;height:8px;border-radius:50%;background:#9BE9DC;box-shadow:0 0 0 0 rgba(155,233,220,.6);animation:pulse 2.4s ease-out infinite}
    @keyframes pulse{0%{box-shadow:0 0 0 0 rgba(155,233,220,.55)}70%,100%{box-shadow:0 0 0 10px rgba(155,233,220,0)}}
    @media (prefers-reduced-motion:reduce){.pulse{animation:none}}
    h1{font-size:30px;line-height:1.2;font-weight:650;letter-spacing:-.015em;margin-bottom:12px}
    .lede{color:#B9CBD1;font-size:16px;margin-bottom:28px}
    .notice{border:1px solid rgba(155,233,220,.22);background:rgba(155,233,220,.06);border-radius:12px;padding:14px 16px;margin-bottom:20px}
    .notice p{color:#D6ECE8}.notice p+p{margin-top:4px}
    .services{list-style:none;padding:0;border:1px solid rgba(233,247,244,.10);border-radius:12px;background:rgba(6,20,32,.45);
    margin-bottom:20px;overflow:hidden}
    .services li{padding:12px 16px}.services li+li{border-top:1px solid rgba(233,247,244,.08)}
    .line{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
    .name{font:600 14px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
    .state{font:500 11px/1 ui-monospace,SFMono-Regular,Menlo,monospace;text-transform:uppercase;letter-spacing:.06em;
    padding:4px 7px;border-radius:999px;border:1px solid currentColor}
    .good{color:#9BE9DC}.bad{color:#FF9E8A}.busy{color:#F4CF7A}.quiet{color:#8AA0AB}
    .restarts{font:12px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:#8AA0AB}
    .message{margin-top:6px;font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:#B9CBD1;white-space:pre-wrap;overflow-wrap:anywhere}
    .empty{color:#B9CBD1;margin-bottom:20px}
    code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;background:rgba(233,247,244,.08);padding:2px 6px;border-radius:5px}
    .foot{font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:#8AA0AB}
    """
}
