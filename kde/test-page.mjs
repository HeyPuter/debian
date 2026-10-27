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
// Env: CHROME (default /usr/bin/chromium), KDE_QUERY (appended to the URL).
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
  const size = statSync(f).size;
  served += size;
  res.writeHead(200, { ...h, 'Content-Type': TYPES[extname(f)] || 'application/octet-stream', 'Content-Length': size });
  // KDE_NETLOG=1: each request served, when it came and when its last byte
  // was handed over (seconds from start), as OUT/net.txt
  if (process.env.KDE_NETLOG) {
    const at = ((Date.now() - t0) / 1000).toFixed(3), rel = f.slice(SITE.length);
    res.on('finish', () => appendFileSync(join(OUT, 'net.txt'), `${at} ${((Date.now() - t0) / 1000).toFixed(3)} ${size} ${rel}\n`));
  }
  createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
// KDE_URL: boot a served demo instead of SITE (bytes then come from the
// server's own log, not "served")
const url = (process.env.KDE_URL || `http://127.0.0.1:${server.address().port}/`) + (process.env.KDE_QUERY ? `?${process.env.KDE_QUERY}` : '');
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
let readyAt = null, lastShot = Date.now(), lastNote = 0, peak = 0;
// KDE_INPUT: what a user does once the page is ready, steps split by ';':
// `wait S`, `click X,Y` (page pixels; negative from the right or
// bottom), `type TEXT`, `key NAME` (a DOM key name: Enter, Escape,
// Tab...), `hold CH N` (a key held for N repeats), `shot`, `profile`
// (every Worker's CPU profile from now, as KDE_PROFILE_AT takes). Each step is logged.
const steps = (process.env.KDE_INPUT || '').split(';').map((x) => x.trim()).filter(Boolean);
let stepAt = 0;
const keyCodes = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39 };
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
  peak = Math.max(peak, rss());
  if (st?.out) writeFileSync(join(OUT, 'session.txt'), st.out);
  // the whole of it, once a minute (session.txt is its last 4000 characters)
  if (now - lastFull > 60000) { lastFull = now; const all = await ev('globalThis.__kde?.out ?? ""').catch(() => null); if (all) writeFileSync(join(OUT, 'session-full.txt'), all); }
  if (st?.phase === 'ready' && !readyAt) {
    readyAt = now; log(`ready: ${st.readyMs} ms from navigation; served ${served} bytes; browser ${rss()} MiB resident`);
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
const heap = await ev('performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) : -1').catch(() => -1);
log(`end: ready ${readyAt ? `${await ev('globalThis.__kde.readyMs')} ms` : 'never'}; served ${served} bytes; browser peak ${peak} MiB resident; page JS heap ${heap} MiB`);
process.exit(readyAt && !sycoca ? 0 : 1);
