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
        let preference = ColourThemePreference.shared
        let face: String
        switch preference.chatFont {
        case "system": face = "-apple-system,BlinkMacSystemFont,sans-serif"
        case "reading": face = "'New York',Georgia,serif"
        default:
            let name = preference.chatFont.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            face = "'\(name)',-apple-system,BlinkMacSystemFont,sans-serif"
        }
        let typography = ":root { --chat-font:\(face); --chat-size:\(13 * preference.chatTextSize.scale)px; --chat-leading:\(preference.chatLineHeight.ratio); --sidebar-width:\(Metrics.sidebarWidth)px; --inspector-width:\(Metrics.inspectorWidth)px; --row-height:\(Metrics.rowHeight)px; --corner:\(Metrics.corner)px; }"
        return ":root { \(light) } \(systemDark) \(chosenDark) \(typography) \(layout)"
    }

    private static func palette(_ theme: ThemeSurfaces, dark: Bool) -> String {
        func hex(_ pair: PaletteInk.Pair) -> String {
            String(format: "#%06X", pair.member(dark: dark))
        }
        return """
        color-scheme:\(dark ? "dark" : "light");
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
        body { margin:0; background:var(--surface); color:var(--text); font:13px/1.48 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; -webkit-font-smoothing:antialiased; }
        button,input,textarea { font:inherit; }
        button { cursor:pointer; transition:background-color .14s ease,color .14s ease,box-shadow .14s ease; }
        button:focus-visible,input:focus-visible,textarea:focus-visible,summary:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
        ::selection { background:var(--selected); color:var(--text); }
        .shell { height:100dvh; min-height:0; display:grid; grid-template-columns:var(--sidebar-width) minmax(0,1fr); }
        .sidebar { min-width:0; min-height:0; background:var(--sidebar); border-right:1px solid var(--border); display:flex; flex-direction:column; }
        .sidebar-head { height:53px; flex:none; display:flex; align-items:center; justify-content:space-between; gap:9px; padding:0 16px; }
        .sidebar-head strong { font-size:11px; font-weight:650; color:var(--secondary); letter-spacing:.015em; }
        .sidebar-head button { display:none; width:30px; height:30px; place-items:center; border:0; border-radius:6px; background:transparent; color:var(--secondary); }
        .sidebar-head svg,.top svg,.composer-bar svg { width:18px; height:18px; fill:none; stroke:currentColor; stroke-width:1.7; stroke-linecap:round; stroke-linejoin:round; }
        .workspaces { flex:1; min-height:0; overflow:auto; padding:8px 8px 16px; scrollbar-width:thin; }
        .sidebar-actions { display:flex; gap:5px; padding:9px 10px 0; }
        .sidebar-actions button,.conversation-head button,.project-heading button,.top > button,.inspector-head button { border:0; border-radius:5px; background:transparent; color:var(--secondary); }
        .sidebar-actions button { min-height:27px; padding:4px 8px; background:var(--sunken); font-size:11px; }
        .sidebar-actions #new-project { background:var(--selected); color:var(--text); font-weight:600; }
        .sidebar-actions #new-project span { font-size:15px; line-height:0; vertical-align:-1px; }
        .sidebar-actions button:hover,.conversation-head button:hover,.project-heading button:hover,.top > button:hover,.inspector-head button:hover { background:var(--selected); }
        .project-heading { display:flex; align-items:center; gap:7px; margin:13px 9px 4px; color:var(--text); font-size:11px; font-weight:650; }
        .project-heading > span:nth-child(2) { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .project-icon { width:16px; height:16px; flex:none; display:grid; place-items:center; border-radius:5px; background:var(--accent-fill); color:white; font-size:9px; font-weight:700; }
        .project-heading button { font-size:16px; line-height:1; }
        .workspace { display:flex; align-items:center; gap:8px; width:100%; min-height:var(--row-height); padding:3px 8px; border:0; border-radius:var(--corner); text-align:left; background:transparent; color:var(--text); font-size:11px; }
        .workspace:hover,.chat-tab:hover { background:var(--sunken); }
        .workspace.selected,.chat-tab.selected { background:var(--selected); font-weight:600; }
        .workspace .mark { width:6px; height:6px; margin:0 5px; flex:none; border-radius:50%; background:var(--accent-fill); }
        .workspace .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .workspace .branch { display:none; }
        .conversation-head { display:flex; align-items:center; justify-content:space-between; padding:8px 16px 3px; color:var(--tertiary); font-size:10px; text-transform:uppercase; letter-spacing:.045em; }
        .conversation-head button { width:23px; height:23px; font-size:17px; line-height:1; }
        .conversations { max-height:25vh; min-height:36px; overflow:auto; padding:3px 8px 8px; }
        .conversation { display:block; width:100%; border:0; border-radius:6px; padding:5px 9px; text-align:left; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; background:transparent; color:var(--text); font-size:11px; }
        .conversation:hover { background:var(--sunken); } .conversation.selected { background:var(--selected); }
        .stage { display:flex; flex-direction:column; min-width:0; height:100dvh; background:var(--surface); }
        .top { min-height:53px; padding:7px 20px 7px 24px; display:flex; align-items:center; gap:6px; border-bottom:1px solid var(--border); }
        .top > div { flex:1; min-width:0; }
        .top > button { width:29px; height:29px; display:grid; place-items:center; font-size:19px; line-height:1; }
        .top h1 { margin:0; font-size:12px; font-weight:650; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .top p { margin:1px 0 0; color:var(--tertiary); font-size:10px; }
        .status { color:var(--accent); font-size:11px; white-space:nowrap; }
        .status:empty { display:none; }
        .status::before { content:""; display:inline-block; width:6px; height:6px; margin-right:6px; border-radius:50%; background:currentColor; vertical-align:1px; }
        .tabs { display:flex; align-items:stretch; gap:3px; min-height:34px; padding:0 15px; overflow-x:auto; border-bottom:1px solid var(--border); scrollbar-width:thin; }
        .tabs[hidden] { display:none; }
        .chat-tab { position:relative; max-width:230px; padding:6px 13px; border:0; border-radius:6px 6px 0 0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; background:transparent; color:var(--secondary); }
        .chat-tab.selected { color:var(--text); font-weight:600; }
        .chat-tab.selected::after { content:""; position:absolute; left:8px; right:8px; bottom:0; height:2px; border-radius:2px; background:var(--accent-fill); }
        .content { position:relative; flex:1; display:flex; min-height:0; }
        .center-pane { flex:1; display:flex; flex-direction:column; min-width:0; min-height:0; }
        .messages { flex:1; display:flex; flex-direction:column; gap:3px; min-width:0; overflow:auto; padding:26px max(24px,calc((100% - 790px)/2)) 20px; scrollbar-width:thin; }
        .inspector { display:none; width:var(--inspector-width); flex:none; border-left:1px solid var(--border); background:var(--raised); overflow:hidden; }
        .inspector.open { display:flex; flex-direction:column; }
        .inspector-head { min-height:43px; display:flex; align-items:center; justify-content:space-between; gap:8px; padding:7px 14px; border-bottom:1px solid var(--border); }
        .inspector-head strong { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:11px; font-weight:650; }
        .inspector-head button { font-size:18px; }
        .file-content { flex:1; overflow:auto; padding:12px; color:var(--secondary); font-size:11px; }
        .inspector-empty { min-height:100%; display:flex; flex-direction:column; align-items:center; justify-content:center; gap:5px; padding:24px; text-align:center; color:var(--tertiary); }
        .inspector-empty-icon { width:38px; height:38px; display:grid; place-items:center; margin-bottom:10px; border:2px solid var(--border); border-radius:50%; color:var(--tertiary); font-size:23px; line-height:1; }
        .inspector-empty strong { color:var(--secondary); font-size:12px; font-weight:650; }
        .inspector-empty span:last-child { max-width:220px; line-height:1.4; }
        .file-content pre { margin:0; font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .file-image { display:block; max-width:100%; height:auto; margin:auto; }
        .file-line { white-space:pre; } .file-line > span { display:inline-block; width:35px; margin-right:8px; text-align:right; color:var(--tertiary); user-select:none; }
        .file-line.focused { background:var(--selected); color:var(--text); }
        .changes-list { display:flex; flex-direction:column; gap:2px; }
        .change-file { display:grid; grid-template-columns:14px minmax(0,1fr) auto; gap:7px; align-items:center; width:100%; padding:5px 4px; border:0; border-radius:5px; text-align:left; background:transparent; color:var(--text); font-size:11px; }
        .change-file:hover { background:var(--selected); }
        .change-file > span:nth-child(2) { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .change-file > span:first-child { color:var(--accent); font:10px ui-monospace,SFMono-Regular,Menlo,monospace; }
        .change-file small { color:var(--tertiary); font-size:10px; }
        .back-to-changes { margin:0 0 9px; border:0; background:transparent; color:var(--accent); font-size:11px; }
        .empty { max-width:380px; margin:auto; text-align:center; color:var(--tertiary); }
        .empty strong { display:block; margin-bottom:4px; color:var(--text); font-size:14px; }
        .load-earlier { align-self:center; margin:0 0 16px; padding:5px 10px; border:1px solid var(--border); border-radius:6px; background:var(--raised); color:var(--secondary); font-size:11px; }
        .load-earlier[hidden] { display:none; }
        .entry { min-width:0; flex:none; }
        .entry.user { align-self:flex-end; max-width:min(78%,560px); margin:15px 0 12px; padding:8px 11px; border-radius:11px 11px 4px 11px; background:var(--accent-fill); color:white; }
        .entry.user .prose { white-space:pre-wrap; }
        .entry.user .chip { color:white; border-color:#ffffff70; background:#ffffff1f; }
        .entry.assistant { max-width:820px; margin:17px 0 8px; padding:0 4px; font:var(--chat-size)/var(--chat-leading) var(--chat-font); }
        .entry.user .prose,.entry.crew .prose,.entry.plan .prose { font:var(--chat-size)/var(--chat-leading) var(--chat-font); }
        .file-link { border:0; border-bottom:1px dotted currentColor; padding:0; background:transparent; color:var(--accent); cursor:pointer; font:inherit; }
        .entry.user .file-link { color:white; }
        .entry.nested { margin-left:20px; border-left:2px solid var(--border); padding-left:12px; }
        .entry.tool,.entry.thinking,.entry.session,.entry.notice { color:var(--secondary); font-size:12px; }
        .activity-line { display:grid; grid-template-columns:16px minmax(85px,176px) minmax(0,1fr); align-items:baseline; gap:8px; min-height:25px; padding:4px 6px; border-radius:5px; }
        .glyph { width:16px; text-align:center; color:var(--tertiary); font-size:12px; }
        .tool[data-tint=positive] .glyph { color:var(--accent); }
        .tool[data-tint=negative] .glyph,.entry.error .glyph { color:var(--negative); }
        .tool[data-tint=warning] .glyph,.entry.permission .glyph { color:var(--warning); }
        .activity-title { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-weight:520; }
        .activity-detail { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; min-width:0; color:var(--tertiary); }
        details > summary { list-style:none; cursor:pointer; }
        details > summary::-webkit-details-marker { display:none; }
        details > summary:hover { background:var(--sunken); border-radius:5px; }
        details > summary:focus-visible { border-radius:5px; }
        .tool-output,.thinking-body { max-height:340px; margin:3px 8px 12px 30px; padding:10px 12px; overflow:auto; border-left:2px solid var(--border); border-radius:0 5px 5px 0; background:var(--sunken); white-space:pre-wrap; overflow-wrap:anywhere; font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .tool-output.failure { border-left-color:var(--negative); }
        .chip-list { display:inline-flex; flex-wrap:wrap; gap:4px; margin:5px 0 0 30px; }
        .chip { display:inline-block; padding:1px 5px; border:1px solid var(--border); border-radius:5px; color:var(--secondary); font:10px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .entry.permission,.entry.error,.entry.crew,.entry.plan { max-width:820px; margin:10px 4px; padding:10px 13px; border:1px solid var(--border); border-radius:7px; }
        .entry.permission { background:var(--sunken); }
        .permission-actions { display:flex; gap:7px; margin-top:9px; }
        .permission-actions button:not(.primary) { border:1px solid var(--border); border-radius:var(--corner); padding:6px 11px; background:var(--raised); color:var(--text); font-size:11px; }
        .question-form { display:flex; flex-direction:column; align-items:flex-start; gap:12px; margin-top:10px; }
        .question-form fieldset { width:100%; margin:0; padding:0; border:0; }
        .question-form legend { margin-bottom:7px; font-weight:600; }
        .question-header { display:block; margin-bottom:4px; color:var(--accent); font-size:10px; font-weight:650; letter-spacing:.05em; text-transform:uppercase; }
        .question-hint { display:block; margin:-3px 0 7px; color:var(--tertiary); }
        .question-option { display:flex; align-items:flex-start; gap:8px; padding:7px 9px; border:1px solid var(--border); border-radius:var(--corner); background:var(--raised); cursor:pointer; }
        .question-option + .question-option { margin-top:5px; }
        .question-option input { margin:2px 0 0; accent-color:var(--accent); }
        .question-option small { display:block; margin-top:2px; color:var(--secondary); }
        .question-form pre { padding:8px; overflow:auto; background:var(--surface); font:11px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .question-other { display:block; margin-top:8px; color:var(--secondary); font-size:11px; }
        .question-other input { display:block; width:100%; margin-top:4px; padding:8px; border:1px solid var(--border); border-radius:var(--corner); background:var(--surface); color:var(--text); }
        .card-title { margin-bottom:4px; font-size:12px; font-weight:650; }
        .card-note { margin-top:5px; color:var(--tertiary); font-size:11px; }
        .composer { flex:none; padding:8px max(24px,calc((100% - 820px)/2)) 14px; background:var(--surface); }
        .composer form { display:flex; flex-direction:column; gap:3px; padding:7px 8px 6px; border:1px solid var(--border); border-radius:13px; background:var(--raised); box-shadow:0 2px 10px #0000000c,0 10px 28px #00000008; transition:border-color .14s ease,box-shadow .14s ease; }
        .composer form:focus-within { border-color:var(--accent); box-shadow:0 0 0 2px color-mix(in srgb,var(--accent) 12%,transparent),0 6px 20px #00000012; }
        .composer textarea { width:100%; min-height:32px; max-height:180px; padding:5px 7px; border:0; outline:0; resize:vertical; background:transparent; color:var(--text); }
        .composer textarea:focus-visible { outline:0; }
        .composer textarea::placeholder { color:var(--tertiary); opacity:1; }
        .composer-bar { display:flex; align-items:center; justify-content:space-between; gap:8px; padding:0 2px 0 4px; color:var(--tertiary); font-size:10px; }
        .composer-bar > div { display:flex; align-items:center; gap:3px; min-width:0; }
        .composer-bar [hidden] { display:none !important; }
        .composer-bar button:not(.primary) { min-width:27px; height:27px; display:inline-flex; align-items:center; justify-content:center; gap:5px; padding:0 5px; border:0; border-radius:6px; background:transparent; color:var(--secondary); }
        .composer-bar button:not(.primary):hover { background:var(--sunken); color:var(--text); }
        .composer-bar button:not(.primary):disabled { opacity:.5; cursor:default; }
        #agent-settings { max-width:min(250px,37vw); }
        #agent-settings svg { flex:none; }
        #chat-settings { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:11px; }
        .settings-chevron { flex:none; font-size:13px; line-height:1; }
        #fast-mode[aria-pressed="true"] { background:color-mix(in srgb,var(--warning) 16%,transparent); color:var(--warning); }
        #context-usage { font-size:11px; font-variant-numeric:tabular-nums; }
        #attach-file { flex:none; }
        .upload-list:empty { display:none; }
        .upload-list { display:flex; flex-wrap:wrap; gap:5px; padding:0 8px 4px; }
        .upload-chip { display:flex; align-items:center; gap:5px; padding:2px 5px; border:1px solid var(--border); border-radius:5px; background:var(--sunken); color:var(--secondary); font:11px ui-monospace,SFMono-Regular,Menlo,monospace; }
        .upload-chip button { border:0; background:transparent; color:var(--secondary); font-size:13px; }
        .composer-bar .primary { width:29px; height:29px; display:grid; place-items:center; padding:0; border-radius:50%; }
        #send svg { width:17px; height:17px; stroke-width:2.2; }
        .primary { padding:8px 13px; border:0; border-radius:7px; background:var(--accent-fill); color:white; font-size:12px; font-weight:650; }
        .primary:hover:not(:disabled) { filter:brightness(1.1); }
        .primary:disabled { opacity:.5; cursor:default; }
        .hint { margin:6px 3px 0; color:var(--tertiary); font-size:10px; }
        .hint:empty { display:none; }
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
        .login-card { width:min(100%,410px); padding:30px; border:1px solid var(--border); border-radius:15px; background:var(--surface); box-shadow:0 16px 45px #00000018; }
        .login-mark { display:block; width:46px; height:46px; margin:0 0 16px -5px; object-fit:contain; }
        .login-card h2 { margin:0 0 5px; font-size:19px; letter-spacing:-.02em; }
        .login-card p { margin:0 0 23px; color:var(--secondary); }
        .login-card label { display:block; margin-bottom:6px; font-size:11px; font-weight:650; }
        .login-card input { width:100%; margin-bottom:11px; padding:10px; border:1px solid var(--border); border-radius:7px; background:var(--sunken); color:var(--text); }
        .login-card .primary { width:100%; }
        .login-error { min-height:18px; margin-top:10px; color:var(--negative); font-size:11px; }
        dialog { width:min(94vw,480px); border:1px solid var(--border); border-radius:10px; padding:22px; background:var(--surface); color:var(--text); box-shadow:0 16px 55px #0005; }
        dialog::backdrop { background:#0008; }
        dialog h2 { margin:0 0 18px; font-size:16px; }
        #create-fields label { display:block; margin:12px 0; color:var(--secondary); font-size:11px; }
        #create-fields input,#create-fields textarea { display:block; width:100%; margin-top:5px; padding:9px; border:1px solid var(--border); border-radius:6px; outline-color:var(--accent); background:var(--sunken); color:var(--text); font-size:13px; }
        #create-fields textarea { min-height:110px; resize:vertical; }
        #create-error { min-height:1em; color:var(--negative); font-size:11px; }
        .dialog-actions { display:flex; justify-content:flex-end; gap:8px; }
        .dialog-actions button:not(.primary) { border:1px solid var(--border); border-radius:6px; background:var(--raised); color:var(--text); padding:7px 12px; }
        .composer-dialog { width:min(94vw,380px); max-height:min(80dvh,680px); overflow:auto; padding:17px; }
        .composer-dialog-head { display:flex; align-items:center; gap:12px; margin-bottom:13px; }
        .composer-dialog-head h2 { flex:1; margin:0; font-size:14px; }
        .composer-dialog-head button { width:27px; height:27px; border:0; border-radius:5px; background:transparent; color:var(--secondary); font-size:18px; }
        .composer-dialog-head button:hover { background:var(--sunken); }
        .agent-fields { display:flex; flex-direction:column; gap:11px; }
        .agent-fields label { display:flex; flex-direction:column; gap:4px; color:var(--secondary); font-size:11px; font-weight:600; }
        .agent-fields select { width:100%; padding:7px 9px; border:1px solid var(--border); border-radius:6px; background:var(--sunken); color:var(--text); font-size:12px; }
        .agent-fields small { color:var(--tertiary); font-weight:400; line-height:1.4; }
        .composer-dialog p { margin:0 0 12px; color:var(--secondary); font-size:11px; }
        .composer-dialog textarea,.composer-dialog input[type="search"] { width:100%; padding:9px; border:1px solid var(--border); border-radius:7px; background:var(--sunken); color:var(--text); }
        .composer-dialog textarea { min-height:92px; margin-bottom:13px; resize:vertical; }
        .quick-list { display:flex; flex-direction:column; gap:3px; margin-top:9px; }
        .quick-list button { display:flex; flex-direction:column; gap:2px; width:100%; padding:8px; border:0; border-radius:6px; text-align:left; background:transparent; color:var(--text); }
        .quick-list button:hover { background:var(--sunken); }
        .quick-list small { color:var(--tertiary); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .quick-list .quick-empty { padding:10px; color:var(--tertiary); }
        .context-detail { display:flex; flex-direction:column; gap:9px; color:var(--secondary); font-size:12px; }
        .context-detail .context-row { display:flex; justify-content:space-between; gap:12px; }
        .context-track { height:6px; overflow:hidden; border-radius:6px; background:var(--selected); }
        .context-track > span { display:block; height:100%; background:var(--accent); }
        @media(max-width:1100px) { .inspector.open { position:absolute; z-index:2; right:0; top:0; bottom:0; box-shadow:-8px 0 20px #0003; } }
        @media(max-width:700px) { .shell { display:flex; flex-direction:column; } .sidebar { flex:none; height:32dvh; max-height:32dvh; border-right:0; border-bottom:1px solid var(--border); } .sidebar-head { height:43px; flex:none; } .sidebar-actions { padding:4px 8px; } .workspaces { display:block; min-height:40px; padding:2px 8px; overflow:auto; } .project-heading { margin:7px 5px 2px; } .workspace .branch { display:none; } .conversation-head { padding:4px 12px 2px; } .conversations { display:flex; gap:4px; min-height:34px; padding:3px 8px; overflow-x:auto; } .conversation { width:auto; max-width:180px; flex:none; } .stage { height:68dvh; min-height:350px; } .top { min-height:41px; padding:5px 13px; } .top p { display:none; } .tabs { min-height:33px; padding:0 7px; } .chat-tab { padding:5px 10px; } .messages { padding:15px 12px; } .inspector.open { width:min(92vw,360px); } .entry.user { max-width:90%; } .activity-line { grid-template-columns:16px minmax(65px,110px) minmax(0,1fr); } .composer { padding:6px 10px max(9px,env(safe-area-inset-bottom)); } }
        @media(max-width:700px) { .sidebar { height:43px; } .sidebar.expanded { height:32dvh; } .sidebar-head { justify-content:space-between; } .sidebar-head button { display:grid; } .sidebar:not(.expanded) .sidebar-actions,.sidebar:not(.expanded) .workspaces,.sidebar:not(.expanded) .conversation-head,.sidebar:not(.expanded) .conversations { display:none; } .stage { flex:1; height:auto; min-height:0; } }
        @media(max-width:700px) { .inspector.open:not(.requested) { display:none; } }
        @media(max-width:540px) { #chat-settings,.settings-chevron { display:none; } #agent-settings { width:27px; padding:0; } #context-usage { display:none !important; } .composer-bar > div { gap:2px; } }
        @media(prefers-reduced-motion:reduce) { button,.composer form { transition:none; } }
        """#
}
