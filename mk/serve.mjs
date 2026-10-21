// A static server for a gex-debian site (make kde-serve): isolation
// headers, 404 for a missing file (the runtime asks for units that may not
// be there).
//   node serve.mjs ROOT PORT [HOST] [--tls]   (--tls: TLS_DIR's key.pem and cert.pem)
// With --tls it speaks HTTP/2 (HTTP/1.1 still accepted): a page's Workers make many small sync
// requests, which queued on HTTP/1.1's six connections behind multi-MB downloads.
// Range requests are honoured (a cold cluster is a slice of cold.bin, not the whole file),
// and every response carries an ETag, so a revalidation is a 304, not the file again.
import http from 'node:http'; import http2 from 'node:http2'; import fs from 'node:fs'; import path from 'node:path';
const av = process.argv.slice(2); const tls = av.includes('--tls');
const [dist, port = '8000', host = '127.0.0.1'] = av.filter((a) => a !== '--tls');
const root = path.resolve(dist);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
  '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.tar': 'application/x-tar' };
const handler = (req, res) => {
  let p = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!p.startsWith(root)) { res.writeHead(403).end(); return; }
  if (p.endsWith('/')) p = path.join(p, 'index.html');
  let st = null; try { st = fs.statSync(p); } catch {}
  if (st?.isDirectory()) { p = path.join(p, 'index.html'); try { st = fs.statSync(p); } catch { st = null; } }
  const h = { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp', 'Cross-Origin-Resource-Policy': 'same-origin' };
  if (!st?.isFile()) { res.writeHead(404, h).end(); return; }
  const etag = `"${st.size.toString(36)}-${Math.floor(st.mtimeMs).toString(36)}"`;
  const immutable = p.endsWith('.zst') || p.includes('/assets/');
  Object.assign(h, { 'Content-Type': types[path.extname(p)] || 'application/octet-stream', 'ETag': etag,
    'Last-Modified': st.mtime.toUTCString(), 'Accept-Ranges': 'bytes',
    'Cache-Control': immutable ? 'public, max-age=31536000, immutable' : 'no-cache' });
  if (req.headers['if-none-match'] === etag) { res.writeHead(304, h).end(); return; }
  let start = 0, end = st.size - 1, status = 200;
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
  if (m && (!req.headers['if-range'] || req.headers['if-range'] === etag)) {
    if (m[1] === '') { start = Math.max(0, st.size - Number(m[2])); } else { start = Number(m[1]); if (m[2] !== '') end = Math.min(end, Number(m[2])); }
    if (start > end || start >= st.size) { res.writeHead(416, { ...h, 'Content-Range': `bytes */${st.size}` }).end(); return; }
    status = 206; h['Content-Range'] = `bytes ${start}-${end}/${st.size}`;
  }
  h['Content-Length'] = end - start + 1;
  res.writeHead(status, h);
  if (req.method === 'HEAD' || st.size === 0) { res.end(); return; }
  fs.createReadStream(p, { start, end }).pipe(res);
};
const D = process.env.TLS_DIR || '.';
const srv = tls
  ? http2.createSecureServer({ key: fs.readFileSync(path.join(D, 'key.pem')), cert: fs.readFileSync(path.join(D, 'cert.pem')), allowHTTP1: true }, handler)
  : http.createServer(handler);
srv.listen(Number(port), host, () => console.log(`${tls ? 'https (h2)' : 'http'}://${host}:${port}/`));
