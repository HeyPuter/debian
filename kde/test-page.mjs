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
  createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/${process.env.KDE_QUERY ? `?${process.env.KDE_QUERY}` : ''}`;
const prof = mkdtempSync(join(tmpdir(), 'gex-kde-'));
const port = 9400 + Math.floor(Math.random() * 500);
const chrome = spawn(CHROME, ['--ozone-platform=headless', '--no-sandbox', '--disable-gpu-sandbox', '--enable-unsafe-webgpu',
  '--use-angle=vulkan', '--enable-features=Vulkan', '--window-size=1280,800', `--remote-debugging-port=${port}`,
  '--remote-allow-origins=*', `--user-data-dir=${prof}`, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
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
b.on('Target.attachedToTarget', async (p) => { workers.set(p.sessionId, { url: p.targetInfo?.url, pid: null }); try { await b.send('Runtime.enable', {}, p.sessionId); await b.send('Runtime.runIfWaitingForDebugger', {}, p.sessionId); } catch {} });
b.on('Runtime.consoleAPICalled', (p, sid) => {
  const line = p.args.map((a) => a.value ?? a.description ?? '').join(' ');
  const w = workers.get(sid), m = /\[gex:(\d+)\]|\[gex\] pid (\d+):/.exec(line);
  if (w && m) w.pid = Number(m[1] ?? m[2]);
  appendFileSync(join(OUT, 'console.txt'), line + '\n');
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
      if (name === '(idle)' || name === '(program)' || name === 'k_ws_park' || name === 'wait' || /Atomics/.test(name)) continue;
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
// `wait S`, `click X,Y` (page pixels), `type TEXT`, `key NAME` (a DOM key
// name: Enter, Escape, Tab...), `shot`. Each step is logged.
const steps = (process.env.KDE_INPUT || '').split(';').map((x) => x.trim()).filter(Boolean);
let stepAt = 0;
const keyCodes = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39 };
async function step(st) {
  const [op, ...rest] = st.split(' '); const arg = rest.join(' ');
  log(`input: ${st}`);
  if (op === 'wait') { stepAt = Date.now() + Number(arg) * 1000; return; }
  if (op === 'click') {
    const [x, y] = arg.split(',').map(Number);
    await b.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, s);
    await new Promise((r) => setTimeout(r, 200));
    await b.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 }, s);
    await new Promise((r) => setTimeout(r, 150));
    await b.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 }, s);
  } else if (op === 'type') {
    for (const ch of arg) {
      const code = ch === ' ' ? 'Space' : /[a-z]/i.test(ch) ? `Key${ch.toUpperCase()}` : /[0-9]/.test(ch) ? `Digit${ch}` : '';
      await b.send('Input.dispatchKeyEvent', { type: 'keyDown', key: ch, text: ch, code, windowsVirtualKeyCode: ch.toUpperCase().charCodeAt(0) }, s);
      await b.send('Input.dispatchKeyEvent', { type: 'keyUp', key: ch, code, windowsVirtualKeyCode: ch.toUpperCase().charCodeAt(0) }, s);
      await new Promise((r) => setTimeout(r, 80));
    }
  } else if (op === 'key') {
    const vk = keyCodes[arg] ?? 0;
    await b.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: arg, code: arg, windowsVirtualKeyCode: vk, ...(arg === 'Enter' ? { text: '\r' } : {}) }, s);
    await b.send('Input.dispatchKeyEvent', { type: 'keyUp', key: arg, code: arg, windowsVirtualKeyCode: vk }, s);
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
  if (st?.phase === 'ready' && !readyAt) { readyAt = now; log(`ready: ${st.readyMs} ms from navigation; served ${served} bytes; browser ${rss()} MiB resident`); await shot(); lastShot = now; }
  if (profAt.length && (now - t0) / 1000 >= profAt[0]) await profileAll(profAt.shift());
  while (readyAt && steps.length && Date.now() >= stepAt) await step(steps.shift());
  if (now - lastNote > 30000) {
    lastNote = now;
    log(`phase ${st?.phase}; served ${(served / 1048576).toFixed(0)} MiB; browser ${rss()} MiB; last: ${(st?.out ?? '').trim().split('\n').pop()?.slice(0, 200)}`);
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
