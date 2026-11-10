// The page only displays instructions and status; it never starts installation.
const prefix = document.body.dataset.session;
const version = document.body.dataset.version;
const params = new URLSearchParams(location.search);
let language = params.get('lang') === 'en' ? 'en' : params.get('lang') === 'zh' ? 'zh' : navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
let translations, copied = false, current = { stage: 'waiting', user: '' };
const icons = {
 copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V4H4v12h4"/>',
 check: '<path d="m5 12 4 4L19 6"/>',
 wait: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
 spinner: '<path d="M21 12a9 9 0 1 1-6.2-8.55"/>',
 success: '<circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/>',
 error: '<circle cx="12" cy="12" r="9"/><path d="M12 7v6m0 4h.01"/>',
 offline: '<path d="M4 4l16 16M2 8a16 16 0 0 1 20 0M5 12a11 11 0 0 1 14 0m-11 4a6 6 0 0 1 8 0M12 20h.01"/>'
};
const icon = (name, cls = '') => `<svg class="${cls}" viewBox="0 0 24 24" aria-hidden="true">${icons[name]}</svg>`;
const stageKey = stage => ({ waiting: 'ready', checking: 'running', installing: 'running', configuring: 'running', ready: 'verifying', 'ready-final': 'verifying', complete: 'success', failed: 'error', cancelled: 'ready', offline: 'offline' }[stage] || 'ready');
function command() { return `irm ${location.origin}${prefix}/setup.ps1?lang=${language} | iex`; }
function escapeHTML(value) { return value.replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character])); }
function render() {
 const t = translations[language], status = t.statuses[stageKey(current.stage)], shots = t.shots;
 document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
 document.title = t.title + ' · LAN SSH';
 document.getElementById('notice').textContent = t.setupNote;
 const ready = ['ready','ready-final','complete'].includes(current.stage);
 document.getElementById('app').innerHTML = `
 <header class="page-header"><div class="brand">LAN SSH</div><div class="header-tools"><div class="connection"><i class="dot ${current.stage==='offline'?'offline':''}"></i>${current.stage==='offline'?t.macOffline:t.connection}</div><div class="language-switch" role="group" aria-label="${t.language}"><button data-lang="zh" lang="zh-CN" aria-pressed="${language==='zh'}">中文</button><button data-lang="en" lang="en" aria-pressed="${language==='en'}">English</button></div></div></header>
 <main class="layout checklist-page"><div class="checklist-intro"><h1>${t.title}</h1><p class="lead">${t.subtitle}</p></div>
 <ol class="steps">
 <li class="step"><span class="step-number ${ready?'done':''}">${ready?icon('check'):'01'}</span><div><h3>${t.openTitle}</h3><p>${t.startIntro}</p><div class="start-guide ${shots.images.length===1?'single':''}">${shots.images.map(image=>`<figure><figcaption>${image.caption}</figcaption><a href="${image.src}" target="_blank" rel="noopener" aria-label="${image.caption}"><img src="${image.src}" alt="${image.alt}"></a></figure>`).join('')}</div><p class="screenshot-note">${t.figureNote}<br>${t.permission}</p><small class="screenshot-source">${t.sourceLabel}: <a href="${shots.source}" target="_blank" rel="noopener">${shots.author}</a> · <a href="${shots.licenseURL}" target="_blank" rel="noopener">${shots.license}</a> · ${t.versionNote}</small></div></li>
 <li class="step"><span class="step-number ${ready?'done':''}">${ready?icon('check'):'02'}</span><div><h3>${t.copyTitle}</h3><div class="command"><code>${escapeHTML(command())}</code><button class="primary ${copied?'copied':''}" id="copy-command">${icon(copied?'check':'copy')} ${copied?t.copied:t.copy}</button></div><p class="copy-note" aria-live="polite">${copied?t.copyNote:' '}</p><p class="hint">${t.hint} <span class="keycap">Enter ↵</span>${t.hintEnd}</p></div></li>
 <li class="step"><span class="step-number ${current.stage==='complete'?'done':''}">${current.stage==='complete'?icon('check'):'03'}</span><div class="status ${stageKey(current.stage)}" role="status"><div class="status-icon">${icon(status.icon,status.icon==='spinner'?'spin':'')}</div><div><h3>${status.title}</h3><p>${current.stage==='cancelled'?t.cancelled:current.stage==='ready-final'?t.lockdown:status.body}</p>${current.user?`<p class="account">${t.accountLabel}: ${escapeHTML(current.user)}</p>`:''}</div></div></li>
 </ol><div class="meta"><span>Windows 10 / 11 · x64</span><span>${t.sameLAN}</span></div><p class="caption">${t.versionLabel}: ${version}</p><p class="footer-line">${t.footer}</p></main>`;
 document.querySelectorAll('[data-lang]').forEach(button => button.onclick = () => {
  if (language !== button.dataset.lang) { language = button.dataset.lang; copied = false; render(); }
 });
 document.getElementById('copy-command').onclick = copyCommand;
 history.replaceState(null, '', `${location.pathname}?lang=${language}`);
}
async function copyCommand() {
 const t = translations[language];
 let didCopy = false;
 if (window.isSecureContext && navigator.clipboard) {
  try { await navigator.clipboard.writeText(command()); didCopy = true; } catch {}
 }
 if (!didCopy) {
  // Clipboard API requires HTTPS; local HTTP onboarding still needs one-click copy.
  const temporary = document.createElement('textarea'); temporary.value = command();
  temporary.setAttribute('readonly', ''); temporary.style.position = 'fixed'; temporary.style.opacity = '0';
  document.body.append(temporary); temporary.focus(); temporary.select();
  try { didCopy = document.execCommand('copy'); } catch {} finally { temporary.remove(); }
 }
 if (didCopy) { copied = true; render(); return; }
 {
  const overlay = document.createElement('div'); overlay.className = 'manual-copy';
  overlay.innerHTML = `<section class="manual-dialog" role="dialog" aria-modal="true" aria-labelledby="manual-title"><h3 id="manual-title">${t.manualTitle}</h3><p>${t.manualBody}</p><textarea readonly aria-label="${t.manualCommand}"></textarea><button class="primary">${t.manualDone}</button></section>`;
  document.body.append(overlay); const text = overlay.querySelector('textarea'); text.value = command(); text.focus(); text.select();
  overlay.querySelector('button').onclick = () => { overlay.remove(); copied = true; render(); };
 }
}
async function poll() {
 try {
  const response = await fetch(prefix + '/status', { cache: 'no-store' });
  if (!response.ok) throw new Error('status');
  const next = await response.json();
  if (next.stage !== current.stage || next.user !== current.user) { current = next; render(); }
 } catch { if (current.stage !== 'offline') { current = { stage: 'offline', user: '' }; render(); } }
 if (current.stage !== 'complete') setTimeout(poll, 2000);
}
fetch('/i18n.json', { cache: 'no-store' }).then(response => { if (!response.ok) throw new Error('translations'); return response.json(); }).then(data => { translations = data; render(); poll(); }).catch(() => {
 document.getElementById('notice').textContent = '无法载入引导，请确认 Mac 服务仍在运行后刷新。 / Could not load instructions. Check that the Mac service is running, then reload.';
});
