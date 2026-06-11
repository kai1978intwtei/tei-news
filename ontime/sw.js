/* OnTime service worker — offline app shell + push reminders */
const CACHE = 'ontime-v1';
const SHELL = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon.svg'
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  // network-first for navigation, cache-first for shell assets
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).catch(() => caches.match('./index.html')));
    return;
  }
  e.respondWith(caches.match(req).then((hit) => hit || fetch(req)));
});

/* Local reminder relay: the page posts a message; the SW shows the notification.
   This lets reminders fire even when the tab is backgrounded. */
self.addEventListener('message', (e) => {
  const d = e.data || {};
  if (d.type === 'reminder') {
    self.registration.showNotification(d.title || 'OnTime 提醒', {
      body: d.body || '',
      icon: './icon.svg',
      badge: './icon.svg',
      tag: d.tag || 'ontime-reminder',
      data: { url: d.url || './' }
    });
  }
});

/* Web Push (server-driven) — requires VAPID + Supabase Edge Function, see README */
self.addEventListener('push', (e) => {
  let payload = {};
  try { payload = e.data ? e.data.json() : {}; } catch (_) { payload = { body: e.data && e.data.text() }; }
  e.waitUntil(
    self.registration.showNotification(payload.title || 'OnTime', {
      body: payload.body || '',
      icon: './icon.svg',
      badge: './icon.svg',
      data: { url: payload.url || './' }
    })
  );
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((cs) => {
      for (const c of cs) { if ('focus' in c) { c.navigate(url); return c.focus(); } }
      return self.clients.openWindow(url);
    })
  );
});
