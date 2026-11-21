// Site-served hosts: a guest connection to one of a few named hosts (the
// site's apt repository, http://gex-site/) is answered by the page itself,
// from files under a URL of its own origin, instead of going out over the
// network. The guest speaks plain HTTP/1.1 to it: GET and HEAD, keep-alive
// and pipelined requests, each answered from `fetch` as its body arrives.
// Every other connection goes to the network it wraps (the runtime's
// network interface: `connect(host, port)`, `datagram(host, port)`).

const REASON = { 200: 'OK', 206: 'Partial Content', 304: 'Not Modified', 400: 'Bad Request', 404: 'Not Found', 405: 'Method Not Allowed', 416: 'Range Not Satisfiable', 502: 'Bad Gateway' };
/** What of the guest's request goes on to `fetch`. */
const FORWARD = ['range', 'if-range', 'if-modified-since', 'if-none-match', 'accept'];
/** What of the response comes back. */
const KEEP = ['content-type', 'last-modified', 'etag', 'content-range', 'accept-ranges', 'cache-control'];
const enc = new TextEncoder();

export class SiteHosts {
  #hosts = new Map();
  #inner;

  /** `hosts`: `{ name: base }`, each base a URL (relative ones against
   *  `relativeTo`) whose files the name serves; `inner`: the network for
   *  every other connection, or null. */
  constructor(hosts, relativeTo, inner = null) {
    for (const [name, base] of Object.entries(hosts ?? {})) {
      const u = new URL(String(base), relativeTo);
      if (!u.pathname.endsWith('/')) u.pathname += '/';
      this.#hosts.set(name.toLowerCase(), u.href);
    }
    this.#inner = inner;
  }

  connect(host, port) {
    const base = this.#hosts.get(String(host).toLowerCase());
    if (base) return served(base);
    if (!this.#inner) throw new Error(`${host}:${port}: no network`);
    return this.#inner.connect(host, port);
  }

  datagram(host, port) {
    if (!this.#inner?.datagram) throw new Error(`${host}:${port}: no UDP`);
    return this.#inner.datagram(host, port);
  }
}

/** A connection to a served host, as a Duplex: the guest's requests in,
 *  the answers out. */
function served(base) {
  let out;
  let closed = false;
  let stopped = false;
  let held = new Uint8Array(0);
  let queue = Promise.resolve();
  let reader = null;
  const emit = (bytes) => { if (!closed && bytes.length) out.enqueue(bytes); };
  const end = () => {
    if (closed) return;
    closed = true;
    out.close();
  };
  const head = (status, headers) => {
    const lines = [`HTTP/1.1 ${status} ${REASON[status] ?? ''}`.trimEnd()];
    for (const [k, v] of headers) lines.push(`${k}: ${v}`);
    emit(enc.encode(`${lines.join('\r\n')}\r\n\r\n`));
  };
  const serve = async (req) => {
    if (closed) return;
    if (!((req.method === 'GET' || req.method === 'HEAD') && !req.body && !req.bad && !req.headers.get('upgrade'))) {
      head(req.bad ? 400 : 405, [['Allow', 'GET, HEAD'], ['Content-Length', '0'], ['Connection', 'close']]);
      end();
      return;
    }
    const keep = req.version === 'HTTP/1.1' && !/\bclose\b/i.test(req.headers.get('connection') ?? '');
    const conn = keep ? [] : [['Connection', 'close']];
    // The path, under the base and nowhere above it.
    const url = new URL(req.target.replace(/^[a-z]+:\/\/[^/]*/i, '').replace(/^\/+/, ''), base);
    if (!url.href.startsWith(base)) {
      head(404, [['Content-Length', '0'], ...conn]);
      if (!keep) end();
      return;
    }
    const headers = {};
    for (const h of FORWARD) if (req.headers.has(h)) headers[h] = req.headers.get(h);
    let r;
    try {
      r = await fetch(url.href, { method: req.method, headers });
    } catch {
      head(502, [['Content-Length', '0'], ...conn]);
      if (!keep) end();
      return;
    }
    const kept = [];
    for (const h of KEEP) if (r.headers.get(h) != null) kept.push([h.replace(/(^|-)./g, (c) => c.toUpperCase()), r.headers.get(h)]);
    // The length as served, unless fetch decoded a compressed body (then it
    // is the compressed one's): otherwise chunked.
    const len = r.headers.get('content-encoding') ? null : r.headers.get('content-length');
    const chunked = len == null && req.method === 'GET' && r.status !== 304;
    if (len != null) kept.push(['Content-Length', len]);
    else if (chunked) kept.push(['Transfer-Encoding', 'chunked']);
    else if (req.method !== 'HEAD') kept.push(['Content-Length', '0']);
    head(r.status, [...kept, ...conn]);
    if (req.method === 'GET' && r.body && r.status !== 304) {
      reader = r.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done || closed) break;
        if (!value?.length) continue;
        if (chunked) emit(enc.encode(`${value.length.toString(16)}\r\n`));
        emit(value);
        if (chunked) emit(enc.encode('\r\n'));
      }
      reader = null;
      if (chunked) emit(enc.encode('0\r\n\r\n'));
    } else {
      await r.body?.cancel().catch(() => {});
    }
    if (!keep) end();
  };
  return {
    readable: new ReadableStream({
      start(c) { out = c; },
      cancel() {
        closed = true;
        reader?.cancel().catch(() => {});
      },
    }),
    writable: new WritableStream({
      write(bytes) {
        if (closed || stopped) return;
        const all = new Uint8Array(held.length + bytes.length);
        all.set(held);
        all.set(bytes, held.length);
        held = all;
        // Every whole request head, in order: pipelined ones answered one after another.
        for (;;) {
          const at = headEnd(held);
          if (at < 0) break;
          const req = parse(new TextDecoder().decode(held.subarray(0, at)));
          held = held.subarray(at + 4);
          queue = queue.then(() => serve(req)).catch(() => end());
          // A request with a body is not one this answers (no POST): the
          // connection ends after its 405, so whatever follows is not read.
          if (req.body || req.bad) {
            stopped = true;
            break;
          }
        }
      },
      close() {
        queue.then(() => end());
      },
    }),
  };
}

/** Where the head ends (the index of its blank line's `\r\n\r\n`), or -1. */
function headEnd(b) {
  for (let i = 0; i + 3 < b.length; i++) {
    if (b[i] === 13 && b[i + 1] === 10 && b[i + 2] === 13 && b[i + 3] === 10) return i;
  }
  return -1;
}

function parse(head) {
  const [line, ...rest] = head.split('\r\n');
  const [method, target, version] = line.split(' ');
  const headers = new Map();
  for (const l of rest) {
    const at = l.indexOf(':');
    if (at > 0) headers.set(l.slice(0, at).trim().toLowerCase(), l.slice(at + 1).trim());
  }
  const body = Number(headers.get('content-length') ?? 0) > 0 || headers.has('transfer-encoding');
  return { method, target: target ?? '', version: version ?? '', headers, body, bad: !method || !target || !/^HTTP\/1\.[01]$/.test(version ?? '') };
}
