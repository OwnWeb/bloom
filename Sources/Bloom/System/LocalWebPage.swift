import Foundation

/// The browser shell is small. The host supplies semantic transcript rows, and the CSS draws
/// them using the selected Bloom theme. No transcript payload is interpolated into this page.
enum LocalWebPage {
    @MainActor static func html(nonce: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="referrer" content="no-referrer">
          <title>Bloom</title>
          <style>\(LocalWebStyle.css)</style>
        </head>
        <body>
          <div class="shell">
            <aside class="sidebar">
              <div class="sidebar-head"><span class="brand-mark">B</span><strong>Bloom</strong><small>Host Mac</small></div>
              <nav class="workspaces" id="workspaces" aria-label="Workspaces"></nav>
              <div class="sidebar-foot">Bloom runs on the host Mac</div>
            </aside>
            <main class="stage">
              <header class="top">
                <div><h1 id="title">Choose a workspace</h1><p id="subtitle">Work stays on the host Mac</p></div>
                <span class="status" id="status">Local</span>
              </header>
              <nav class="tabs" id="chats" aria-label="Conversations"></nav>
              <div class="messages" id="messages"><div class="empty"><strong>Choose a conversation</strong>Its transcript will appear here.</div></div>
              <div class="composer">
                <form id="compose">
                  <textarea id="prompt" aria-label="Message" placeholder="Message the agent" disabled></textarea>
                  <button class="primary" id="send" disabled>Send</button>
                </form>
                <div class="hint" id="hint">Choose a conversation to write a message.</div>
              </div>
            </main>
          </div>
          <div class="login" id="login">
            <form class="login-card" id="login-form">
              <h2>Connect to Bloom</h2>
              <p>Find the access code in Bloom Settings under Browser Access.</p>
              <label for="code">Access code</label>
              <input id="code" type="password" autocomplete="off" spellcheck="false" autofocus>
              <button class="primary">Connect</button>
              <div class="login-error" id="login-error"></div>
            </form>
          </div>
          <script nonce="\(nonce)">\(LocalWebClientScript.javascript)</script>
        </body>
        </html>
        """
    }
}
