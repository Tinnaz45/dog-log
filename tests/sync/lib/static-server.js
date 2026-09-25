// Serves the repository root exactly as Vercel does (static files), on 127.0.0.1 (a secure context) so service workers work.
// /__test__/sw?version=v8 switches sw.js to the previous generation for the v8 -> v9 upgrade test.
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../../..');
const V8 = path.resolve(__dirname, '../fixtures/sw-v8.js');
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json', '.png': 'image/png' };

function start(port) {
  let swVersion = 'v9';
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/__test__/sw') { swVersion = url.searchParams.get('version') || 'v9'; res.end(swVersion); return; }
    let rel = decodeURIComponent(url.pathname);
    if (rel === '/') rel = '/index.html';
    const file = rel === '/sw.js' && swVersion === 'v8' ? V8 : path.join(ROOT, rel);
    if (!file.startsWith(ROOT) && file !== V8) { res.writeHead(403); res.end(); return; }
    if (rel.startsWith('/tests/') || rel.startsWith('/.git') || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-cache' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(resolve => server.listen(port, '127.0.0.1', () => resolve({ url: `http://127.0.0.1:${port}`, close: () => new Promise(r => server.close(r)) })));
}

module.exports = { start };
