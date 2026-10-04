import Foundation

/// Browser behaviour stays separate from the HTML and theme. Provider payloads never enter here;
/// this script renders the versioned rows the host has already interpreted.
enum LocalWebClientScript {
    static let javascript = #"""
        const $ = id => document.getElementById(id);
        let token = sessionStorage.getItem('bloom-access') || '';
        let workspace = null, chat = null, lastSeq = null, earliestSeq = null, poll = null, fetching = false;
        const shown = new Set(), tools = new Map(), permissions = new Map(), history = new Map();

        async function api(path, options = {}) {
          const response = await fetch(path, {
            ...options,
            headers: { Authorization: `Bearer ${token}`, ...(options.headers || {}) },
            cache: 'no-store'
          });
          if (response.status === 401) {
            sessionStorage.removeItem('bloom-access'); $('login').hidden = false;
            throw Error('Access code was not accepted.');
          }
          if (!response.ok) throw Error(await response.text());
          return response.json();
        }

        function empty(title, detail) {
          const box = document.createElement('div'); box.className = 'empty';
          const heading = document.createElement('strong'); heading.textContent = title;
          box.append(heading, document.createTextNode(detail)); $('messages').replaceChildren(box);
        }

        function earlierButton() {
          const button = document.createElement('button');
          button.id = 'load-earlier'; button.className = 'load-earlier'; button.type = 'button';
          button.textContent = 'Load earlier messages'; button.hidden = true;
          button.addEventListener('click', () => loadEarlier().catch(showError));
          return button;
        }

        function showError(error) {
          $('status').textContent = error.message || 'Connection lost';
          $('status').style.color = 'var(--negative)';
        }

        async function loadWorkspaces() {
          const rows = await api('/api/workspaces');
          const container = $('workspaces'); container.replaceChildren();
          let project = '';
          for (const row of rows) {
            if (row.project !== project) {
              project = row.project;
              const heading = document.createElement('div'); heading.className = 'project-heading';
              heading.textContent = project; container.append(heading);
            }
            const button = document.createElement('button'); button.className = 'workspace';
            button.type = 'button'; button.dataset.workspace = row.id;
            const mark = document.createElement('span'); mark.className = 'mark';
            mark.textContent = project.slice(0, 1).toUpperCase();
            const name = document.createElement('span'); name.className = 'name'; name.textContent = row.name;
            const branch = document.createElement('span'); branch.className = 'branch'; branch.textContent = row.branch;
            button.append(mark, name, branch);
            button.addEventListener('click', () => selectWorkspace(row)); container.append(button);
          }
          if (rows.length) await selectWorkspace(rows[0]);
          else empty('No workspaces yet', 'Create one in the Mac app to begin.');
        }

        async function selectWorkspace(row) {
          workspace = row.id; chat = null; lastSeq = null; earliestSeq = null;
          shown.clear(); tools.clear(); permissions.clear(); history.clear(); clearInterval(poll); poll = null;
          $('title').textContent = row.name; $('subtitle').textContent = `${row.project} · ${row.branch}`;
          $('messages').replaceChildren(); $('prompt').disabled = true; $('send').disabled = true;
          document.querySelectorAll('.workspace').forEach(button => {
            button.classList.toggle('selected', button.dataset.workspace === row.id);
          });
          const rows = await api(`/api/workspaces/${encodeURIComponent(row.id)}/chats`);
          if (workspace !== row.id) return;
          const container = $('chats'); container.replaceChildren();
          for (const entry of rows) {
            const button = document.createElement('button'); button.className = 'chat-tab';
            button.type = 'button'; button.dataset.chat = entry.id; button.textContent = entry.title;
            button.title = `${entry.title} · ${entry.agent}`;
            button.addEventListener('click', () => selectChat(entry)); container.append(button);
          }
          if (rows.length) await selectChat(rows[0]);
          else empty('No conversations yet', 'Create a chat in the Mac app to begin.');
        }

        async function selectChat(entry) {
          chat = entry.id; lastSeq = null; earliestSeq = null;
          shown.clear(); tools.clear(); permissions.clear(); history.clear(); clearInterval(poll);
          $('title').textContent = entry.title; $('subtitle').textContent = `${entry.agent} · ${entry.state}`;
          $('messages').replaceChildren(earlierButton()); $('prompt').disabled = false; $('send').disabled = false;
          $('hint').textContent = 'Agent and files stay on the host Mac.';
          document.querySelectorAll('.chat-tab').forEach(button => {
            button.classList.toggle('selected', button.dataset.chat === entry.id);
          });
          await refresh(); poll = setInterval(() => refresh().catch(showError), 1200);
        }

        function prose(row) {
          const body = document.createElement('div'); body.className = 'prose';
          // The host renders this with MarkdownHTML, which escapes markup and filters addresses.
          if (row.html !== null && row.html !== undefined) body.innerHTML = row.html;
          else body.textContent = row.text;
          return body;
        }

        function activity(row, glyph) {
          const line = document.createElement('div'); line.className = 'activity-line';
          const mark = document.createElement('span'); mark.className = 'glyph'; mark.textContent = glyph;
          const title = document.createElement('span'); title.className = 'activity-title'; title.textContent = row.title;
          const detail = document.createElement('span'); detail.className = 'activity-detail';
          detail.textContent = row.detail;
          line.append(mark, title, detail); return line;
        }

        function toolGlyph(row) {
          if (/shell|command|terminal/i.test(row.title)) return '›';
          if (/read|search|find/i.test(row.title)) return '⌕';
          if (/write|edit|patch/i.test(row.title)) return '✎';
          return '◦';
        }

        function addResult(row) {
          const target = tools.get(row.refID);
          if (target) {
            const output = target.querySelector('.tool-output');
            output.textContent = row.text || (row.isError ? 'Failed' : 'Completed');
            output.classList.toggle('failure', row.isError);
            if (row.isError) target.dataset.tint = 'negative';
            return;
          }
          const orphan = document.createElement('article'); orphan.className = 'entry tool';
          const details = document.createElement('details'); const summary = document.createElement('summary');
          summary.setAttribute('role', 'button'); summary.setAttribute('aria-label', row.title);
          summary.append(activity(row, row.isError ? '!' : '✓'));
          const output = document.createElement('div'); output.className = 'tool-output';
          output.textContent = row.text; details.append(summary, output); orphan.append(details);
          $('messages').append(orphan);
        }

        function addChips(element, labels) {
          if (!labels?.length) return;
          const chips = document.createElement('span'); chips.className = 'chip-list';
          for (const label of labels) {
            const chip = document.createElement('span'); chip.className = 'chip';
            chip.textContent = label; chips.append(chip);
          }
          element.append(chips);
        }

        function appendMessage(row, temporary = false) {
          const key = `${row.seq}:${row.kind}`;
          if (!temporary && shown.has(key)) return;
          if (!temporary) shown.add(key);
          if (row.kind === 'toolResult') { addResult(row); return; }
          const element = document.createElement('article'); element.className = `entry ${row.kind}`;
          if (temporary) element.id = 'streaming';
          if (row.parentToolUseID) element.classList.add('nested');
          if (['user', 'assistant', 'crew', 'plan'].includes(row.kind)) {
            if (row.kind === 'crew' || row.kind === 'plan') {
              const title = document.createElement('div'); title.className = 'card-title';
              title.textContent = row.title; element.append(title);
            }
            element.append(prose(row)); addChips(element, row.chips);
          } else if (row.kind === 'tool') {
            element.dataset.tint = row.tint;
            const details = document.createElement('details'); const summary = document.createElement('summary');
            summary.setAttribute('role', 'button');
            summary.setAttribute('aria-label', `${row.title} ${row.detail}`.trim());
            summary.append(activity(row, toolGlyph(row)));
            const output = document.createElement('div'); output.className = 'tool-output';
            output.textContent = 'Waiting for result';
            details.append(summary, output); element.append(details); addChips(element, row.chips);
            if (row.refID) tools.set(row.refID, element);
          } else if (row.kind === 'thinking') {
            const details = document.createElement('details'); const summary = document.createElement('summary');
            summary.setAttribute('role', 'button'); summary.setAttribute('aria-label', 'Thinking');
            summary.append(activity(row, '◌'));
            const body = document.createElement('div'); body.className = 'thinking-body'; body.textContent = row.text;
            details.append(summary, body); element.append(details);
          } else if (row.kind === 'permission' || row.kind === 'error') {
            const title = document.createElement('div'); title.className = 'card-title'; title.textContent = row.title;
            const body = document.createElement('div'); body.textContent = row.text;
            const note = document.createElement('div'); note.className = 'card-note';
            note.textContent = row.kind === 'permission' ? 'Answer this in Bloom on the host Mac.' : row.detail;
            element.append(title, body, note); if (row.requestID) permissions.set(row.requestID, note);
          } else if (row.kind === 'turnEnd') {
            element.textContent = row.title;
          } else {
            element.append(activity(row, row.kind === 'session' ? '◉' : '•'));
            if (row.text) {
              const text = document.createElement('div'); text.className = 'card-note';
              text.textContent = row.text; element.append(text);
            }
          }
          $('messages').append(element);
        }

        function updateDecisions(decisions) {
          for (const [request, decision] of Object.entries(decisions || {})) {
            const note = permissions.get(request);
            if (note) note.textContent = `Answered: ${decision}`;
          }
        }

        async function loadEarlier() {
          if (!chat || fetching || earliestSeq === null || earliestSeq <= 0) return;
          fetching = true;
          const current = chat;
          const pane = $('messages'); const oldHeight = pane.scrollHeight; const oldTop = pane.scrollTop;
          const button = $('load-earlier'); button.disabled = true;
          try {
            const data = await api(`/api/chats/${encodeURIComponent(current)}/messages?before=${earliestSeq}`);
            if (chat !== current) return;
            if (data.schemaVersion !== 1) throw Error('Bloom was updated. Reload this page.');
            data.messages.forEach(row => history.set(row.seq, row));
            earliestSeq = data.firstSeq; button.hidden = !data.hasMoreEarlier;
            shown.clear(); tools.clear(); permissions.clear();
            pane.replaceChildren(button);
            Array.from(history.values()).sort((a, b) => a.seq - b.seq).forEach(row => appendMessage(row));
            updateDecisions(data.decisions);
            pane.scrollTop = oldTop + pane.scrollHeight - oldHeight;
          } finally { button.disabled = false; fetching = false; }
        }

        async function refresh() {
          if (!chat || fetching) return;
          fetching = true;
          const current = chat;
          const initial = lastSeq === null;
          const path = `/api/chats/${encodeURIComponent(current)}/messages${lastSeq === null ? '' : '?after=' + lastSeq}`;
          try {
            const data = await api(path); if (chat !== current) return;
            if (data.schemaVersion !== 1) throw Error('Bloom was updated. Reload this page.');
            const pane = $('messages');
            const follow = pane.scrollHeight - pane.scrollTop - pane.clientHeight < 100;
            $('streaming')?.remove();
            data.messages.forEach(row => { history.set(row.seq, row); appendMessage(row); });
            if (initial) {
              earliestSeq = data.firstSeq;
              $('load-earlier').hidden = !data.hasMoreEarlier;
            }
            lastSeq = Math.max(lastSeq ?? -1, data.lastSeq);
            updateDecisions(data.decisions);
            if (data.streaming) appendMessage({ seq:-1, kind:'assistant', text:data.streaming, html:data.streamingHTML }, true);
            if (follow) pane.scrollTop = pane.scrollHeight;
            $('status').textContent = 'Connected'; $('status').style.color = '';
          } finally { fetching = false; }
        }

        $('compose').addEventListener('submit', async event => {
          event.preventDefault(); const text = $('prompt').value.trim(); if (!chat || !text) return;
          $('send').disabled = true;
          try {
            await api(`/api/chats/${encodeURIComponent(chat)}/messages`, {
              method:'POST', headers:{ 'Content-Type':'application/json' }, body:JSON.stringify({ text })
            });
            $('prompt').value = ''; await refresh();
          } catch(error) { showError(error); } finally { $('send').disabled = false; }
        });

        $('login-form').addEventListener('submit', async event => {
          event.preventDefault(); token = $('code').value.trim(); $('login-error').textContent = '';
          try { await loadWorkspaces(); sessionStorage.setItem('bloom-access', token); $('login').hidden = true; }
          catch(error) { $('login-error').textContent = error.message; }
        });

        if (token) loadWorkspaces().then(() => { $('login').hidden = true; })
          .catch(error => { $('login-error').textContent = error.message; });
        """#
}
