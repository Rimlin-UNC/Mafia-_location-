/* Service worker веб-клиента «Мафия Offline».
 *
 * Зачем он нужен, если игра и так локальная:
 *
 * 1. Телефон игрока может на секунду потерять Wi-Fi. Без SW перезагрузка
 *    страницы в этот момент даёт «Нет подключения к интернету» и человек
 *    выпадает из партии совсем. С SW страница поднимается из кеша и сама
 *    переподключается к хосту.
 *
 * 2. Карты ролей и звуки (около 5 МБ) скачиваются один раз. При 20 игроках
 *    это экономит телефону ведущего примерно 100 МБ раздачи — на слабой
 *    точке доступа разница между «мгновенно» и «полминуты ожидания».
 *
 * 3. Игру можно добавить на домашний экран, и она откроется без адресной
 *    строки — на iPhone это заметно снижает риск случайного закрытия.
 *
 * Стратегия намеренно разная для разных типов:
 *   - HTML: сначала сеть (нужен свежий код партии), кеш как запасной путь;
 *   - статика: сначала кеш (она неизменна в пределах версии);
 *   - WebSocket и /ping: не трогаем вообще.
 */
'use strict';

const VERSION = 'mafia-v20';
const CORE = ['/', '/style.css', '/app.js', '/manifest.webmanifest',
              '/instructions/guides/01_host.jpg'];

self.addEventListener('install', (e) => {
  // Не ждём закрытия старых вкладок: игрок обновляет страницу и хочет
  // видеть новую версию сразу.
  self.skipWaiting();
  e.waitUntil(
    caches.open(VERSION).then((c) => c.addAll(CORE)).catch(() => {})
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('mafia-') && k !== VERSION).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Чужие адреса и служебные пути не наше дело.
  if (url.origin !== location.origin) return;
  if (url.pathname === '/ping' || url.pathname === '/ws') return;

  const isHtml = req.mode === 'navigate' ||
                 url.pathname === '/' ||
                 url.pathname.endsWith('.html');

  if (isHtml) {
    // Сеть первой: в HTML зашит код текущей партии, устаревший опасен.
    e.respondWith((async () => {
      try {
        const fresh = await fetch(req);
        const c = await caches.open(VERSION);
        c.put('/', fresh.clone()).catch(() => {});
        return fresh;
      } catch (err) {
        // Хост недоступен — отдаём последнюю рабочую страницу.
        // Она сама начнёт стучаться в сокет и вернёт игрока в партию.
        const c = await caches.open(VERSION);
        const cached = await c.match('/');
        return cached || new Response(
          '<meta charset="utf-8"><body style="background:#0e0f14;color:#eee;'
          + 'font:16px system-ui;padding:40px;text-align:center">'
          + '<h2>Нет связи с ведущим</h2>'
          + '<p style="color:#9aa">Проверьте, что вы подключены к его Wi-Fi,'
          + ' и обновите страницу.</p></body>',
          { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
        );
      }
    })());
    return;
  }

  if (!/^\/(cards|instructions|crimes|sounds|images)\//.test(url.pathname) &&
      !['/app.js', '/style.css', '/manifest.webmanifest'].includes(url.pathname)) return;

  // Статика: кеш первым, сеть только при промахе.
  e.respondWith((async () => {
    const c = await caches.open(VERSION);
    const cached = await c.match(req);
    if (cached) return cached;
    try {
      const fresh = await fetch(req);
      if (fresh.ok && fresh.status === 200 && !fresh.redirected &&
          !(fresh.headers.get('Cache-Control') || '').includes('no-store')) {
        const c = await caches.open(VERSION);
        c.put(req, fresh.clone()).catch(() => {});
      }
      return fresh;
    } catch (err) {
      return new Response('', { status: 504 });
    }
  })());
});
