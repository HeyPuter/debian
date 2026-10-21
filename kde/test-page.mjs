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

let ws = null;
for (let i = 0; i < 100 && !ws; i++) { ws = await browserWsUrl(port); if (!ws) await new Promise((r) => setTimeout(r, 100)); }
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
b.on('Target.attachedToTarget', async (p) => { try { await b.send('Runtime.enable', {}, p.sessionId); await b.send('Runtime.runIfWaitingForDebugger', {}, p.sessionId); } catch {} });
b.on('Runtime.consoleAPICalled', (p) => {
  const line = p.args.map((a) => a.value ?? a.description ?? '').join(' ');
  appendFileSync(join(OUT, 'console.txt'), line + '\n');
  if (/called through a declaration of the wrong type|panic|RuntimeError|wasm trap/i.test(line)) log(`console: ${line.slice(0, 300)}`);
});
b.on('Runtime.exceptionThrown', (p) => log(`exception: ${p.exceptionDetails?.exception?.description?.slice(0, 400)}`));
await b.send('Runtime.enable', {}, s);
await b.send('Page.enable', {}, s);
const ev = async (expr) => (await b.send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }, s)).result?.value;
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
let readyAt = null, lastShot = 0, lastNote = 0, peak = 0;
for (;;) {
  await new Promise((r) => setTimeout(r, 1000));
  const st = await ev('({ phase: globalThis.__kde?.phase, readyMs: globalThis.__kde?.readyMs, out: (globalThis.__kde?.out ?? "").slice(-4000), status: globalThis.__kde?.status })').catch(() => null);
  const now = Date.now();
  peak = Math.max(peak, rss());
  if (st?.out) writeFileSync(join(OUT, 'session.txt'), st.out);
  if (st?.phase === 'ready' && !readyAt) { readyAt = now; log(`ready: ${st.readyMs} ms from navigation; served ${served} bytes; browser ${rss()} MiB resident`); await shot(); lastShot = now; }
  if (now - lastNote > 30000) { lastNote = now; log(`phase ${st?.phase}; served ${(served / 1048576).toFixed(0)} MiB; browser ${rss()} MiB; last: ${(st?.out ?? '').trim().split('\n').pop()?.slice(0, 200)}`); }
  if (readyAt && now - lastShot > SHOT) { lastShot = now; await shot(); }
  if (st?.phase === 'exited') { log(`FAIL the session ended (${st.status})`); break; }
  if (readyAt && now - readyAt > AFTER) break;
  if (now - t0 > WALL) { log(`FAIL wall of ${WALL / 1000} s`); break; }
}
await shot();
const heap = await ev('performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) : -1').catch(() => -1);
log(`end: ready ${readyAt ? `${await ev('globalThis.__kde.readyMs')} ms` : 'never'}; served ${served} bytes; browser peak ${peak} MiB resident; page JS heap ${heap} MiB`);
process.exit(readyAt ? 0 : 1);
