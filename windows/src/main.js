const { invoke, Channel } = window.__TAURI__.core;
const { open } = window.__TAURI__.dialog;
const { revealItemInDir, openPath } = window.__TAURI__.opener;
const $ = (id) => document.getElementById(id);

const store = {
  get: (k, d) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch {} },
};

const s = {
  phase: 'idle',            // idle | fetching | ready | downloading | done
  info: null, downloadUrl: null, isLiveNow: false, liveEdge: null,
  mode: 'entire', outputDir: '', cookies: store.get('cookies', ''),
  progress: null, file: null, log: [], tools: null,
};

// ---------- time helpers (same rules as the Mac app) ----------
function parseTime(text) {
  const t = text.trim();
  if (!t) return null;
  const parts = t.split(':');
  if (parts.length > 3 || parts.some((p) => !/^\d+(\.\d+)?$|^\.\d+$/.test(p))) return null;
  const v = parts.map(Number);
  if (v.slice(1).some((x) => x >= 60)) return null;
  return v.reduce((a, x) => a * 60 + x, 0);
}
function fmt(sec) {
  const t = Math.max(0, Math.round(sec));
  const p = (n) => String(n).padStart(2, '0');
  return `${p(Math.floor(t / 3600))}:${p(Math.floor((t % 3600) / 60))}:${p(t % 60)}`;
}
const bytes = (n) => n >= 1e9 ? (n / 1e9).toFixed(1) + ' GB' : n >= 1e6 ? (n / 1e6).toFixed(1) + ' MB' : Math.round(n / 1e3) + ' KB';

// ---------- rendering ----------
function showError(msg, warn = false) {
  const b = $('banner');
  b.textContent = msg || '';
  b.classList.toggle('warn', warn);
  b.hidden = !msg;
}

function render() {
  const hasVideo = !!s.info;
  $('empty').hidden = hasVideo || s.phase === 'fetching';
  $('video').hidden = !hasVideo;
  $('options').hidden = !hasVideo;
  $('clear').hidden = !$('url').value;
  $('fetch').disabled = !$('url').value.trim() || s.phase === 'fetching' || s.phase === 'downloading' || !s.tools?.ytdlp;
  $('fetch').textContent = s.phase === 'fetching' ? 'Looking up…' : 'Fetch';

  if (hasVideo) {
    $('title').textContent = s.info.title || 'Untitled';
    $('uploader').textContent = s.info.uploader || '';
    $('length').textContent = s.isLiveNow ? `${fmt(s.info.duration || 0)} recorded so far` : fmt(s.info.duration || 0);
    $('thumb').src = s.info.thumbnail || '';
    $('live-badge').hidden = !s.isLiveNow;
  }

  document.querySelectorAll('#modes button').forEach((b) => {
    b.setAttribute('aria-checked', String(b.dataset.mode === s.mode));
    if (b.dataset.mode === 'startNow') b.disabled = !s.isLiveNow;
  });
  $('range-row').hidden = s.mode !== 'range';
  updateRangeNote();

  const busy = s.phase === 'downloading' || s.phase === 'fetching';
  document.querySelectorAll('#options button, #options input, #options select, #url, #paste').forEach((el) => (el.disabled = busy || (el.dataset?.mode === 'startNow' && !s.isLiveNow)));

  $('folder').textContent = s.outputDir;
  $('folder').title = s.outputDir;
  $('cookies').textContent = s.cookies || 'None';
  $('clear-cookies').hidden = !s.cookies;

  $('bar-idle').hidden = s.phase === 'downloading' || s.phase === 'done';
  $('bar-busy').hidden = s.phase !== 'downloading';
  $('bar-done').hidden = s.phase !== 'done';
  $('download').disabled = !(hasVideo && (s.phase === 'ready'));
  $('summary').textContent = !hasVideo ? 'Paste a link to begin'
    : s.mode === 'entire' ? 'Whole video' : s.mode === 'startNow' ? 'From the start until now' : 'Selected range';

  if (s.phase === 'downloading') {
    const p = s.progress;
    const prog = $('progress');
    if (p?.fraction != null) prog.value = p.fraction; else prog.removeAttribute('value');
    const parts = [];
    if (p?.fraction != null) parts.push(`${Math.floor(p.fraction * 100)}%`);
    if (p?.downloaded_bytes != null) parts.push(bytes(p.downloaded_bytes));
    if (p?.speed != null) parts.push(bytes(p.speed) + '/s');
    if (p?.eta != null) parts.push(fmt(p.eta) + ' left');
    $('progress-text').textContent = p ? (parts.join(' · ') || 'Working…') : 'Starting…';
  }
  if (s.phase === 'done') $('saved-name').textContent = s.file ? s.file.split(/[\\/]/).pop() : s.outputDir;

  $('log-wrap').hidden = s.log.length === 0;
  $('log').textContent = s.log.join('\n');
}

function updateRangeNote() {
  const note = $('range-note');
  note.hidden = true;
  note.classList.remove('warn');
  if (s.mode === 'range') {
    const a = parseTime($('start').value), b = $('end').value.trim() ? parseTime($('end').value) : null;
    $('start').classList.toggle('bad', a === null && $('start').value.trim() !== '');
    $('end').classList.toggle('bad', $('end').value.trim() !== '' && b === null);
    const end = b ?? s.info?.duration;
    $('range-len').textContent = a !== null && end != null && end > a ? `${fmt(end - a)} long` : '';
    if (s.isLiveNow) {
      note.hidden = false; note.classList.add('warn');
      note.textContent = 'Ranges from a live stream download in real time, so they take a while. "Start → now" is much faster.';
    }
  } else if (s.mode === 'startNow') {
    note.hidden = false;
    note.textContent = 'Saves the recording from the start of the stream until the moment you click Download.';
  }
}

// ---------- actions ----------
async function fetchLink() {
  const url = $('url').value.trim();
  if (!url) return;
  showError('');
  s.phase = 'fetching'; s.info = null; s.downloadUrl = null; s.isLiveNow = false; s.progress = null; render();
  try {
    const r = await invoke('fetch_video', { url, cookies: s.cookies });
    s.info = r.info; s.downloadUrl = r.downloadUrl; s.isLiveNow = r.isLiveNow; s.liveEdge = r.liveEdge;
    s.mode = r.isLiveNow ? 'startNow' : (s.mode === 'startNow' ? 'entire' : s.mode);
    s.phase = 'ready';
  } catch (e) {
    s.phase = 'idle';
    showError(String(e));
  }
  render();
}

async function download() {
  showError('');
  s.phase = 'downloading'; s.progress = null; s.log = []; s.file = null; render();
  const channel = new Channel();
  channel.onmessage = ({ event, data }) => {
    switch (event) {
      case 'length': s.info.duration = data.seconds; s.liveEdge = data.seconds; $('length').textContent = `${fmt(data.seconds)} recorded so far`; break;
      case 'progress': s.progress = data; break;
      case 'log': s.log.push(data.line); if (s.log.length > 200) s.log.shift(); break;
      case 'done': s.phase = 'done'; s.file = data.file; if (s.progress) s.progress.fraction = 1; break;
      case 'failed': s.phase = 'ready'; showError(data.message); break;
      case 'cancelled': s.phase = 'ready'; s.log.push('Cancelled.'); break;
    }
    render();
  };
  try {
    await invoke('start_download', {
      params: {
        downloadUrl: s.downloadUrl, mode: s.mode,
        startText: $('start').value, endText: $('end').value,
        quality: $('quality').value, accurateCuts: $('accurate').checked,
        outputDir: s.outputDir, cookies: s.cookies,
        isLiveNow: s.isLiveNow, liveEdge: s.liveEdge, duration: s.info?.duration ?? null,
      },
      onEvent: channel,
    });
  } catch (e) {
    s.phase = 'ready'; showError(String(e)); render();
  }
}

async function chooseFolder() {
  const dir = await open({ directory: true, defaultPath: s.outputDir, title: 'Choose where to save videos' });
  if (dir) { s.outputDir = dir; store.set('outputDir', dir); render(); }
}
async function chooseCookies() {
  const f = await open({ multiple: false, filters: [{ name: 'Cookies', extensions: ['txt'] }], title: 'Choose a cookies.txt file' });
  if (f) { s.cookies = f; store.set('cookies', f); render(); }
}

// ---------- wiring ----------
$('url').addEventListener('input', render);
$('url').addEventListener('keydown', (e) => { if (e.key === 'Enter') fetchLink(); });
$('clear').onclick = () => { $('url').value = ''; $('url').focus(); render(); };
$('fetch').onclick = fetchLink;
$('paste').onclick = async () => {
  try { $('url').value = (await navigator.clipboard.readText()).trim(); } catch { return; }
  render(); fetchLink();
};
document.querySelectorAll('#modes button').forEach((b) => (b.onclick = () => { s.mode = b.dataset.mode; render(); }));
['start', 'end'].forEach((id) => $(id).addEventListener('input', updateRangeNote));
$('choose').onclick = chooseFolder;
$('choose-cookies').onclick = chooseCookies;
$('clear-cookies').onclick = () => { s.cookies = ''; store.set('cookies', ''); render(); };
$('download').onclick = download;
$('again').onclick = () => { s.phase = 'ready'; render(); download(); };
$('cancel').onclick = () => invoke('cancel_download');
$('reveal').onclick = async () => {
  try { if (s.file) await revealItemInDir(s.file); else await openPath(s.outputDir); } catch { try { await openPath(s.outputDir); } catch {} }
};
window.addEventListener('keydown', (e) => { if (e.key === 'Escape' && s.phase === 'downloading') invoke('cancel_download'); });

(async function init() {
  s.outputDir = store.get('outputDir', '') || await invoke('default_output_dir');
  s.tools = await invoke('tools_status');
  if (!s.tools.ytdlp) showError('Vodsnip could not find yt-dlp. Reinstall the app, or put yt-dlp on your PATH.');
  else if (!s.tools.ffmpeg) showError('ffmpeg was not found, so cutting and merging will fail. Reinstall the app.', true);
  render();
  const q = new URLSearchParams(location.search);
  // Test hooks: ?url=<link>&mode=range
  if (q.get('url')) { $('url').value = q.get('url'); await fetchLink(); if (q.get('mode')) { s.mode = q.get('mode'); render(); } }
})();
