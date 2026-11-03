// The KDE demo site in headless Chromium: serves SITE (COOP/COEP, on
// 127.0.0.1), opens it, and follows the session until the desktop is up.
//
//   node kde/test-page.mjs SITE OUT        (GEX_SRC: a gex checkout, for web/test/cdp.mjs)
//
// Prints the page's phase and the session's last log line every 30 s, a
// screenshot of the compositor's output into OUT every KDE_SHOT seconds
// (default 60), and at the end: ms from navigation to the page's first frame
// (`ready`), bytes served, and the browser's memory (resident, all its
// processes). Ends KDE_AFTER seconds (default 120) after `ready`, or at
// KDE_WALL seconds (default 1800). OUT/console.txt gets every console line,
// OUT/session.txt the session's output.
// At `ready`, console.txt also gets the `[gex-mark]` lines `start` and
// `desktop` (ms of the epoch), which `gexc units profile` cuts a profile at.
// Env: CHROME (default /usr/bin/chromium), KDE_QUERY (appended to the URL;
// launch=0, Launch pressed at once, unless it names launch=S).
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { createReadStream, existsSync, statSync, mkdtempSync, rmSync, mkdirSync, writeFileSync, appendFileSync } from 'node:fs';
import { join, extname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import zlib from 'node:zlib';

const SITE = resolve(process.argv[2]);
const OUT = resolve(process.argv[3]);
mkdirSync(OUT, { recursive: true });
const { Cdp, browserWsUrl } = await import(join(process.env.GEX_SRC, 'web/test/cdp.mjs'));
const CHROME = process.env.CHROME || '/usr/bin/chromium';
const WALL = Number(process.env.KDE_WALL || 1800) * 1000;
const AFTER = Number(process.env.KDE_AFTER || 120) * 1000;
const SHOT = Number(process.env.KDE_SHOT || 60) * 1000;
const t0 = Date.now();
const log = (s) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] ${s}`);
for (const ev of ['uncaughtException', 'unhandledRejection']) process.on(ev, (e) => { log(`FAIL ${ev}: ${e?.stack || e}`); process.exit(1); });

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
  '.json': 'application/json', '.zst': 'application/zstd' };
let served = 0;
const server = createServer((req, res) => {
  const p = join(SITE, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  const h = { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp',
    'Cross-Origin-Resource-Policy': 'same-origin', 'Cache-Control': 'no-cache' };
  // A unit's files are named by their content (units/HASH/): cached for good,
  // so the processes after the first read them from the browser's cache.
  if (/^\/units\/[0-9a-f]{64}\//.test(new URL(req.url, 'http://x').pathname)) h['Cache-Control'] = 'public, max-age=31536000, immutable';
  const f = existsSync(p) && statSync(p).isDirectory() ? join(p, 'index.html') : p;
  if (!f.startsWith(SITE) || !existsSync(f) || !statSync(f).isFile()) return res.writeHead(404, h).end();
  // KDE_BLOCK=REGEX: requests whose path matches are refused (404) and
  // logged, a site's rest bundle say: what a session needs of it shows
  if (process.env.KDE_BLOCK && new RegExp(process.env.KDE_BLOCK).test(f.slice(SITE.length))) {
    log(`blocked: ${f.slice(SITE.length)} ${req.headers.range || ''}`);
    return res.writeHead(404, h).end();
  }
  const whole = statSync(f).size;
  // A range (the rest bundle's frames are read so): those bytes, 206.
  const r = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || '');
  const start = r ? Number(r[1]) : 0, end = r ? Math.min(r[2] ? Number(r[2]) : whole - 1, whole - 1) : whole - 1;
  if (r && start > end) return res.writeHead(416, { ...h, 'Content-Range': `bytes */${whole}` }).end();
  const size = end - start + 1;
  served += size;
  res.writeHead(r ? 206 : 200, { ...h, 'Content-Type': TYPES[extname(f)] || 'application/octet-stream', 'Content-Length': size,
    'Accept-Ranges': 'bytes', ...(r ? { 'Content-Range': `bytes ${start}-${end}/${whole}` } : {}) });
  // KDE_NETLOG=1: each request served, when it came and when its last byte
  // was handed over (seconds from start), as OUT/net.txt
  if (process.env.KDE_NETLOG) {
    const at = ((Date.now() - t0) / 1000).toFixed(3), rel = f.slice(SITE.length);
    res.on('finish', () => appendFileSync(join(OUT, 'net.txt'), `${at} ${((Date.now() - t0) / 1000).toFixed(3)} ${size} ${rel}\n`));
  }
  createReadStream(f, { start, end }).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
// KDE_URL: boot a served demo instead of SITE (bytes then come from the
// server's own log, not "served")
// the page waits for Launch: pressed at once (`launch=0`) unless KDE_QUERY says when
const query = /(^|&)launch=/.test(process.env.KDE_QUERY || '') ? process.env.KDE_QUERY : ['launch=0', process.env.KDE_QUERY].filter(Boolean).join('&');
const url = (process.env.KDE_URL || `http://127.0.0.1:${server.address().port}/`) + `?${query}`;
const prof = mkdtempSync(join(tmpdir(), 'gex-kde-'));
const port = 9400 + Math.floor(Math.random() * 500);
const chrome = spawn(CHROME, ['--ozone-platform=headless', '--no-sandbox', '--disable-gpu-sandbox', '--enable-unsafe-webgpu',
  '--use-angle=vulkan', '--enable-features=Vulkan', '--window-size=1280,800', `--remote-debugging-port=${port}`,
  '--remote-allow-origins=*', `--user-data-dir=${prof}`, ...(process.env.KDE_URL ? ['--ignore-certificate-errors'] : []),
  // KDE_CHROME_FLAGS: more browser flags, for diagnosis only (the demo runs
  // in a browser without any)
  ...(process.env.KDE_CHROME_FLAGS ? process.env.KDE_CHROME_FLAGS.split(' ').filter(Boolean) : []),
  'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
let stderr = '';
chrome.stderr.on('data', (d) => (stderr = (stderr + d).slice(-20000)));
let closing = false;
chrome.on('exit', (code, sig) => { if (!closing) { log(`FAIL the browser exited (${code}, ${sig}): ${stderr.slice(-1500)}`); process.exit(1); } });
process.on('exit', () => { closing = true; try { chrome.kill('SIGKILL'); } catch {} try { rmSync(prof, { recursive: true, force: true }); } catch {} });
// a signal ends the run through 'exit', so the browser goes with it
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, () => { log(`stopped (${sig})`); process.exit(1); });

let ws = null;
for (let i = 0; i < 600 && !ws; i++) { ws = await browserWsUrl(port); if (!ws) await new Promise((r) => setTimeout(r, 100)); }
if (!ws) throw new Error('no browser');
const b = await Cdp.connect(ws);
// the first tab can appear some time after the browser's endpoint does
let page = null;
for (let i = 0; i < 50 && !page; i++) {
  page = (await b.send('Target.getTargets')).targetInfos.find((t) => t.type === 'page');
  if (!page) await new Promise((r) => setTimeout(r, 200));
}
const targetId = page ? page.targetId : (await b.send('Target.createTarget', { url: 'about:blank' })).targetId;
const { sessionId: s } = await b.send('Target.attachToTarget', { targetId, flatten: true });
// every Worker's console too (each guest process runs in one)
await b.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, s);
// every attached Worker, and the guest pid it last spoke for (a pooled
// Worker runs one process after another)
const workers = new Map();
b.on('Target.detachedFromTarget', (p) => workers.delete(p.sessionId));
b.on('Target.attachedToTarget', async (p) => { workers.set(p.sessionId, { url: p.targetInfo?.url, pid: null }); try { await b.send('Runtime.enable', {}, p.sessionId); await b.send('Runtime.runIfWaitingForDebugger', {}, p.sessionId); } catch {} });
const consoleTime = !!process.env.KDE_CONSOLE_TIME;
const markRe = process.env.KDE_MARK ? new RegExp(process.env.KDE_MARK) : null, marked = new Set();
b.on('Runtime.consoleAPICalled', (p, sid) => {
  const line = p.args.map((a) => a.value ?? a.description ?? '').join(' ');
  const w = workers.get(sid), m = /\[gex:(\d+)\]|\[gex\] pid (\d+):/.exec(line);
  if (w && m) w.pid = Number(m[1] ?? m[2]);
  // KDE_CONSOLE_TIME=1: each console line with its time, as `log` gives it
  appendFileSync(join(OUT, 'console.txt'), (consoleTime ? `[${((Date.now() - t0) / 1000).toFixed(1)}s] ` : '') + line + '\n');
  // KDE_MARK=RE: the first console line each distinct match of RE is on,
  // logged with its time (`mark:`), e.g. when a program is first exec'd
  if (markRe) { const mm = markRe.exec(line); if (mm && !marked.has(mm[0])) { marked.add(mm[0]); log(`mark: ${mm[0]}`); } }
  if (/called through a declaration of the wrong type|panic|RuntimeError|wasm trap/i.test(line)) log(`console: ${line.slice(0, 300)}`);
});
b.on('Runtime.exceptionThrown', (p) => log(`exception: ${p.exceptionDetails?.exception?.description?.slice(0, 400)}`));
await b.send('Runtime.enable', {}, s);
await b.send('Page.enable', {}, s);
// a tab that dies (out of memory, a renderer crash) answers nothing again:
// said, with the browser's last words, rather than waited on for ever
b.on('Inspector.targetCrashed', (p, sid) => { if (sid === s) { log(`FAIL the page crashed: ${stderr.slice(-1500)}`); process.exit(1); } });
await b.send('Inspector.enable', {}, s);
// and one that hangs (its main thread busy): each question gives up after
// a minute, said once per minute
let hungSaid = 0;
const ev = async (expr) => {
  let timer;
  const late = new Promise((_, rej) => { timer = setTimeout(() => rej(new Error('no answer in 60 s')), 60000); });
  try {
    return (await Promise.race([b.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }, s), late])).result?.value;
  } catch (e) {
    if (/no answer/.test(e.message) && Date.now() - hungSaid > 60000) { hungSaid = Date.now(); log('the page did not answer in 60 s'); }
    throw e;
  } finally { clearTimeout(timer); }
};
function png(w, h, rgba) {
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (buf) => { let c = 0xffffffff; for (const x of buf) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (type, data) => { const l = Buffer.alloc(4); l.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
let shots = 0;
async function shot() {
  const r = await ev('globalThis.__gexCompositor?.readoutBase64?.()').catch(() => null);
  const name = join(OUT, `shot-${String(shots++).padStart(2, '0')}.png`);
  if (r) writeFileSync(name, png(r.w, r.h, Buffer.from(r.b64, 'base64')));
  else { const { data } = await b.send('Page.captureScreenshot', { format: 'png' }, s); writeFileSync(name, Buffer.from(data, 'base64')); }
  log(`screenshot ${name}${r ? ` (compositor ${r.w}x${r.h})` : ' (page)'}`);
}
function rss() {
  // resident set of the browser and every process under it, MiB
  try {
    const out = execFileSync('ps', ['-e', '-o', 'pid=,ppid=,rss='], { encoding: 'utf8' });
    const rows = out.trim().split('\n').map((l) => l.trim().split(/\s+/).map(Number));
    const kids = new Map(); for (const [p, pp] of rows) { if (!kids.has(pp)) kids.set(pp, []); kids.get(pp).push(p); }
    const byPid = new Map(rows.map(([p, , r]) => [p, r]));
    let sum = 0; const todo = [chrome.pid];
    while (todo.length) { const p = todo.pop(); sum += byPid.get(p) ?? 0; todo.push(...(kids.get(p) ?? [])); }
    return Math.round(sum / 1024);
  } catch { return -1; }
}

log(`open ${url}`);
await b.send('Page.navigate', { url }, s);
let lastFull = 0, sycoca = false;
// KDE_PROFILE_AT=S1,S2..: at those seconds, a CPU profile of every Worker for
// KDE_PROFILE_SECS (default 10); each busy one's top functions are logged and
// its profile kept as OUT/prof-S-PID.cpuprofile
const profAt = (process.env.KDE_PROFILE_AT || '').split(',').filter(Boolean).map(Number);
async function profileAll(at) {
  const secs = Number(process.env.KDE_PROFILE_SECS || 10);
  const ids = [...workers.keys()];
  await Promise.all(ids.map(async (id) => { try { await b.send('Profiler.enable', {}, id); await b.send('Profiler.setSamplingInterval', { interval: 1000 }, id); await b.send('Profiler.start', {}, id); } catch {} }));
  await new Promise((r) => setTimeout(r, secs * 1000));
  const rows = [];
  await Promise.all(ids.map(async (id) => {
    let prof; try { prof = (await b.send('Profiler.stop', {}, id)).profile; } catch { return; }
    const byId = new Map(prof.nodes.map((n) => [n.id, n]));
    const self = new Map(); let busy = 0;
    for (const sid of prof.samples) {
      const f = byId.get(sid).callFrame; const name = f.functionName || `(anon ${f.url.split('/').pop()}:${f.lineNumber})`;
      // a thread blocked in the kernel (gex_syscall's wait, a park) is idle too
      if (name === '(idle)' || name === '(program)' || name === 'k_ws_park' || name === 'wait' || /Atomics|waitq4park|^gex_syscall$/.test(name)) continue;
      busy++; self.set(name, (self.get(name) || 0) + 1);
    }
    const w = workers.get(id);
    rows.push({ id, pid: w?.pid, busy, total: prof.samples.length, top: [...self].sort((a, b) => b[1] - a[1]).slice(0, 25), prof });
  }));
  rows.sort((a, b) => b.busy - a.busy);
  for (const r of rows.filter((r) => r.busy > r.total / 10).slice(0, 8)) {
    log(`profile at ${at}s: pid ${r.pid} busy ${r.busy}/${r.total} samples; top: ${r.top.map(([n, c]) => `${n} ${c}`).join(', ').slice(0, 1500)}`);
    writeFileSync(join(OUT, `prof-${at}-${r.pid}.cpuprofile`), JSON.stringify(r.prof));
  }
}
let readyAt = null, lastShot = Date.now(), lastNote = 0, peak = 0, lastMem = 0, lastSmaps = 0;
function smaps() {
  try {
    const out = execFileSync('ps', ['-e', '-o', 'pid=,ppid=,rss=,args='], { encoding: 'utf8', maxBuffer: 1 << 26 });
    const rows = out.trim().split('\n').map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean);
    const mine = new Set([String(chrome.pid)]);
    for (let grew = true; grew;) { grew = false; for (const m of rows) if (mine.has(m[2]) && !mine.has(m[1])) { mine.add(m[1]); grew = true; } }
    const r = rows.filter((m) => mine.has(m[1]) && /--type=renderer/.test(m[4])).sort((x, y) => Number(y[3]) - Number(x[3]))[0];
    if (!r) return;
    const text = execFileSync('cat', [`/proc/${r[1]}/smaps`], { encoding: 'utf8', maxBuffer: 1 << 28 });
    const maps = [];
    let cur = null;
    for (const l of text.split('\n')) {
      const h = /^([0-9a-f]+)-([0-9a-f]+) \S+ \S+ \S+ \S+\s*(.*)$/.exec(l);
      if (h) { cur = { size: (parseInt(h[2], 16) - parseInt(h[1], 16)) / 1048576, name: h[3] || 'anon', rss: 0 }; maps.push(cur); continue; }
      const m = /^Rss:\s+(\d+) kB/.exec(l);
      if (m && cur) cur.rss = Number(m[1]) / 1024;
    }
    const big = maps.filter((m) => m.rss >= 16).sort((x, y) => y.rss - x.rss);
    const total = maps.reduce((a, m) => a + m.rss, 0);
    appendFileSync(join(OUT, 'smaps.txt'), `${((Date.now() - t0) / 1000).toFixed(1)} renderer ${r[1]} rss ${total.toFixed(0)} MiB; ${big.length} mappings >= 16 MiB: ${big.slice(0, 40).map((m) => `${m.rss.toFixed(0)}/${m.size >= 1024 ? (m.size / 1024).toFixed(0) + 'G' : m.size.toFixed(0) + 'M'}${m.name === 'anon' ? '' : ' ' + m.name.split('/').pop()}`).join(' ')}\n`);
  } catch (e) { appendFileSync(join(OUT, 'smaps.txt'), `smaps: ${e.message}\n`); }
}
async function memPids() {
  const rows = await Promise.all([...workers.entries()].map(async ([sid, w]) => {
    const [h, r] = await Promise.all([
      Promise.race([b.send('Runtime.getHeapUsage', {}, sid), new Promise((res) => setTimeout(() => res(null), 3000))]).catch(() => null),
      Promise.race([b.send('Runtime.evaluate', { expression: 'JSON.stringify(globalThis.__gexWho?.() ?? null)', returnByValue: true }, sid), new Promise((res) => setTimeout(() => res(null), 3000))]).catch(() => null)]);
    let v = null;
    try { v = r ? JSON.parse(r.result?.value ?? 'null') : null; } catch {}
    return { mib: (h?.backingStorageSize ?? 0) / 1048576, js: (h?.usedSize ?? 0) / 1048576, who: v?.pid != null ? `${v.pid}${v.tid ? '.' + v.tid : ''} ${(v.cmdline || '?').split(' ')[0].split('/').pop()}` : '-' };
  }));
  rows.sort((x, y) => y.mib - x.mib);
  const total = rows.reduce((a, x) => a + x.mib, 0);
  const line = `${((Date.now() - t0) / 1000).toFixed(1)} total ${total.toFixed(0)} MiB in ${rows.length} workers; ${rows.slice(0, 12).map((x) => `${x.who} ${x.mib.toFixed(0)}+${x.js.toFixed(0)}js`).join(', ')}`;
  appendFileSync(join(OUT, 'mempids.txt'), line + '\n');
}
// KDE_INPUT: what a user does once the page is ready, steps split by ';':
// `wait S`, `click X,Y` (page pixels; negative from the right or
// bottom), `dblclick X,Y`, `rclick X,Y` (the right button), `move X,Y`,
// `drag X,Y X2,Y2` (the left button held across), `scroll X,Y N` (N wheel
// notches, down if positive), `type TEXT`, `key NAME` (a DOM key name:
// Enter, Escape, Tab, Delete, F2..., or a chord: Control+s,
// Control+Shift+t, Alt+F4, Shift+Delete), `hold CH N` (a key held for N
// repeats), `mark` (a clock starts) and `at S` (wait until S seconds on
// it: steps on a guest script's schedule, which waits would drift from as
// each step takes its own time), `shot`, `profile`
// (every Worker's CPU profile from now, as KDE_PROFILE_AT takes). Each step is logged.
const steps = (process.env.KDE_INPUT || '').split(';').map((x) => x.trim()).filter(Boolean);
let stepAt = 0;
let markAt = 0;
const keyCodes = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Delete: 46, Home: 36, End: 35, PageUp: 33, PageDown: 34, Insert: 45, Space: 32 };
for (let i = 1; i <= 12; i++) keyCodes[`F${i}`] = 111 + i;
// a chord's modifiers: DevTools' modifier bit, key code and virtual key
const modKeys = { Alt: [1, 'AltLeft', 18], Control: [2, 'ControlLeft', 17], Meta: [4, 'MetaLeft', 91], Shift: [8, 'ShiftLeft', 16] };
// `X,Y` in page pixels, a negative one from the right or bottom edge
async function point(arg) {
  let [x, y] = arg.split(',').map(Number);
  if (x < 0 || y < 0) {
    const r = await b.send('Runtime.evaluate', { expression: '[innerWidth, innerHeight]', returnByValue: true }, s);
    const [w, h] = r.result?.value ?? [0, 0];
    if (x < 0) x += w;
    if (y < 0) y += h;
  }
  return [x, y];
}
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
async function press(x, y, button, clickCount) {
  const buttons = button === 'right' ? 2 : 1;
  await b.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button, buttons, clickCount }, s);
  await pause(120);
  await b.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button, buttons: 0, clickCount }, s);
}
// A US keyboard: each character's key, and whether it is shifted
const plainKeys = { ' ': 'Space', '-': 'Minus', '=': 'Equal', '[': 'BracketLeft', ']': 'BracketRight', '\\': 'Backslash', ';': 'Semicolon', "'": 'Quote', '`': 'Backquote', ',': 'Comma', '.': 'Period', '/': 'Slash' };
const shiftedKeys = { '_': 'Minus', '+': 'Equal', '{': 'BracketLeft', '}': 'BracketRight', '|': 'Backslash', ':': 'Semicolon', '"': 'Quote', '~': 'Backquote', '<': 'Comma', '>': 'Period', '?': 'Slash', ')': 'Digit0', '!': 'Digit1', '@': 'Digit2', '#': 'Digit3', '$': 'Digit4', '%': 'Digit5', '^': 'Digit6', '&': 'Digit7', '*': 'Digit8', '(': 'Digit9' };
function keyOf(ch) {
  if (/[a-z]/.test(ch)) return [`Key${ch.toUpperCase()}`, false];
  if (/[A-Z]/.test(ch)) return [`Key${ch}`, true];
  if (/[0-9]/.test(ch)) return [`Digit${ch}`, false];
  if (plainKeys[ch]) return [plainKeys[ch], false];
  return [shiftedKeys[ch] ?? '', true];
}
async function step(st) {
  const [op, ...rest] = st.split(' '); const arg = rest.join(' ');
  log(`input: ${st}`);
  if (op === 'wait') { stepAt = Date.now() + Number(arg) * 1000; return; }
  if (op === 'mark') { markAt = Date.now(); return; }
  if (op === 'at') { stepAt = markAt + Number(arg) * 1000; return; }
  // `profile`: profileAll from here, in the background (KDE_PROFILE_SECS)
  if (op === 'profile') { profileAll(`${((Date.now() - t0) / 1000).toFixed(0)}`).catch((e) => log(`profile: ${e}`)); return; }
  if (op === 'click') {
    let [x, y] = arg.split(',').map(Number);
    // a negative coordinate counts from the page's right or bottom edge (the
    // panel sits at the bottom whatever the window's height)
    if (x < 0 || y < 0) {
      const r = await b.send('Runtime.evaluate', { expression: '[innerWidth, innerHeight]', returnByValue: true }, s);
      const [w, h] = r.result?.value ?? [0, 0];
      if (x < 0) x += w;
      if (y < 0) y += h;
      log(`input: click at ${x},${y} (page ${w}x${h})`);
    }
    await b.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, s);
    await new Promise((r) => setTimeout(r, 200));
    await b.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 }, s);
    await new Promise((r) => setTimeout(r, 150));
    await b.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 }, s);
  } else if (op === 'dblclick' || op === 'rclick' || op === 'move') {
    const [x, y] = await point(arg);
    await b.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, s);
    await pause(200);
    if (op === 'rclick') await press(x, y, 'right', 1);
    if (op === 'dblclick') { await press(x, y, 'left', 1); await pause(80); await press(x, y, 'left', 2); }
  } else if (op === 'drag') {
    // pressed, moved there in steps (a drag starts past a threshold, and
    // its target sees the pointer arrive), held a moment, released
    const [from, to] = rest;
    const [x, y] = await point(from), [x2, y2] = await point(to);
    await b.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, s);
    await pause(200);
    await b.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 }, s);
    for (let i = 1; i <= 20; i++) {
      await pause(50);
      await b.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x + ((x2 - x) * i) / 20, y: y + ((y2 - y) * i) / 20, button: 'left', buttons: 1 }, s);
    }
    await pause(500);
    await b.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x2, y: y2, button: 'left', buttons: 0, clickCount: 1 }, s);
  } else if (op === 'scroll') {
    const [x, y] = await point(rest[0]);
    for (let i = 0; i < Math.abs(Number(rest[1] ?? 1)); i++) {
      await b.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: 0, deltaY: Math.sign(Number(rest[1] ?? 1)) * 100 }, s);
      await pause(100);
    }
  } else if (op === 'type') {
    for (const ch of arg) {
      // the compositor maps KeyboardEvent.code (a key, not a character), so
      // a shifted character is Shift and its key
      const [code, shift] = keyOf(ch);
      if (!code) { log(`input: no key types ${JSON.stringify(ch)}`); continue; }
      if (shift) await b.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Shift', code: 'ShiftLeft', windowsVirtualKeyCode: 16, modifiers: 8 }, s);
      await b.send('Input.dispatchKeyEvent', { type: 'keyDown', key: ch, text: ch, code, windowsVirtualKeyCode: ch.toUpperCase().charCodeAt(0), modifiers: shift ? 8 : 0 }, s);
      await b.send('Input.dispatchKeyEvent', { type: 'keyUp', key: ch, code, windowsVirtualKeyCode: ch.toUpperCase().charCodeAt(0), modifiers: shift ? 8 : 0 }, s);
      if (shift) await b.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Shift', code: 'ShiftLeft', windowsVirtualKeyCode: 16 }, s);
      await new Promise((r) => setTimeout(r, 80));
    }
  } else if (op === 'key' && /^((Alt|Control|Meta|Shift)\+)+[^+]+$/.test(arg)) {
    // `key Control+Shift+t`: the modifiers pressed in order, the key, and
    // released in reverse
    const parts = arg.split('+'); const last = parts.pop();
    let mods = 0;
    for (const m of parts) {
      const [bit, code, vk] = modKeys[m]; mods |= bit;
      await b.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: m, code, windowsVirtualKeyCode: vk, modifiers: mods }, s);
    }
    const one = last.length === 1;
    const code = one ? keyOf(last.toLowerCase())[0] : last;
    const vk = one ? last.toUpperCase().charCodeAt(0) : (keyCodes[last] ?? 0);
    const key = one && mods & 8 ? last.toUpperCase() : last;
    await b.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, code, windowsVirtualKeyCode: vk, modifiers: mods }, s);
    await b.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: vk, modifiers: mods }, s);
    for (const m of parts.reverse()) {
      const [bit, code, vk] = modKeys[m]; mods &= ~bit;
      await b.send('Input.dispatchKeyEvent', { type: 'keyUp', key: m, code, windowsVirtualKeyCode: vk, modifiers: mods }, s);
    }
  } else if (op === 'key') {
    const vk = keyCodes[arg] ?? 0;
    await b.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: arg, code: arg, windowsVirtualKeyCode: vk, ...(arg === 'Enter' ? { text: '\r' } : {}) }, s);
    await b.send('Input.dispatchKeyEvent', { type: 'keyUp', key: arg, code: arg, windowsVirtualKeyCode: vk }, s);
  } else if (op === 'hold') {
    // `hold CH N`: CH held down for N of the browser's repeats (as a user
    // holding a key gets them, 33 ms apart), then released
    const [ch, n] = [arg.split(' ')[0], Number(arg.split(' ')[1] ?? 10)];
    const [code] = keyOf(ch);
    const ev = (type, autoRepeat) => b.send('Input.dispatchKeyEvent', { type, key: ch, code, windowsVirtualKeyCode: ch.toUpperCase().charCodeAt(0), autoRepeat, ...(type === 'keyDown' ? { text: ch } : {}) }, s);
    await ev('keyDown', false);
    for (let i = 0; i < n; i++) { await new Promise((r) => setTimeout(r, 33)); await ev('keyDown', true); }
    await ev('keyUp', false);
  } else if (op === 'shot') await shot();
  else log(`input: unknown step ${op}`);
}
for (;;) {
  await new Promise((r) => setTimeout(r, 1000));
  const st = await ev('({ phase: globalThis.__kde?.phase, readyMs: globalThis.__kde?.readyMs, out: (globalThis.__kde?.out ?? "").slice(-4000), status: globalThis.__kde?.status })').catch(() => null);
  const now = Date.now();
  const r = rss();
  peak = Math.max(peak, r);
  // KDE_RSS=1: the browser's resident set every second, as OUT/rss.txt
  // (seconds from start, MiB)
  if (process.env.KDE_RSS) appendFileSync(join(OUT, 'rss.txt'), `${((now - t0) / 1000).toFixed(1)} ${r}\n`);
  // KDE_MEMPIDS=S: every S seconds, each Worker's array buffer backing
  // stores (its wasm memories) by the guest process it runs, largest first
  if (process.env.KDE_MEMPIDS && now - lastMem >= Number(process.env.KDE_MEMPIDS) * 1000) { lastMem = now; await memPids(); }
  // KDE_SMAPS=S: every S seconds, the renderer's resident mappings of
  // 16 MiB or more (each wasm memory is one), as OUT/smaps.txt
  if (process.env.KDE_SMAPS && now - lastSmaps >= Number(process.env.KDE_SMAPS) * 1000) { lastSmaps = now; smaps(); }
  if (st?.out) writeFileSync(join(OUT, 'session.txt'), st.out);
  // the whole of it, once a minute (session.txt is its last 4000 characters)
  if (now - lastFull > 60000) { lastFull = now; const all = await ev('globalThis.__kde?.out ?? ""').catch(() => null); if (all) writeFileSync(join(OUT, 'session-full.txt'), all); }
  if (st?.phase === 'ready' && !readyAt) {
    readyAt = now; log(`ready: ${st.readyMs} ms from navigation; served ${served} bytes; browser ${rss()} MiB resident`);
    // KDE_OPENED=FILE: the files whose bytes the session used up to ready,
    // in the order of first use (a site's first bundle: mksite.sh OPENED)
    if (process.env.KDE_OPENED) {
      const o = await ev('globalThis.__ntOpened ? __ntOpened().then((p) => JSON.stringify(p), (e) => JSON.stringify({ error: String(e) })) : "null"');
      const paths = JSON.parse(o ?? 'null');
      if (Array.isArray(paths)) writeFileSync(process.env.KDE_OPENED, paths.join('\n') + '\n');
      log(`opened: ${Array.isArray(paths) ? `${paths.length} files to ${process.env.KDE_OPENED}` : JSON.stringify(paths)}`);
    }
    // the start-up marks an instrumented run's profile is cut at (`gexc
    // units profile`): the navigation and the desktop, in ms of the epoch
    const origin = await ev('performance.timeOrigin').catch(() => null);
    if (origin) appendFileSync(join(OUT, 'console.txt'), `[gex-mark] start ${origin}\n[gex-mark] desktop ${origin + st.readyMs}\n`);
    await shot(); lastShot = now;
  }
  if (profAt.length && (now - t0) / 1000 >= profAt[0]) await profileAll(profAt.shift());
  while (readyAt && steps.length && Date.now() >= stepAt) await step(steps.shift());
  if (now - lastNote > 30000) {
    lastNote = now;
    log(`phase ${st?.phase}; served ${(served / 1048576).toFixed(0)} MiB; browser ${rss()} MiB; last: ${(st?.out ?? '').trim().split('\n').pop()?.slice(0, 200)}`);
    // KDE_HEAPS=1: every isolate's JS heap (the page's and each Worker's),
    // which share one renderer and its limits
    if (process.env.KDE_HEAPS) {
      const sizes = await Promise.all([s, ...workers.keys()].map((sid) => Promise.race([b.send('Runtime.getHeapUsage', {}, sid), new Promise((r) => setTimeout(() => r(null), 5000))]).catch(() => null)));
      const ok = sizes.filter(Boolean), sum = (k) => ok.reduce((a, h) => a + (h[k] ?? 0), 0) / 1048576;
      // Workers per guest pid (the pid each last spoke for), most first
      const per = new Map();
      for (const w of workers.values()) per.set(w.pid, (per.get(w.pid) ?? 0) + 1);
      const byPid = [...per].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([p, n]) => `${p ?? '?'}:${n}`).join(' ');
      log(`heaps: workers per pid ${byPid}`);
      // KDE_WHO=1: each Worker's guest thread, asked of the Worker itself
      // (worker.mjs `__gexWho`); one parked in a wait does not answer
      if (process.env.KDE_WHO) {
        const who = await Promise.all([...workers.entries()].map(async ([sid, w]) => {
          const r = await Promise.race([b.send('Runtime.evaluate', { expression: 'JSON.stringify(globalThis.__gexWho?.() ?? null)', returnByValue: true }, sid), new Promise((res) => setTimeout(() => res(null), 3000))]).catch(() => null);
          let v = null;
          try { v = r ? JSON.parse(r.result?.value ?? 'null') : undefined; } catch {}
          if (v?.pid != null) w.pid = v.pid;
          // a Worker with no guest by its script (the runtime's own, or the
          // compositor's, the fill's...): the runtime's are the host's pool
          const script = (w.url || '?').split('?')[0].split('/').pop().replace(/-[A-Za-z0-9_]{8}\.js$/, '.js');
          return v === undefined ? `no answer (${script})` : v === null ? `no guest (${script})` : `${(v.cmdline || '?').split(' ')[0].split('/').pop()}${v.tid ? ' thread' : ''}`;
        }));
        const n = new Map();
        for (const k of who) n.set(k, (n.get(k) ?? 0) + 1);
        log(`heaps: workers by program ${[...n].sort((a, b) => b[1] - a[1]).map(([k, c]) => `${k}:${c}`).join(', ')}`);
        // and the host's own count, where the page build has one
        const census = await ev('JSON.stringify(globalThis.__gexHosts?.map((h) => h.census) ?? null)').catch(() => null);
        if (census && census !== 'null') log(`heaps: host workers ${census.slice(0, 1500)}`);
      }
      log(`heaps: ${ok.length} of ${sizes.length} isolates; used ${sum('usedSize').toFixed(0)} MiB, total ${sum('totalSize').toFixed(0)} MiB, backing stores ${sum('backingStorageSize').toFixed(0)} MiB; page ${((sizes[0]?.totalSize ?? 0) / 1048576).toFixed(0)} MiB`);
    }
    // KDE_SCENE=1: the compositor's frames, windows and scene, each note
    if (process.env.KDE_SCENE) {
      const sc = await ev('(async () => JSON.stringify({ c: globalThis.__gexCompositor?.counters?.(), d: await globalThis.__gexCompositor?.describe?.({ pixels: false }) }))()', true).catch((e) => String(e));
      log(`scene ${String(sc).slice(0, 1500)}`);
    }
  }
  // before `ready` too: a session can draw its desktop without the page
  // calling itself ready
  if (now - lastShot > SHOT) { lastShot = now; await shot(); }
  if (!sycoca && /gex-kde-session: (ksycoca rebuilt|no ksycoca)/.test(st?.out ?? '')) { sycoca = true; log(`FAIL ${(st.out.match(/gex-kde-session: (ksycoca rebuilt[^\n]*|no ksycoca[^\n]*)/) || [])[0]}`); }
  if (st?.phase === 'exited') { log(`FAIL the session ended (${st.status})`); break; }
  if (readyAt && now - readyAt > AFTER && !steps.length && Date.now() >= stepAt) break;
  if (now - t0 > WALL) { log(`FAIL wall of ${WALL / 1000} s`); break; }
}
await shot();
// and KDE_OPENED.end: the files used by the end of the run (the input's
// programs too), with the whole session output
if (process.env.KDE_OPENED) {
  const o = await ev('globalThis.__ntOpened ? __ntOpened().then((p) => JSON.stringify(p), (e) => JSON.stringify({ error: String(e) })) : "null"').catch((e) => JSON.stringify({ error: String(e) }));
  const paths = JSON.parse(o ?? 'null');
  if (Array.isArray(paths)) writeFileSync(`${process.env.KDE_OPENED}.end`, paths.join('\n') + '\n');
  log(`opened by the end: ${Array.isArray(paths) ? paths.length : JSON.stringify(paths)}`);
  const all = await ev('globalThis.__kde?.out ?? ""').catch(() => null);
  if (all) writeFileSync(join(OUT, 'session-full.txt'), all);
}
const heap = await ev('performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) : -1').catch(() => -1);
log(`end: ready ${readyAt ? `${await ev('globalThis.__kde.readyMs')} ms` : 'never'}; served ${served} bytes; browser peak ${peak} MiB resident; page JS heap ${heap} MiB`);
process.exit(readyAt && !sycoca ? 0 : 1);
