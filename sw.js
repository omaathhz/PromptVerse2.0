/* PromptVerse 2.0 — Service Worker de notificações push
   Fica na RAIZ do site (mesmo lugar do acesso.html), como sw.js */

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = { body: event.data ? event.data.text() : '' }; }

  const title = data.title || 'Venda aprovada';
  const options = {
    body: data.body || '',
    icon: data.icon || '/logo.png',   // a logo do seu SaaS
    badge: '/logo.png',
    vibrate: [80, 40, 80],
    data: { url: data.url || '/' }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      for (const c of list) { if ('focus' in c) return c.focus(); }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});
