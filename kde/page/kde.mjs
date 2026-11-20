// The KDE demo's loader: the Debian KDE session on the gex runtime package
// (rt/, @gexemu/runtime), through its public API alone. The site's policy is
// here: the tree (kde.tar, packed as kde.tar.zst per pack.json) and its rest
// bundle (lazy.json, rest.bin: each file fetched as the guest reads it), the
// site-served apt repository (site.json pageHosts), the network, and how the
// session is started.
//
// start(options) -> handle, as index.html uses it:
//   container   the element the desktop fills
//   size        'fit' (the container's), 'WxH'
//   filesystem  'memory' or { kind: 'opfs', name }
//   wisp        a Wisp proxy's URL for the guest's network, or none (offline)
//   env         ['K=V', ...] after the session's own
//   debug       the runtime's switches
//   onLog(text), onProgress({ phase: 'boot' | 'ready' | 'exited' | 'failed', boot: { program }, error })
// handle: { exited (the session's status), ready() (the desktop is up: the
//   page saw plasmashell say so), system, describe(opts), kill() }

import { System } from './rt/index.mjs';
import { MemoryFilesystem, OPFSFilesystem } from './rt/fs.mjs';
import { CompositorWindows } from './rt/windows-compositor.mjs';
import { SiteHosts } from './site-hosts.mjs';

const json = async (url, what) => {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${what ?? url}: ${r.status} ${r.statusText}`);
  return r.json();
};

export async function start(opts = {}) {
  const at = (p) => new URL(p, import.meta.url).href;
  const progress = (p) => opts.onProgress?.(p);
  if (!globalThis.crossOriginIsolated) throw new Error('This page needs cross-origin isolation for its threads: serve it with the headers Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: require-corp.');
  if (!navigator.gpu) throw new Error('This browser has no WebGPU, which the desktop draws with. Use a recent desktop Chrome or Edge with hardware acceleration on.');
  const [site, pack] = await Promise.all([json(at('site.json'), 'the site\'s settings'), json(at('pack.json')).catch(() => ({}))]);
  /** A site file's URL, named by the build so a cached copy is the same build's; with `zst`, its packed
   *  copy (FILE.zst, pack.json's) when it has one. */
  const url = (path, zst = false) => {
    const u = new URL(at(zst && pack.files?.[`/${path}`] ? `${path}.zst` : path));
    if (pack.build) u.search = `v=${pack.build}`;
    return u.href;
  };

  // The tree's programs are arm64 Debian's beside wasm32 ones: aarch64, named
  // so the runtime loads while the tree downloads.
  const sys = new System({ arch: 'aarch64', debug: { ...(site.switches ?? {}), ...(opts.debug ?? {}) } });
  const where = opts.filesystem ?? 'memory';
  const fs = where?.kind === 'opfs' ? new OPFSFilesystem(sys, { name: where.name }) : new MemoryFilesystem(sys);
  // The tree, with the rest bundle's files (lazy.json) over its last tar: each read from rest.bin as the guest
  // first reads it.
  const tars = site.tar ?? ['kde.tar'];
  tars.forEach((t, i) => fs.addTar(url(t, true), i === tars.length - 1 && site.lazy ? { lazy: url(site.lazy) } : {}));

  // The desktop: one canvas, the scene compositor's; the X server rootful (one
  // fullscreen screen under KWin, which draws the decorations).
  const container = opts.container ?? document.body;
  const sizeOf = (s) => (s && s !== 'fit' ? String(s).split('x').map(Number)
    : [Math.max(640, container.clientWidth || innerWidth), Math.max(480, container.clientHeight || innerHeight)]);
  let [w, h] = sizeOf(opts.size);
  const canvas = document.createElement('canvas');
  canvas.style.display = 'block';
  const place = () => {
    canvas.width = w;
    canvas.height = h;
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
  };
  place();
  container.append(canvas);
  const windows = new CompositorWindows(sys, { canvas, scale: 1, x11: 'rootful' });
  globalThis.__gexCompositor = { describe: (o) => windows.describe(o) };
  if (!opts.size || opts.size === 'fit') {
    addEventListener('resize', () => {
      const [nw, nh] = sizeOf('fit');
      if (nw === w && nh === h) return;
      [w, h] = [nw, nh];
      canvas.style.width = `${w}px`;
      canvas.style.height = `${h}px`;
      windows.resize(w, h);
    });
  }

  let failed = false;
  sys.addEventListener('failed', (e) => {
    failed = true;
    progress({ phase: 'failed', error: String(e.error?.stack ?? e.error) });
  });
  sys.addEventListener('console', (e) => opts.onLog?.(e.text));

  await sys.boot();
  progress({ phase: 'boot', boot: { program: null } });
  // The guest's network: the site's own hosts (its apt repository), the rest through Wisp.
  let inner = null;
  if (opts.wisp) {
    const { Wisp } = await import('./rt/net-wisp.mjs');
    inner = new Wisp(String(opts.wisp));
  }
  sys.network = new SiteHosts(site.pageHosts ?? {}, at('./'), inner);

  const env = {
    PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', HOME: '/root', TERM: 'xterm-256color', LANG: 'C.UTF-8',
    ...windows.env, XDG_RUNTIME_DIR: '/run/user/0',
  };
  for (const e of [...(site.env ?? []), ...(opts.env ?? [])]) env[e.slice(0, e.indexOf('='))] = e.slice(e.indexOf('=') + 1);
  // bash runs gex-kde-session (the tree's /usr/local/bin), which starts startplasma-x11.
  const proc = sys.spawn(['/usr/bin/bash', '/usr/local/bin/gex-kde-session'], { env, cwd: '/root', uid: 0 });
  progress({ phase: 'boot', boot: { program: '/usr/local/bin/gex-kde-session' } });
  const pump = (s) => s.pipeTo(new WritableStream({ write: (b) => opts.onLog?.(new TextDecoder().decode(b)) })).catch(() => {});
  pump(proc.stdout);
  pump(proc.stderr);

  let up = false;
  const exited = proc.exited.then((r) => {
    const status = r?.code ?? r;
    if (!failed) progress({ phase: 'exited', status });
    return status;
  });
  return {
    exited,
    system: sys,
    ready() {
      if (up) return;
      up = true;
      progress({ phase: 'ready' });
    },
    describe: (o) => windows.describe(o),
    kill() {
      sys.shutdown().catch(() => {});
    },
  };
}
