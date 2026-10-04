import Foundation

/// Browser behaviour stays separate from the HTML and theme. Provider payloads never enter here;
/// this script renders the versioned rows the host has already interpreted.
enum LocalWebClientScript {
    static let javascript = #"""
        const $ = id => document.getElementById(id);
        let token = sessionStorage.getItem('bloom-access') || '';
        let workspace = null, chat = null, lastSeq = null, earliestSeq = null, poll = null, fetching = false;
        let projectRows = [], workspaceRows = [];
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

        function collapseSidebar() {
          $('sidebar').classList.remove('expanded');
          $('mobile-sidebar').setAttribute('aria-expanded', 'false');
        }

        async function loadWorkspaces() {
          const [projects, rows, conversations] = await Promise.all([
            api('/api/projects'), api('/api/workspaces'), api('/api/conversations')
          ]);
          projectRows.splice(0, projectRows.length, ...projects);
          workspaceRows.splice(0, workspaceRows.length, ...rows);
          const container = $('workspaces'); container.replaceChildren();
          for (const project of projects) {
            const heading = document.createElement('div'); heading.className = 'project-heading';
            const icon = document.createElement('span'); icon.className = 'project-icon';
            icon.textContent = project.name.slice(0, 1).toUpperCase();
            if (/^[0-9a-fA-F]{6}$/.test(project.accent)) icon.style.backgroundColor = `#${project.accent}`;
            const name = document.createElement('span'); name.textContent = project.name;
            const add = document.createElement('button'); add.type = 'button'; add.textContent = '＋';
            add.title = `New workspace in ${project.name}`;
            add.addEventListener('click', () => showCreate('workspace', project));
            heading.append(icon, name, add); container.append(heading);
            for (const row of rows.filter(item => item.projectID === project.id)) {
            const button = document.createElement('button'); button.className = 'workspace';
            button.type = 'button'; button.dataset.workspace = row.id;
            const mark = document.createElement('span'); mark.className = 'mark';
            if (/^[0-9a-fA-F]{6}$/.test(project.accent)) mark.style.backgroundColor = `#${project.accent}`;
            const name = document.createElement('span'); name.className = 'name'; name.textContent = row.name;
            const branch = document.createElement('span'); branch.className = 'branch'; branch.textContent = row.branch;
            button.append(mark, name, branch);
            button.addEventListener('click', () => selectWorkspace(row)); container.append(button);
            }
          }
          const conversationList = $('conversations'); conversationList.replaceChildren();
          for (const entry of conversations) {
            const button = document.createElement('button'); button.className = 'conversation';
            button.type = 'button'; button.dataset.conversation = entry.id;
            button.textContent = entry.title;
            button.addEventListener('click', () => selectConversation(entry)); conversationList.append(button);
          }
          const savedWorkspace = workspace || sessionStorage.getItem('bloom-workspace');
          const savedConversation = !workspace && (chat || sessionStorage.getItem('bloom-conversation'));
          const savedChat = sessionStorage.getItem('bloom-chat');
          if (savedWorkspace && rows.some(row => row.id === savedWorkspace)) {
            await selectWorkspace(rows.find(row => row.id === savedWorkspace), savedChat);
          } else if (savedConversation && conversations.some(row => row.id === savedConversation)) {
            await selectConversation(conversations.find(row => row.id === savedConversation));
          } else if (projects.length && rows.length) {
            const first = projects.map(project => rows.find(row => row.projectID === project.id)).find(Boolean);
            await selectWorkspace(first || rows[0]);
          } else if (conversations.length) await selectConversation(conversations[0]);
          else { $('new-chat').hidden = true; empty('Start in Bloom', 'Create a project or conversation from the sidebar.'); }
        }

        async function selectWorkspace(row, preferredChat = null) {
          workspace = row.id; chat = null; lastSeq = null; earliestSeq = null;
          collapseSidebar();
          sessionStorage.setItem('bloom-workspace', row.id); sessionStorage.removeItem('bloom-conversation');
          $('new-chat').hidden = false;
          shown.clear(); tools.clear(); permissions.clear(); history.clear(); clearInterval(poll); poll = null;
          $('title').textContent = row.name; $('subtitle').textContent = `${row.project} · ${row.branch}`;
          $('messages').replaceChildren(); $('prompt').disabled = true; $('send').disabled = true;
          document.querySelectorAll('.workspace').forEach(button => {
            button.classList.toggle('selected', button.dataset.workspace === row.id);
          });
          document.querySelectorAll('.conversation').forEach(button => button.classList.remove('selected'));
          const rows = await api(`/api/workspaces/${encodeURIComponent(row.id)}/chats`);
          if (workspace !== row.id) return;
          const container = $('chats'); container.replaceChildren();
          container.hidden = rows.length <= 1;
          for (const entry of rows) {
            const button = document.createElement('button'); button.className = 'chat-tab';
            button.type = 'button'; button.dataset.chat = entry.id; button.textContent = entry.title;
            button.title = `${entry.title} · ${entry.agent}`;
            button.addEventListener('click', () => selectChat(entry)); container.append(button);
          }
          if (rows.length) await selectChat(rows.find(entry => entry.id === preferredChat) || rows[0]);
          else empty('No conversations yet', 'Use the plus button above to create a chat.');
          loadChanges(row.id).catch(showError);
        }

        async function selectConversation(entry) {
          workspace = null; chat = null; lastSeq = null; earliestSeq = null;
          collapseSidebar();
          sessionStorage.setItem('bloom-conversation', entry.id); sessionStorage.removeItem('bloom-workspace');
          $('new-chat').hidden = true;
          shown.clear(); tools.clear(); permissions.clear(); history.clear(); clearInterval(poll); poll = null;
          $('chats').replaceChildren();
          $('chats').hidden = true;
          $('inspector').classList.remove('open');
          document.querySelectorAll('.workspace').forEach(button => button.classList.remove('selected'));
          document.querySelectorAll('.conversation').forEach(button => {
            button.classList.toggle('selected', button.dataset.conversation === entry.id);
          });
          await selectChat(entry);
        }

        async function selectChat(entry) {
          chat = entry.id; lastSeq = null; earliestSeq = null;
          if (workspace) sessionStorage.setItem('bloom-chat', entry.id);
          shown.clear(); tools.clear(); permissions.clear(); history.clear(); clearInterval(poll);
          $('title').textContent = entry.title; $('subtitle').textContent = `${entry.agent} · ${entry.state}`;
          $('messages').replaceChildren(earlierButton()); $('prompt').disabled = false; $('send').disabled = false;
          $('chat-settings').textContent = [entry.model || entry.agent, entry.effort].filter(Boolean).join(' · ');
          $('hint').textContent = '';
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
          if (workspace && row.files?.length) {
            linkReferences(body, row.files);
            for (const anchor of body.querySelectorAll('a[href]')) {
              const file = row.files.find(item => item.label === anchor.textContent);
              if (!file) continue;
              anchor.removeAttribute('href'); anchor.classList.add('file-link');
              anchor.tabIndex = 0; anchor.setAttribute('role', 'button');
              anchor.addEventListener('click', () => openFile(file));
              anchor.addEventListener('keydown', event => { if (event.key === 'Enter') openFile(file); });
            }
          }
          return body;
        }

        function linkReferences(body, files) {
          const byLabel = new Map(files.map(file => [file.label, file]));
          const labels = [...byLabel.keys()].sort((a, b) => b.length - a.length);
          const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
          const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
          for (const node of nodes) {
            if (node.parentElement.closest('a,pre')) continue;
            const text = node.textContent; let position = 0; const fragment = document.createDocumentFragment();
            while (position < text.length) {
              let hit = null, index = text.length;
              for (const label of labels) {
                const found = text.indexOf(label, position);
                if (found >= 0 && found < index) { hit = label; index = found; }
              }
              if (!hit) break;
              fragment.append(document.createTextNode(text.slice(position, index)));
              const file = byLabel.get(hit); const link = document.createElement('button');
              link.className = 'file-link'; link.type = 'button'; link.textContent = hit;
              link.addEventListener('click', () => openFile(file)); fragment.append(link);
              position = index + hit.length;
            }
            if (position) { fragment.append(document.createTextNode(text.slice(position))); node.replaceWith(fragment); }
          }
        }

        async function openFile(file) {
          if (!workspace) return;
          $('inspector').classList.add('open'); $('file-title').textContent = file.path;
          $('file-content').textContent = 'Loading file…';
          try {
            const result = await api(`/api/workspaces/${encodeURIComponent(workspace)}/files?path=${encodeURIComponent(file.path)}`);
            const back = document.createElement('button'); back.className = 'back-to-changes';
            back.type = 'button'; back.textContent = '‹ Changes';
            back.addEventListener('click', () => loadChanges(workspace).catch(showError));
            if (result.imageDataURL) {
              const picture = document.createElement('img'); picture.className = 'file-image';
              picture.src = result.imageDataURL; picture.alt = file.path;
              $('file-content').replaceChildren(back, picture);
              return;
            }
            const pre = document.createElement('pre');
            const lines = (result.content || '').split('\n');
            lines.forEach((line, index) => {
              const row = document.createElement('div'); row.className = 'file-line';
              if (index + 1 === file.line) row.classList.add('focused');
              const number = document.createElement('span'); number.textContent = index + 1;
              row.append(number, document.createTextNode(line)); pre.append(row);
            });
            $('file-content').replaceChildren(back, pre);
            $('file-content').querySelector('.focused')?.scrollIntoView({ block:'center' });
          } catch(error) { $('file-content').textContent = error.message; }
        }

        async function loadChanges(id) {
          let files;
          try { files = await api(`/api/workspaces/${encodeURIComponent(id)}/changes`); }
          catch(error) {
            if (workspace === id) {
              $('inspector').classList.add('open'); $('file-title').textContent = 'Changes';
              $('file-content').textContent = 'Bloom could not read changes for this workspace.';
            }
            return;
          }
          if (workspace !== id) return;
          $('inspector').classList.add('open'); $('file-title').textContent = `Changes (${files.length})`;
          const list = document.createElement('div'); list.className = 'changes-list';
          if (!files.length) list.textContent = 'No changes in this workspace.';
          for (const file of files) {
            const button = document.createElement('button'); button.type = 'button'; button.className = 'change-file';
            const status = document.createElement('span'); status.textContent = file.change;
            const name = document.createElement('span'); name.textContent = file.path; name.title = file.path;
            const count = document.createElement('small'); count.textContent = `+${file.additions} −${file.deletions}`;
            button.append(status, name, count); button.addEventListener('click', () => openFile({path:file.path,line:1}));
            list.append(button);
          }
          $('file-content').replaceChildren(list);
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

        function addChips(element, labels, files = []) {
          if (!labels?.length) return;
          const chips = document.createElement('span'); chips.className = 'chip-list';
          for (const label of labels) {
            const file = workspace && files.find(item => item.label === label);
            const chip = document.createElement(file ? 'button' : 'span'); chip.className = 'chip';
            chip.textContent = label; chips.append(chip);
            if (file) { chip.type = 'button'; chip.addEventListener('click', () => openFile(file)); }
          }
          element.append(chips);
        }

        function appendMessage(row, temporary = false) {
          const key = `${row.seq}:${row.kind}`;
          if (!temporary && shown.has(key)) return;
          if (!temporary) shown.add(key);
          if (row.kind === 'turnEnd') return;
          if (row.kind === 'toolResult') { addResult(row); return; }
          const element = document.createElement('article'); element.className = `entry ${row.kind}`;
          if (temporary) element.id = 'streaming';
          if (row.parentToolUseID) element.classList.add('nested');
          if (['user', 'assistant', 'crew', 'plan'].includes(row.kind)) {
            if (row.kind === 'crew' || row.kind === 'plan') {
              const title = document.createElement('div'); title.className = 'card-title';
              title.textContent = row.title; element.append(title);
            }
            element.append(prose(row)); addChips(element, row.chips, row.files);
          } else if (row.kind === 'tool') {
            element.dataset.tint = row.tint;
            const details = document.createElement('details'); const summary = document.createElement('summary');
            summary.setAttribute('role', 'button');
            summary.setAttribute('aria-label', `${row.title} ${row.detail}`.trim());
            summary.append(activity(row, toolGlyph(row)));
            const output = document.createElement('div'); output.className = 'tool-output';
            output.textContent = 'Waiting for result';
            details.append(summary, output); element.append(details); addChips(element, row.chips, row.files);
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
            note.textContent = row.kind === 'permission' ? (row.canAnswer ? '' : 'Answer this in Bloom on the host Mac.') : row.detail;
            element.append(title, body, note); if (row.requestID) permissions.set(row.requestID, note);
            if (row.kind === 'permission' && row.canAnswer && row.requestID) {
              const actions = document.createElement('div'); actions.className = 'permission-actions';
              for (const [label, decision] of [['Allow once','allow_once'], ['Deny','deny']]) {
                const button = document.createElement('button'); button.type = 'button'; button.textContent = label;
                if (decision === 'allow_once') button.className = 'primary';
                button.addEventListener('click', async () => {
                  actions.querySelectorAll('button').forEach(item => item.disabled = true);
                  try {
                    await api(`/api/chats/${encodeURIComponent(chat)}/permissions/${encodeURIComponent(row.requestID)}`, {
                      method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({decision})
                    });
                    note.textContent = decision === 'allow_once' ? 'Allowed once' : 'Denied';
                    actions.remove();
                  } catch(error) {
                    showError(error); actions.querySelectorAll('button').forEach(item => item.disabled = false);
                  }
                });
                actions.append(button);
              }
              element.append(actions);
            }
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
            if (note) {
              note.textContent = `Answered: ${decision}`;
              note.parentElement.querySelector('.permission-actions')?.remove();
            }
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
            $('status').textContent = ''; $('status').style.color = '';
          } finally { fetching = false; }
        }

        let createKind = null, createProject = null;
        function showCreate(kind, project = null) {
          createKind = kind; createProject = project;
          const titles = { project:'New project', addProject:'Add existing project', workspace:`New workspace in ${project?.name || ''}`, chat:'New chat' };
          $('create-title').textContent = titles[kind]; $('create-error').textContent = '';
          const fields = $('create-fields'); fields.replaceChildren();
          function field(name, title, placeholder, multiline = false) {
            const label = document.createElement('label'); label.textContent = title;
            const input = document.createElement(multiline ? 'textarea' : 'input');
            input.name = name; input.placeholder = placeholder;
            input.required = name === 'path' || name === 'location' || name === 'name' && kind === 'project' || name === 'prompt';
            label.append(input); fields.append(label);
          }
          if (kind === 'project') { field('name', 'Project name', 'my-project'); field('location', 'Parent folder', '~/Developer'); }
          if (kind === 'addProject') field('path', 'Git repository folder', '~/Developer/my-project');
          if (kind === 'workspace') {
            field('name', 'Workspace name (optional)', 'Describe the task');
            field('baseBranch', 'Base branch (optional)', project.branch);
            field('prompt', 'What should the agent do?', 'Describe the work to do', true);
          }
          if (kind === 'chat') field('title', 'Chat title (optional)', 'New chat');
          $('confirm-create').textContent = kind === 'addProject' ? 'Add project' : 'Create';
          $('create-dialog').showModal(); fields.querySelector('input,textarea')?.focus();
        }

        $('new-project').addEventListener('click', () => showCreate('project'));
        $('mobile-sidebar').addEventListener('click', () => {
          const open = $('sidebar').classList.toggle('expanded');
          $('mobile-sidebar').setAttribute('aria-expanded', String(open));
        });
        $('add-project').addEventListener('click', () => showCreate('addProject'));
        $('new-chat').addEventListener('click', () => { if (workspace) showCreate('chat'); });
        $('new-conversation').addEventListener('click', async () => {
          try {
            const entry = await api('/api/conversations', { method:'POST', headers:{'Content-Type':'application/json'}, body:'{}' });
            await loadWorkspaces(); await selectConversation(entry);
          } catch(error) { showError(error); }
        });
        $('cancel-create').addEventListener('click', () => $('create-dialog').close());
        $('close-file').addEventListener('click', () => $('inspector').classList.remove('open'));
        $('create-form').addEventListener('submit', async event => {
          event.preventDefault();
          const values = Object.fromEntries(new FormData(event.currentTarget));
          let path, body;
          if (createKind === 'project') { path = '/api/projects'; body = { name:values.name, location:values.location }; }
          else if (createKind === 'addProject') { path = '/api/projects'; body = { path:values.path }; }
          else { path = createKind === 'workspace' ? '/api/workspaces' : `/api/workspaces/${encodeURIComponent(workspace)}/chats`;
            body = createKind === 'workspace' ? { project:createProject.path, name:values.name, baseBranch:values.baseBranch, prompt:values.prompt } : { title:values.title }; }
          $('confirm-create').disabled = true; $('create-error').textContent = '';
          try {
            const targetWorkspace = workspace;
            const made = await api(path, { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) });
            $('create-dialog').close(); await loadWorkspaces();
            if (createKind === 'workspace') {
              const row = workspaceRows.find(item => item.id === made.workspace_id);
              if (row) await selectWorkspace(row);
            } else if (createKind === 'chat') {
              const row = workspaceRows.find(item => item.id === targetWorkspace);
              if (row) { await selectWorkspace(row); await selectChat({ id:made.chat_id, title:made.title, agent:made.agent, model:made.model, effort:made.effort, state:'idle' }); }
            }
          } catch(error) { $('create-error').textContent = error.message; }
          finally { $('confirm-create').disabled = false; }
        });

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
