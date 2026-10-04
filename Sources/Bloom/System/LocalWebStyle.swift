import Foundation
import BloomCore

/// CSS uses the same colour pairs and spacing scale as Bloom's Mac views. Layout adapts at phone
/// widths, while the transcript's visual language stays the same.
enum LocalWebStyle {
    @MainActor static var css: String {
        let theme = ColourThemePreference.shared.choice.surfaces
        let appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        let light = palette(theme, dark: false)
        let dark = palette(theme, dark: true)
        let systemDark = appearance == "system" ? "@media (prefers-color-scheme: dark) { :root { \(dark) } }" : ""
        let chosenDark = appearance == "dark" ? ":root { \(dark) }" : ""
        return ":root { \(light) } \(systemDark) \(chosenDark) \(layout)"
    }

    private static func palette(_ theme: ThemeSurfaces, dark: Bool) -> String {
        func hex(_ pair: PaletteInk.Pair) -> String {
            String(format: "#%06X", pair.member(dark: dark))
        }
        return """
        --surface:\(hex(theme.surface)); --raised:\(hex(theme.raised));
        --sunken:\(hex(theme.sunken)); --sidebar:\(hex(theme.sidebar));
        --selected:\(hex(theme.selected)); --border:\(hex(theme.border));
        --accent:\(hex(PaletteInk.accent)); --accent-fill:\(hex(PaletteInk.accentFill));
        --negative:\(hex(PaletteInk.negative)); --warning:\(hex(PaletteInk.warning));
        --tertiary:\(hex(PaletteInk.textTertiary));
        --text:\(dark ? "#E7F0F3" : "#1D3039");
        --secondary:\(dark ? "#A7BAC4" : "#53646D");
        """
    }

    private static let layout = #"""
        * { box-sizing:border-box; }
        body { margin:0; background:var(--surface); color:var(--text); font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
        button,input,textarea { font:inherit; }
        button { cursor:pointer; }
        .shell { min-height:100dvh; display:grid; grid-template-columns:260px minmax(0,1fr); }
        .sidebar { min-width:0; background:var(--sidebar); border-right:1px solid var(--border); display:flex; flex-direction:column; }
        .sidebar-head { height:59px; border-bottom:1px solid var(--border); display:flex; align-items:center; gap:9px; padding:0 16px; }
        .sidebar-head strong { font-size:15px; }
        .sidebar-head small { color:var(--tertiary); margin-left:auto; }
        .brand-mark { width:24px; height:24px; border-radius:6px; display:grid; place-items:center; background:var(--accent-fill); color:white; font:bold 16px Georgia,serif; }
        .workspaces { flex:1; overflow:auto; padding:14px 8px; }
        .project-heading { margin:14px 9px 5px; color:var(--tertiary); font-size:10px; font-weight:650; letter-spacing:.04em; text-transform:uppercase; }
        .workspace { display:flex; align-items:center; gap:8px; width:100%; min-height:28px; padding:3px 8px; border:0; border-radius:6px; text-align:left; background:transparent; color:var(--text); }
        .workspace:hover,.chat-tab:hover { background:var(--sunken); }
        .workspace.selected,.chat-tab.selected { background:var(--selected); }
        .workspace .mark { width:16px; height:16px; flex:none; border-radius:5px; display:grid; place-items:center; background:var(--accent-fill); color:white; font-size:10px; font-weight:650; }
        .workspace .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .workspace .branch { margin-left:auto; max-width:80px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:var(--tertiary); font-size:10px; }
        .sidebar-foot { border-top:1px solid var(--border); padding:11px 16px; color:var(--tertiary); font-size:10px; }
        .stage { display:flex; flex-direction:column; min-width:0; height:100dvh; background:var(--surface); }
        .top { min-height:59px; padding:8px 24px; display:flex; align-items:center; gap:12px; border-bottom:1px solid var(--border); }
        .top h1 { margin:0; font-size:14px; font-weight:650; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .top p { margin:2px 0 0; color:var(--tertiary); font-size:11px; }
        .status { margin-left:auto; color:var(--accent); font-size:11px; white-space:nowrap; }
        .status::before { content:""; display:inline-block; width:6px; height:6px; margin-right:6px; border-radius:50%; background:currentColor; vertical-align:1px; }
        .tabs { display:flex; align-items:stretch; gap:3px; min-height:36px; padding:0 15px; overflow-x:auto; border-bottom:1px solid var(--border); scrollbar-width:thin; }
        .chat-tab { position:relative; max-width:230px; padding:6px 13px; border:0; border-radius:6px 6px 0 0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; background:transparent; color:var(--secondary); }
        .chat-tab.selected { color:var(--text); font-weight:600; }
        .chat-tab.selected::after { content:""; position:absolute; left:8px; right:8px; bottom:0; height:2px; border-radius:2px; background:var(--accent-fill); }
        .messages { flex:1; display:flex; flex-direction:column; gap:3px; overflow:auto; padding:34px max(24px,calc((100% - 930px)/2)) 24px; }
        .empty { max-width:380px; margin:auto; text-align:center; color:var(--tertiary); }
        .empty strong { display:block; margin-bottom:4px; color:var(--text); font-size:15px; }
        .load-earlier { align-self:center; margin:0 0 16px; padding:5px 10px; border:1px solid var(--border); border-radius:6px; background:var(--raised); color:var(--secondary); font-size:11px; }
        .load-earlier[hidden] { display:none; }
        .entry { min-width:0; flex:none; }
        .entry.user { align-self:flex-end; max-width:min(78%,560px); margin:16px 0 14px; padding:10px 13px; border-radius:12px 12px 4px 12px; background:var(--accent-fill); color:white; }
        .entry.user .prose { white-space:pre-wrap; }
        .entry.user .chip { color:white; border-color:#ffffff70; background:#ffffff1f; }
        .entry.assistant { max-width:820px; margin:20px 0 8px; padding:0 6px; line-height:1.55; }
        .entry.nested { margin-left:20px; border-left:2px solid var(--border); padding-left:12px; }
        .entry.tool,.entry.thinking,.entry.session,.entry.notice,.entry.turnEnd { color:var(--secondary); font-size:12px; }
        .activity-line { display:grid; grid-template-columns:16px minmax(85px,176px) minmax(0,1fr); align-items:baseline; gap:8px; min-height:24px; padding:3px 6px; }
        .glyph { width:16px; text-align:center; color:var(--tertiary); font-size:12px; }
        .tool[data-tint=positive] .glyph { color:var(--accent); }
        .tool[data-tint=negative] .glyph,.entry.error .glyph { color:var(--negative); }
        .tool[data-tint=warning] .glyph,.entry.permission .glyph { color:var(--warning); }
        .activity-title { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-weight:520; }
        .activity-detail { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; min-width:0; color:var(--tertiary); }
        details > summary { list-style:none; cursor:pointer; }
        details > summary::-webkit-details-marker { display:none; }
        details > summary:hover { background:var(--sunken); border-radius:5px; }
        .tool-output,.thinking-body { max-height:340px; margin:3px 8px 12px 30px; padding:10px 12px; overflow:auto; border-left:2px solid var(--border); border-radius:0 5px 5px 0; background:var(--sunken); white-space:pre-wrap; overflow-wrap:anywhere; font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .tool-output.failure { border-left-color:var(--negative); }
        .chip-list { display:inline-flex; flex-wrap:wrap; gap:4px; margin:5px 0 0 30px; }
        .chip { display:inline-block; padding:1px 5px; border:1px solid var(--border); border-radius:5px; color:var(--secondary); font:10px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .entry.permission,.entry.error,.entry.crew,.entry.plan { max-width:820px; margin:10px 4px; padding:10px 13px; border:1px solid var(--border); border-radius:7px; }
        .entry.permission { border-left:3px solid var(--warning); background:var(--sunken); }
        .entry.error { border-left:3px solid var(--negative); }
        .entry.crew { border-left:3px solid var(--accent); }
        .entry.plan { border-left:3px solid var(--accent-fill); }
        .card-title { margin-bottom:4px; font-size:12px; font-weight:650; }
        .card-note { margin-top:5px; color:var(--tertiary); font-size:11px; }
        .entry.turnEnd { display:flex; align-items:center; gap:9px; margin:12px 5px 26px; color:var(--tertiary); font-size:10px; }
        .entry.turnEnd::before,.entry.turnEnd::after { content:""; height:1px; flex:1; background:var(--border); }
        .composer { flex:none; padding:13px max(24px,calc((100% - 930px)/2)) 17px; border-top:1px solid var(--border); background:var(--surface); }
        .composer form { display:flex; align-items:flex-end; gap:8px; padding:7px; border:1px solid var(--border); border-radius:8px; background:var(--sunken); }
        .composer textarea { min-height:42px; max-height:180px; padding:7px 8px; flex:1; border:0; outline:0; resize:vertical; background:transparent; color:var(--text); }
        .primary { padding:8px 13px; border:0; border-radius:6px; background:var(--accent-fill); color:white; font-size:12px; font-weight:650; }
        .primary:disabled { opacity:.5; cursor:default; }
        .hint { margin:6px 3px 0; color:var(--tertiary); font-size:10px; }
        .prose { overflow-wrap:anywhere; }
        .prose > :first-child { margin-top:0; }
        .prose > :last-child { margin-bottom:0; }
        .prose h1,.prose h2,.prose h3 { margin:1.25em 0 .45em; font-size:1.16em; line-height:1.3; }
        .prose h1 { font-size:1.28em; }
        .prose p,.prose ul,.prose ol,.prose blockquote,.prose pre,.prose table { margin:.5em 0 .85em; }
        .prose ul,.prose ol { padding-left:1.7em; }
        .prose blockquote { padding-left:12px; border-left:2px solid var(--border); color:var(--secondary); }
        .prose pre { padding:11px 13px; overflow:auto; border:1px solid var(--border); border-radius:6px; background:var(--sunken); font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .prose :not(pre) > code { padding:1px 3px; border-radius:3px; background:var(--sunken); font:11px ui-monospace,SFMono-Regular,Menlo,monospace; }
        .prose table { display:block; overflow-x:auto; border-collapse:collapse; }
        .prose td,.prose th { padding:5px 8px; border:1px solid var(--border); }
        .prose a { color:var(--accent); }
        .entry.user .prose a { color:white; }
        .prose img { max-width:100%; }
        .login { position:fixed; inset:0; z-index:10; display:grid; place-items:center; padding:24px; background:var(--sidebar); }
        .login[hidden] { display:none; }
        .login-card { width:min(100%,410px); padding:29px; border:1px solid var(--border); border-radius:12px; background:var(--surface); box-shadow:0 12px 35px #0002; }
        .login-card h2 { margin:0 0 5px; font-size:20px; }
        .login-card p { margin:0 0 23px; color:var(--secondary); }
        .login-card label { display:block; margin-bottom:6px; font-size:11px; font-weight:650; }
        .login-card input { width:100%; margin-bottom:11px; padding:10px; border:1px solid var(--border); border-radius:6px; background:var(--sunken); color:var(--text); }
        .login-card .primary { width:100%; }
        .login-error { min-height:18px; margin-top:10px; color:var(--negative); font-size:11px; }
        @media(max-width:700px) { .shell { display:flex; flex-direction:column; } .sidebar { flex:none; border-right:0; border-bottom:1px solid var(--border); } .sidebar-head { height:43px; } .workspaces { display:flex; gap:4px; padding:5px 8px; overflow-x:auto; } .project-heading,.sidebar-foot { display:none; } .workspace { flex:none; width:auto; max-width:185px; } .workspace .branch { display:none; } .stage { height:calc(100dvh - 82px); min-height:350px; } .top { min-height:39px; padding:5px 13px; } .top p { display:none; } .tabs { min-height:33px; padding:0 7px; } .chat-tab { padding:5px 10px; } .messages { padding:15px 10px; } .entry.user { max-width:90%; } .activity-line { grid-template-columns:16px minmax(65px,110px) minmax(0,1fr); } .composer { padding:8px 10px 10px; } }
        """#
}
