import Foundation

/// The browser shell is small. The host supplies semantic transcript rows, and the CSS draws
/// them using the selected Bloom theme. No transcript payload is interpolated into this page.
enum LocalWebPage {
    @MainActor static func html(nonce: String, devBrowser: Bool) -> String {
        """
        <!doctype html>
        <html lang="en" data-dev-browser="\(devBrowser)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="referrer" content="no-referrer">
          <title>Bloom</title>
          <link rel="icon" href="/assets/bloom-mark.svg" type="image/svg+xml">
          <style>\(LocalWebStyle.css)</style>
        </head>
        <body>
          <div class="shell">
            <aside class="sidebar" id="sidebar">
              <div class="sidebar-head">
                <strong>Projects</strong>
                <button id="mobile-sidebar" type="button" aria-label="Toggle projects" aria-expanded="false">
                  <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3.5 5.5h13M3.5 10h13M3.5 14.5h13"/></svg>
                </button>
              </div>
              <div class="sidebar-actions">
                <button id="new-project" type="button"><span aria-hidden="true">＋</span> New project</button>
                <button id="add-project" type="button">Add folder</button>
              </div>
              <nav class="workspaces" id="workspaces" aria-label="Projects and workspaces"></nav>
              <div class="conversation-head">
                <strong>Conversations</strong>
                <button id="new-conversation" type="button" title="New conversation" aria-label="New conversation">＋</button>
              </div>
              <nav class="conversations" id="conversations" aria-label="Standalone conversations"></nav>
            </aside>
            <main class="stage">
              <header class="top">
                <div><h1 id="title">Choose a workspace</h1><p id="subtitle">Work stays on the host Mac</p></div>
                <button id="new-chat" type="button" title="New chat in this workspace" aria-label="New chat in this workspace">＋</button>
                <button id="toggle-inspector" type="button" title="Show changed files" aria-label="Show changed files">
                  <svg viewBox="0 0 20 20" aria-hidden="true"><rect x="2.5" y="3" width="15" height="14" rx="2"/><path d="M12 3v14"/></svg>
                </button>
                <span class="status" id="status" role="status">Local</span>
              </header>
              <nav class="tabs" id="chats" aria-label="Workspace chats"></nav>
              <div class="content">
                <div class="center-pane">
                  <div class="messages" id="messages">
                    <div class="empty"><strong>Choose a conversation</strong><span>Its transcript will appear here.</span></div>
                  </div>
                  <div class="composer">
                    <form id="compose">
                      <textarea id="prompt" aria-label="Message" placeholder="Ask to make changes, mention files" disabled></textarea>
                      <div class="upload-list" id="uploads"></div>
                      <div class="composer-bar">
                        <div>
                          <button id="attach-file" type="button" title="Attach a file" aria-label="Attach a file" disabled>
                            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="m7 10.5 5.8-5.8a3 3 0 0 1 4.2 4.2l-7.3 7.3a5 5 0 0 1-7.1-7.1l7.1-7.1"/></svg>
                          </button>
                          <span id="chat-settings"></span>
                        </div>
                        <button class="primary" id="send" aria-label="Send message" disabled>
                          <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 15.5v-11m0 0L5.5 9m4.5-4.5L14.5 9"/></svg>
                        </button>
                      </div>
                      <input id="file-picker" type="file" multiple hidden>
                    </form>
                    <div class="hint" id="hint"></div>
                  </div>
                </div>
                <aside class="inspector" id="inspector">
                  <div class="inspector-head">
                    <strong id="file-title">Files</strong>
                    <button id="close-file" type="button" title="Close file" aria-label="Close file">×</button>
                  </div>
                  <div id="file-content" class="file-content">Select a file reference in the transcript.</div>
                </aside>
              </div>
            </main>
          </div>
          <dialog id="create-dialog">
            <form id="create-form">
              <h2 id="create-title">Create</h2>
              <div id="create-fields"></div>
              <p id="create-error" role="alert"></p>
              <div class="dialog-actions">
                <button type="button" id="cancel-create">Cancel</button>
                <button class="primary" id="confirm-create">Create</button>
              </div>
            </form>
          </dialog>
          <div class="login" id="login" \(devBrowser ? "hidden" : "")>
            <form class="login-card" id="login-form">
              <img class="login-mark" src="/assets/bloom-mark.svg" alt="">
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
