const CACHE = 'dog-log-v10';
// The vendored library is version-named: a new version gets a new URL, and any change to a precached
// non-HTML asset must also bump CACHE.
const ASSETS = ['/', '/index.html', '/manifest.json', '/vendor/supabase-js-2.116.0.min.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS.map(u => new Request(u, { cache: 'reload' })))));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ));
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Cloud sync (Supabase REST/RPC/Auth), the Apps Script calendar bridge, any other origin and every non-GET
  // request go straight to the network: never answered from, or written to, Cache Storage.
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return;
  // Icons always come from the network so a stale cache can never substitute an old icon.
  if (url.pathname.endsWith('.png')) return;
  // Pages are network-first so new HTML (and its icon declarations) is seen immediately; cache is the offline fallback.
  if (e.request.mode === 'navigate') {
    e.respondWith(
      fetch(e.request).then(r => {
        if (r.ok) {
          const copy = r.clone();
          caches.open(CACHE).then(c => c.put('/index.html', copy));
        }
        return r;
      }).catch(() => caches.match('/index.html'))
    );
    return;
  }
  e.respondWith(
    caches.match(e.request).then(r => r || fetch(e.request).catch(() => caches.match('/index.html')))
  );
});
