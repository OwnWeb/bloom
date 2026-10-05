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
                        <div class="composer-left">
                          <button id="agent-settings" type="button" title="Agent settings" aria-label="Agent settings" disabled>
                            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 5h14M3 10h14M3 15h14"/><circle cx="7" cy="5" r="1.5"/><circle cx="13" cy="10" r="1.5"/><circle cx="8" cy="15" r="1.5"/></svg>
                            <span id="chat-settings"></span><span class="settings-chevron" aria-hidden="true">⌄</span>
                          </button>
                          <button id="fast-mode" type="button" title="Fast mode" aria-label="Fast mode" aria-pressed="false" hidden>
                            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="m11.5 2-6 9H10l-1.5 7 6-9H10z"/></svg>
                          </button>
                        </div>
                        <div class="composer-right">
                          <button id="context-usage" type="button" title="Context window" aria-label="Context window" hidden></button>
                          <button id="quick-prompts" type="button" title="Quick prompts" aria-label="Quick prompts" disabled>
                            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 5h11M3 9h8M3 13h6M14.5 12v6m-3-3h6"/></svg>
                          </button>
                          <button id="side-question" type="button" title="Ask a side question" aria-label="Ask a side question" hidden>
                            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 4v5a5 5 0 0 0 5 5h8m-4-4 4 4-4 4"/></svg>
                          </button>
                          <button id="attach-file" type="button" title="Attach a file" aria-label="Attach a file" disabled>
                            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="m7 10.5 5.8-5.8a3 3 0 0 1 4.2 4.2l-7.3 7.3a5 5 0 0 1-7.1-7.1l7.1-7.1"/></svg>
                          </button>
                          <button class="primary" id="send" aria-label="Send message" disabled>
                            <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 15.5v-11m0 0L5.5 9m4.5-4.5L14.5 9"/></svg>
                          </button>
                        </div>
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
          <dialog class="composer-dialog" id="agent-dialog" aria-labelledby="agent-dialog-title">
            <div class="composer-dialog-head"><h2 id="agent-dialog-title">Agent settings</h2><button type="button" data-close="agent-dialog" aria-label="Close agent settings">×</button></div>
            <div id="agent-fields" class="agent-fields"></div>
          </dialog>
          <dialog class="composer-dialog" id="quick-dialog" aria-labelledby="quick-dialog-title">
            <div class="composer-dialog-head"><h2 id="quick-dialog-title">Quick prompts</h2><button type="button" data-close="quick-dialog" aria-label="Close quick prompts">×</button></div>
            <input id="quick-search" type="search" placeholder="Search prompts" aria-label="Search quick prompts">
            <div id="quick-list" class="quick-list"></div>
          </dialog>
          <dialog class="composer-dialog" id="context-dialog" aria-labelledby="context-dialog-title">
            <div class="composer-dialog-head"><h2 id="context-dialog-title">Context</h2><button type="button" data-close="context-dialog" aria-label="Close context">×</button></div>
            <div id="context-detail" class="context-detail"></div>
          </dialog>
          <dialog class="composer-dialog" id="side-dialog" aria-labelledby="side-dialog-title">
            <form id="side-form">
              <div class="composer-dialog-head"><h2 id="side-dialog-title">Ask a side question</h2><button type="button" data-close="side-dialog" aria-label="Close side question">×</button></div>
              <p>This question gets a snapshot of the current conversation and runs separately.</p>
              <textarea id="side-prompt" aria-label="Side question" placeholder="What would you like to ask?"></textarea>
              <div class="dialog-actions"><button type="button" data-close="side-dialog">Cancel</button><button class="primary" id="send-side-question">Ask</button></div>
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
