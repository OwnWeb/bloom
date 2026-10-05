import Foundation

/// Browser behaviour stays separate from the HTML and theme. Provider payloads never enter here;
/// this script renders the versioned rows the host has already interpreted.
enum LocalWebClientScript {
    static let javascript = #"""
        const $ = id => document.getElementById(id);
        let token = sessionStorage.getItem('bloom-access') || '';
        let workspace = null, chat = null, lastSeq = null, earliestSeq = null, poll = null, fetching = false;
        let projectRows = [], workspaceRows = [];
        const shown = new Set(), tools = new Map(), permissions = new Map(), messageHistory = new Map();
        const drafts = new Map(JSON.parse(sessionStorage.getItem('bloom-drafts') || '[]'));
        const uploadsByChat = new Map(
          JSON.parse(sessionStorage.getItem('bloom-uploads') || '[]').map(([id, entries]) => [id, new Map(entries)])
        );
        let uploading = 0;

        function saveComposer() {
          sessionStorage.setItem('bloom-drafts', JSON.stringify([...drafts]));
          sessionStorage.setItem('bloom-uploads', JSON.stringify(
            [...uploadsByChat].map(([id, entries]) => [id, [...entries]])
          ));
        }

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

        function rememberDraft() {
          if (chat) { drafts.set(chat, $('prompt').value); saveComposer(); }
        }

        function renderUploads() {
          const container = $('uploads'); container.replaceChildren();
          for (const upload of uploadsByChat.get(chat)?.values() || []) {
            const chip = document.createElement('span'); chip.className = 'upload-chip';
            const label = document.createElement('span'); label.textContent = upload.name;
            const remove = document.createElement('button'); remove.type = 'button';
            remove.title = `Remove ${upload.name}`; remove.textContent = '×';
            remove.addEventListener('click', () => removeUpload(upload));
            chip.append(label, remove); container.append(chip);
          }
        }

        function insertUpload(token, at) {
          const field = $('prompt'); const current = field.value;
          const offset = Math.min(at, current.length);
          const before = current.slice(0, offset), after = current.slice(offset);
          const lead = before && !/\s$/.test(before) ? ' ' : '';
          const trail = after && /^\s/.test(after) ? '' : ' ';
          field.value = before + lead + token + trail + after;
          field.selectionStart = field.selectionEnd = offset + lead.length + token.length + trail.length;
          drafts.set(chat, field.value); saveComposer(); field.focus();
          return field.selectionStart;
        }

        async function uploadFiles(files) {
          if (!chat || !files.length) return;
          const current = chat; let offset = $('prompt').selectionStart;
          uploading += 1; $('send').disabled = true; $('attach-file').disabled = true;
          $('hint').textContent = 'Attaching files…';
          try {
            for (const file of files) {
              if (file.size > 25 * 1024 * 1024) throw Error(`${file.name} is over the 25 MB browser limit.`);
              const added = await api(`/api/chats/${encodeURIComponent(current)}/attachments`, {
                method:'POST', headers:{ 'Content-Type':'application/octet-stream',
                  'X-Bloom-Filename':encodeURIComponent(file.name || 'attachment') }, body:file
              });
              let held = uploadsByChat.get(current);
              if (!held) { held = new Map(); uploadsByChat.set(current, held); }
              held.set(added.path, added);
              if (chat === current) { offset = insertUpload(added.token, offset); renderUploads(); }
              else { drafts.set(current, `${drafts.get(current) || ''} ${added.token}`.trim()); saveComposer(); }
            }
          } catch(error) { showError(error); }
          finally {
            uploading -= 1; $('hint').textContent = '';
            $('attach-file').disabled = !chat || uploading > 0;
            $('send').disabled = !chat || uploading > 0;
          }
        }

        async function removeUpload(upload) {
          if (!chat) return;
          const current = chat;
          try {
            await api(`/api/chats/${encodeURIComponent(current)}/attachments/remove`, {
              method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({path:upload.path})
            });
            uploadsByChat.get(current)?.delete(upload.path);
            if (chat === current) {
              $('prompt').value = $('prompt').value.split(upload.token).join('');
              drafts.set(current, $('prompt').value); renderUploads();
            }
            saveComposer();
          } catch(error) { showError(error); }
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
          rememberDraft();
          workspace = row.id; chat = null; lastSeq = null; earliestSeq = null;
          collapseSidebar();
          $('inspector').classList.remove('requested'); $('toggle-inspector').hidden = false;
          sessionStorage.setItem('bloom-workspace', row.id); sessionStorage.removeItem('bloom-conversation');
          $('new-chat').hidden = false;
          shown.clear(); tools.clear(); permissions.clear(); messageHistory.clear(); clearInterval(poll); poll = null;
          $('title').textContent = row.name; $('subtitle').textContent = `${row.project} · ${row.branch}`;
          $('messages').replaceChildren(); $('prompt').disabled = true; $('send').disabled = true;
          $('attach-file').disabled = true; $('uploads').replaceChildren();
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
          rememberDraft();
          workspace = null; chat = null; lastSeq = null; earliestSeq = null;
          collapseSidebar();
          sessionStorage.setItem('bloom-conversation', entry.id); sessionStorage.removeItem('bloom-workspace');
          $('new-chat').hidden = true;
          shown.clear(); tools.clear(); permissions.clear(); messageHistory.clear(); clearInterval(poll); poll = null;
          $('chats').replaceChildren();
          $('chats').hidden = true;
          $('inspector').classList.remove('open', 'requested'); $('toggle-inspector').hidden = true;
          document.querySelectorAll('.workspace').forEach(button => button.classList.remove('selected'));
          document.querySelectorAll('.conversation').forEach(button => {
            button.classList.toggle('selected', button.dataset.conversation === entry.id);
          });
          await selectChat(entry);
        }

        async function selectChat(entry) {
          rememberDraft();
          chat = entry.id; lastSeq = null; earliestSeq = null;
          if (workspace) sessionStorage.setItem('bloom-chat', entry.id);
          shown.clear(); tools.clear(); permissions.clear(); messageHistory.clear(); clearInterval(poll);
          $('title').textContent = entry.title; $('subtitle').textContent = `${entry.agent} · ${entry.state}`;
          $('messages').replaceChildren(earlierButton()); $('prompt').disabled = false;
          $('prompt').value = drafts.get(entry.id) || '';
          $('send').disabled = uploading > 0; $('attach-file').disabled = uploading > 0;
          renderUploads();
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
          if (chat && row.files?.length) {
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
          if (!chat) return;
          $('inspector').classList.add('open', 'requested'); $('file-title').textContent = file.path;
          $('file-content').textContent = 'Loading file…';
          try {
            const result = await api(`/api/chats/${encodeURIComponent(chat)}/files?path=${encodeURIComponent(file.path)}`);
            const back = document.createElement('button'); back.className = 'back-to-changes';
            back.type = 'button'; back.textContent = workspace ? '‹ Changes' : '‹ Close file';
            back.addEventListener('click', () => workspace
              ? loadChanges(workspace).catch(showError)
              : $('inspector').classList.remove('open', 'requested'));
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
          if (!files.length) {
            const empty = document.createElement('div'); empty.className = 'inspector-empty';
            const icon = document.createElement('span'); icon.className = 'inspector-empty-icon';
            icon.setAttribute('aria-hidden', 'true'); icon.textContent = '✓';
            const title = document.createElement('strong'); title.textContent = 'No changes yet';
            const detail = document.createElement('span');
            detail.textContent = 'Nothing in this workspace differs from its base branch.';
            empty.append(icon, title, detail); $('file-content').replaceChildren(empty);
            return;
          }
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
            const file = chat && files.find(item => item.label === label);
            const chip = document.createElement(file ? 'button' : 'span'); chip.className = 'chip';
            chip.textContent = label; chips.append(chip);
            if (file) { chip.type = 'button'; chip.addEventListener('click', () => openFile(file)); }
          }
          element.append(chips);
        }

        async function answerPermission(row, payload, actions, note, outcome) {
          actions.querySelectorAll('button,input').forEach(item => item.disabled = true);
          try {
            await api(`/api/chats/${encodeURIComponent(chat)}/permissions/${encodeURIComponent(row.requestID)}`, {
              method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(payload)
            });
            note.textContent = outcome; actions.remove();
          } catch(error) {
            showError(error);
            actions.querySelectorAll('button,input').forEach(item => item.disabled = false);
          }
        }

        function questionForm(row, note) {
          const form = document.createElement('form'); form.className = 'question-form';
          for (const [index, question] of row.questions.entries()) {
            const group = document.createElement('fieldset'); group.dataset.question = question.answerKey;
            const heading = document.createElement('legend');
            if (question.header) {
              const header = document.createElement('span'); header.className = 'question-header';
              header.textContent = question.header; heading.append(header);
            }
            const questionText = document.createElement('span'); questionText.textContent = question.text;
            heading.append(questionText);
            group.append(heading);
            if (question.multiSelect) {
              const hint = document.createElement('small'); hint.className = 'question-hint';
              hint.textContent = 'Choose as many as apply.'; group.append(hint);
            }
            for (const option of question.options) {
              const label = document.createElement('label'); label.className = 'question-option';
              const input = document.createElement('input'); input.className = 'option-input';
              input.type = question.multiSelect ? 'checkbox' : 'radio';
              input.name = `question-${row.seq}-${index}`; input.value = option.label;
              const words = document.createElement('span'); words.textContent = option.label;
              if (option.detail) {
                const detail = document.createElement('small'); detail.textContent = option.detail; words.append(detail);
              }
              input.addEventListener('change', () => {
                const other = group.querySelector('.other-answer'); if (other) other.value = '';
                updateSend();
              });
              label.append(input, words); group.append(label);
              if (option.preview) {
                const preview = document.createElement('pre'); preview.textContent = option.preview; group.append(preview);
              }
            }
            if (question.allowsOther || !question.options.length) {
              const label = document.createElement('label'); label.className = 'question-other';
              label.textContent = question.options.length ? 'Other answer' : 'Your answer';
              const input = document.createElement('input'); input.className = 'other-answer';
              input.type = question.isSecret ? 'password' : 'text';
              input.autocomplete = 'off';
              input.addEventListener('input', () => {
                if (input.value.trim()) group.querySelectorAll('.option-input').forEach(choice => choice.checked = false);
                updateSend();
              });
              label.append(input); group.append(label);
            }
            form.append(group);
          }
          const send = document.createElement('button'); send.className = 'primary';
          send.textContent = 'Send answer'; send.disabled = true; form.append(send);
          function updateSend() {
            send.disabled = !Array.from(form.querySelectorAll('fieldset')).every(group =>
              !!group.querySelector('.option-input:checked') || !!group.querySelector('.other-answer')?.value.trim()
            );
          }
          form.addEventListener('submit', event => {
            event.preventDefault();
            const choices = {}, other = {};
            for (const [index, question] of row.questions.entries()) {
              const group = form.querySelectorAll('fieldset')[index];
              choices[question.answerKey] = Array.from(group.querySelectorAll('.option-input:checked')).map(item => item.value);
              other[question.answerKey] = group.querySelector('.other-answer')?.value || '';
            }
            answerPermission(row, {decision:'answer', choices, other}, form, note, 'Answered');
          });
          return form;
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
            const body = document.createElement('div'); body.textContent = row.questions?.length ? '' : row.text;
            const note = document.createElement('div'); note.className = 'card-note';
            note.textContent = row.kind === 'permission' ? (row.canAnswer ? '' : 'Answer this in Bloom on the host Mac.') : row.detail;
            element.append(title, body, note); if (row.requestID) permissions.set(row.requestID, note);
            if (row.kind === 'permission' && row.canAnswer && row.requestID) {
              if (row.questions?.length) {
                element.append(questionForm(row, note));
              } else {
                const actions = document.createElement('div'); actions.className = 'permission-actions';
                const options = row.planMode
                  ? [['Approve and implement','approve_plan','Approved'], ['Keep planning','keep_planning','Still planning']]
                  : [['Allow once','allow_once','Allowed once'], ['Deny','deny','Denied']];
                if (row.planMode) note.textContent = `Implementation permissions: ${row.planMode}`;
                for (const [label, decision, outcome] of options) {
                  const button = document.createElement('button'); button.type = 'button'; button.textContent = label;
                  if (decision === 'allow_once' || decision === 'approve_plan') button.className = 'primary';
                  button.addEventListener('click', () => answerPermission(
                    row, {decision, mode:row.planMode}, actions, note, outcome
                  ));
                  actions.append(button);
                }
                element.append(actions);
              }
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
              note.parentElement.querySelector('.question-form')?.remove();
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
            data.messages.forEach(row => messageHistory.set(row.seq, row));
            earliestSeq = data.firstSeq; button.hidden = !data.hasMoreEarlier;
            shown.clear(); tools.clear(); permissions.clear();
            pane.replaceChildren(button);
            Array.from(messageHistory.values()).sort((a, b) => a.seq - b.seq).forEach(row => appendMessage(row));
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
            data.messages.forEach(row => { messageHistory.set(row.seq, row); appendMessage(row); });
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
        $('attach-file').addEventListener('click', () => $('file-picker').click());
        $('file-picker').addEventListener('change', event => {
          uploadFiles(Array.from(event.target.files || [])); event.target.value = '';
        });
        $('prompt').addEventListener('input', () => rememberDraft());
        $('prompt').addEventListener('drop', event => {
          if (!event.dataTransfer?.files.length) return;
          event.preventDefault(); uploadFiles(Array.from(event.dataTransfer.files));
        });
        $('prompt').addEventListener('paste', event => {
          if (!event.clipboardData?.files.length) return;
          event.preventDefault(); uploadFiles(Array.from(event.clipboardData.files));
        });
        $('toggle-inspector').addEventListener('click', () => {
          const inspector = $('inspector');
          if (inspector.classList.contains('requested') || window.innerWidth > 700 && inspector.classList.contains('open')) {
            inspector.classList.remove('open', 'requested');
          } else { inspector.classList.add('open', 'requested'); }
        });
        $('new-conversation').addEventListener('click', async () => {
          try {
            const entry = await api('/api/conversations', { method:'POST', headers:{'Content-Type':'application/json'}, body:'{}' });
            await loadWorkspaces(); await selectConversation(entry);
          } catch(error) { showError(error); }
        });
        $('cancel-create').addEventListener('click', () => $('create-dialog').close());
        $('close-file').addEventListener('click', () => $('inspector').classList.remove('open', 'requested'));
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
          event.preventDefault(); const text = $('prompt').value.trim(); if (!chat || !text || uploading) return;
          const current = chat;
          $('send').disabled = true;
          try {
            await api(`/api/chats/${encodeURIComponent(current)}/messages`, {
              method:'POST', headers:{ 'Content-Type':'application/json' }, body:JSON.stringify({ text })
            });
            for (const [path, upload] of uploadsByChat.get(current) || []) {
              if (text.includes(upload.token)) uploadsByChat.get(current).delete(path);
            }
            drafts.set(current, ''); saveComposer();
            if (chat === current) { $('prompt').value = ''; renderUploads(); await refresh(); }
          } catch(error) { showError(error); } finally { $('send').disabled = uploading > 0; }
        });

        $('login-form').addEventListener('submit', async event => {
          event.preventDefault(); token = $('code').value.trim(); $('login-error').textContent = '';
          try { await loadWorkspaces(); sessionStorage.setItem('bloom-access', token); $('login').hidden = true; }
          catch(error) { $('login-error').textContent = error.message; }
        });

        const connectTicket = new URLSearchParams(window.location.hash.slice(1)).get('connect');
        if (connectTicket) {
          window.history.replaceState(null, '', window.location.pathname + window.location.search);
          fetch('/api/connect', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body:JSON.stringify({ticket:connectTicket}), cache:'no-store'
          }).then(async response => {
            if (!response.ok) throw Error(await response.text());
            return response.json();
          }).then(async result => {
            token = result.token;
            sessionStorage.setItem('bloom-access', token);
            await loadWorkspaces(); $('login').hidden = true;
          }).catch(error => { $('login-error').textContent = error.message; });
        } else if (token) loadWorkspaces().then(() => { $('login').hidden = true; })
          .catch(error => { $('login-error').textContent = error.message; });
        """#
}
