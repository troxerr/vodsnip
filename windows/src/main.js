const { invoke, Channel } = window.__TAURI__.core;
const { open } = window.__TAURI__.dialog;
const { revealItemInDir } = window.__TAURI__.opener;
const $ = (id) => document.getElementById(id);

const store = {
  get: (k, d) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch {} },
};

const s = {
  phase: 'idle',            // idle | fetching | ready | downloading | done
  info: null, downloadUrl: null, isLiveNow: false, liveEdge: null,
  cancelling: false, downloadStarted: false, notice: '',
  mode: 'entire', outputDir: '', cookies: store.get('cookies', ''),
  progress: null, file: null, log: [], tools: null,
};

// ---------- time helpers (same rules as the Mac app) ----------
function parseTime(text) {
  const t = text.trim();
  if (!t) return null;
  const parts = t.split(':');
  if (parts.length > 3 || parts.some((p) => !/^(?:\d+\.?\d*|\.\d+)$/.test(p))) return null;
  const v = parts.map(Number);
  if (v.slice(1).some((x) => x >= 60)) return null;
  const seconds = v.reduce((a, x) => a * 60 + x, 0);
  return Number.isFinite(seconds) ? seconds : null;
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
  const busy = s.phase === 'downloading' || s.phase === 'fetching';
  $('clear').hidden = !$('url').value;
  $('clear').disabled = busy;
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
  const error = rangeError();
  updateRangeNote(error);
  document.querySelectorAll('#options button, #options input, #options select, #url, #paste').forEach((el) => (el.disabled = busy || (el.dataset?.mode === 'startNow' && !s.isLiveNow)));

  $('folder').textContent = s.outputDir;
  $('folder').title = s.outputDir;
  $('cookies').textContent = s.cookies || 'None';
  $('clear-cookies').hidden = !s.cookies;

  $('bar-idle').hidden = s.phase === 'downloading' || s.phase === 'done';
  $('bar-busy').hidden = s.phase !== 'downloading';
  $('bar-done').hidden = s.phase !== 'done';
  $('download').disabled = !(hasVideo && s.phase === 'ready' && s.tools?.ffmpeg && !error);
  $('cancel').disabled = s.cancelling;
  $('cancel').textContent = s.cancelling ? 'Cancelling…' : 'Cancel';
  $('summary').textContent = !hasVideo ? 'Paste a link to begin'
    : s.mode === 'entire' ? 'Whole video' : s.mode === 'startNow' ? 'From the start until now' : 'Selected range';

  if (s.notice && s.phase === 'ready') $('summary').textContent = s.notice;

  if (s.phase === 'downloading') {
    const p = s.progress;
    const prog = $('progress');
    if (p?.fraction != null) prog.value = p.fraction; else prog.removeAttribute('value');
    const parts = [];
    if (p?.fraction != null) parts.push(`${Math.floor(p.fraction * 100)}%`);
    if (p?.downloaded_bytes != null) parts.push(bytes(p.downloaded_bytes));
    if (p?.speed != null) parts.push(bytes(p.speed) + '/s');
    if (p?.eta != null) parts.push(fmt(p.eta) + ' left');
    $('progress-text').textContent = s.cancelling ? 'Waiting for the download to stop…'
      : !p ? 'Preparing…' : p.fraction >= 1 ? 'Finalizing…'
      : ['Downloading', ...parts].join(' · ');
  }
  if (s.phase === 'done') $('saved-name').textContent = s.file ? s.file.split(/[\\/]/).pop() : s.outputDir;
  $('open-file').hidden = !s.file;

  $('log-wrap').hidden = s.log.length === 0;
  $('log').textContent = s.log.join('\n');
}

function rangeError() {
  if (s.mode !== 'range' || !s.info) return null;
  const start = parseTime($('start').value);
  const endText = $('end').value.trim();
  const end = parseTime(endText);
  const limit = s.liveEdge ?? s.info.duration;
  if (start === null) return { field: 'start', message: 'Enter a start time, such as 1:30.' };
  if (limit != null && start >= limit) return { field: 'start', message: 'Start time must be before the end of the recording.' };
  if (endText && end === null) return { field: 'end', message: 'Enter an end time or leave it blank.' };
  if (end !== null && end <= start) return { field: 'end', message: 'End time must be after the start time.' };
  if (!s.isLiveNow && end !== null && limit != null && end > limit) {
    return { field: 'end', message: 'End time must be within the video.' };
  }
  return null;
}

function updateRangeNote(error) {
  const errorLabel = $('range-error');
  errorLabel.textContent = error?.message ?? '';
  errorLabel.hidden = !error;
  for (const id of ['start', 'end']) {
    $(id).classList.toggle('bad', error?.field === id);
    $(id).setAttribute('aria-invalid', String(error?.field === id));
  }

  const note = $('range-note');
  note.hidden = true;
  note.classList.remove('warn');
  if (s.mode === 'range' && s.info) {
    const start = parseTime($('start').value);
    const end = parseTime($('end').value) ?? s.info.duration;
    const effectiveEnd = s.liveEdge != null && end != null ? Math.min(end, s.liveEdge) : end;
    $('range-len').textContent = !error && start != null && effectiveEnd != null
      ? `${fmt(effectiveEnd - start)} long` : '';
    if (s.isLiveNow) {
      note.hidden = false; note.classList.add('warn');
      note.textContent = 'Live ranges download in real time. Start → now is faster.';
    }
  } else if (s.mode === 'startNow') {
    note.hidden = false;
    note.textContent = 'Saves the recording from the start of the stream until the moment you click Download.';
  }
}

function resetLink() {
  Object.assign(s, {
    phase: 'idle', info: null, downloadUrl: null, isLiveNow: false, liveEdge: null,
    file: null, progress: null, log: [], notice: '',
  });
  $('start').value = '00:00:00';
  $('end').value = '';
  showError('');
  render();
}

// ---------- actions ----------
async function fetchLink() {
  const url = $('url').value.trim();
  if (!url || $('fetch').disabled) return;
  resetLink();
  s.phase = 'fetching'; render();
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

async function download(cancelOnProgress = false) {
  if (s.phase !== 'ready' || $('download').disabled) return;
  showError('');
  Object.assign(s, { phase: 'downloading', cancelling: false, downloadStarted: false, notice: '', progress: null, log: [], file: null });
  render();
  const channel = new Channel();
  let active = true;
  channel.onmessage = ({ event, data }) => {
    if (!active) return;
    switch (event) {
      case 'started':
        s.downloadStarted = true;
        if (s.cancelling) sendCancellation();
        break;
      case 'length': s.info.duration = data.seconds; s.liveEdge = data.seconds; $('length').textContent = `${fmt(data.seconds)} recorded so far`; break;
      case 'progress':
        s.progress = data;
        if (cancelOnProgress && !s.cancelling) cancelDownload();
        break;
      case 'log': s.log.push(data.line); if (s.log.length > 200) s.log.shift(); break;
    }
    render();
  };
  let result;
  try {
    result = await invoke('start_download', {
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
    result = { event: 'failed', data: { message: String(e) } };
  }
  active = false;
  s.cancelling = false;
  const { event, data } = result;
  s.phase = event === 'done' ? 'done' : 'ready';
  if (event === 'done') s.file = data.file;
  if (event === 'failed') showError(data.message);
  if (event === 'cancelled') s.notice = 'Cancelled. Partial files may be reused on retry.';
  render();
  return { event, ...data };
}

function cancelDownload() {
  if (s.phase !== 'downloading' || s.cancelling) return;
  s.cancelling = true;
  render();
  if (s.downloadStarted) sendCancellation();
}

async function sendCancellation() {
  try {
    await invoke('cancel_download');
  } catch (e) {
    s.cancelling = false;
    showError(String(e));
    render();
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
$('url').addEventListener('input', resetLink);
$('url').addEventListener('keydown', (e) => { if (e.key === 'Enter') fetchLink(); });
$('clear').onclick = () => { $('url').value = ''; $('url').focus(); resetLink(); };
$('fetch').onclick = fetchLink;
$('paste').onclick = async () => {
  let url;
  try { url = (await navigator.clipboard.readText()).trim(); } catch { return; }
  if ($('paste').disabled) return;
  $('url').value = url;
  render();
  fetchLink();
};
document.querySelectorAll('#modes button').forEach((b) => (b.onclick = () => { s.mode = b.dataset.mode; render(); }));
['start', 'end'].forEach((id) => $(id).addEventListener('input', render));
$('choose').onclick = chooseFolder;
$('choose-cookies').onclick = chooseCookies;
$('clear-cookies').onclick = () => { s.cookies = ''; store.set('cookies', ''); render(); };
$('download').onclick = () => download();
$('again').onclick = () => { s.phase = 'ready'; render(); download(); };
$('cancel').onclick = cancelDownload;
$('open-file').onclick = async () => {
  try { await invoke('open_saved_file'); } catch (e) { showError(String(e)); }
};
$('reveal').onclick = async () => {
  try { await revealItemInDir(s.file); } catch (e) { showError(String(e)); }
};
window.addEventListener('keydown', (e) => { if (e.key === 'Escape') cancelDownload(); });

(async function init() {
  s.outputDir = store.get('outputDir', '') || await invoke('default_output_dir');
  s.tools = await invoke('tools_status');
  if (!s.tools.ytdlp) showError('Vodsnip could not find yt-dlp. Reinstall the app, or put yt-dlp on your PATH.');
  else if (!s.tools.ffmpeg) showError('ffmpeg was not found, so cutting and merging will fail. Reinstall the app.', true);
  render();
  // Test hooks (see startup_hooks in lib.rs).
  const hooks = await invoke('startup_hooks');
  if (hooks.url) {
    if (hooks.smokeDir) s.outputDir = hooks.smokeDir;
    $('url').value = hooks.url;
    render();
    await fetchLink();
    if (hooks.mode) { s.mode = hooks.mode; render(); }
    if (hooks.auto?.startsWith('download') && s.phase === 'ready') {
      if (hooks.smokeDir && s.mode === 'range') {
        $('start').value = '2';
        $('end').value = '12';
        render();
      }
      const job = download(hooks.smokeDir && hooks.auto === 'download,cancel-on-progress');
      const delayed = hooks.auto.match(/cancel:(\d+)/);
      const timer = delayed ? setTimeout(cancelDownload, Number(delayed[1]) * 1000) : null;
      const result = await job;
      clearTimeout(timer);
      if (hooks.smokeDir) {
        await invoke('report_smoke_result', { result: result ?? { event: 'downloadBlocked' } });
      }
    } else if (hooks.smokeDir) {
      await invoke('report_smoke_result', { result: { event: 'fetchFailed', message: $('banner').textContent } });
    }
  }
})();
