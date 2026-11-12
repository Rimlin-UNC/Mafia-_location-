#!/usr/bin/env python3
"""Проверка раздачи статики: gzip, ETag, 304, подстановка кода.

Повторяет логику _serveStatic из host_server.dart на Python, чтобы
убедиться в правильности заголовков без сборки APK. Реальный сервер
написан на dart:io, но правила у них одни и те же.

Запуск:  python3 tools/serve_test.py
"""
import functools
import gzip
import http.server
import json
import pathlib
import socketserver
import sys
import threading
import time
import urllib.parse
import urllib.request

print = functools.partial(print, flush=True)

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'assets'
PORT = 8111
CODE = '482913'
VERSION = 'v5'

ROUTES = {
    '/': 'web/index.html',
    '/index.html': 'web/index.html',
    '/style.css': 'web/style.css',
    '/app.js': 'web/app.js',
    '/manifest.webmanifest': 'web/manifest.webmanifest',
    '/sw.js': 'web/sw.js',
}

# Те же подмены, что в WebAssets.resolve
LIGHT_AMBIENTS = {'night_ambient.wav', 'day_ambient.wav', 'vote_ambient.wav'}

COMPRESSIBLE = ('.html', '.css', '.js', '.webmanifest')


def resolve(path):
    if '..' in path:
        return None
    if path in ROUTES:
        return ROOT / ROUTES[path]
    for pref, d in (('/cards/', 'cards'), ('/sounds/', 'sounds'),
                    ('/images/', 'images'), ('/crimes/', 'crimes'),
                    ('/story/', 'story'), ('/court/', 'court'),
                    ('/instructions/', 'instructions')):
        if path.startswith(pref):
            name = path[len(pref):]
            if not name:
                return None
            if pref == '/sounds/' and name in LIGHT_AMBIENTS:
                return ROOT / 'sounds/web' / name
            # Облегчённые копии 560x840 — как в WebAssets._webDirs.
            if pref in ('/cards/', '/crimes/', '/instructions/') \
                    and name.endswith('.jpg'):
                if '..' in name:
                    return None
                return ROOT / d / 'web' / name
            if '/' in name:
                return None
            return ROOT / d / name
    return None


def ctype_for(p):
    return {
        '.html': 'text/html; charset=utf-8',
        '.css': 'text/css; charset=utf-8',
        '.js': 'application/javascript; charset=utf-8',
        '.webmanifest': 'application/manifest+json',
        '.jpg': 'image/jpeg', '.png': 'image/png',
        '.wav': 'audio/wav', '.ogg': 'audio/ogg',
    }.get(p.suffix, 'application/octet-stream')


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split('?')[0]

        if path == '/ping':
            self._plain(200, b'ok')
            return

        f = resolve(path)
        if f is None:
            self.send_response(302)
            self.send_header('Location', '/')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if not f.exists():
            self._plain(404, b'404')
            return

        body = f.read_bytes()
        is_html = path == '/' or path.endswith('.html')

        if is_html:
            boot = json.dumps({'code': CODE, 'v': VERSION})
            body = body.replace(
                b'<script src="/app.js"></script>',
                f'<script>window.__MAFIA__={boot};</script>\n'
                f'<script src="/app.js?{VERSION}"></script>'.encode())

        etag = f'"{VERSION}-{len(body):x}"'

        if not is_html and self.headers.get('If-None-Match') == etag:
            self.send_response(304)
            self.send_header('ETag', etag)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return

        encoded = False
        if (f.suffix in COMPRESSIBLE or is_html) and \
                'gzip' in (self.headers.get('Accept-Encoding') or ''):
            packed = gzip.compress(body, 9)
            if len(packed) < len(body):
                body, encoded = packed, True

        self.send_response(200)
        self.send_header('Content-Type', ctype_for(f))
        self.send_header('Cache-Control',
                         'no-store' if is_html
                         else 'public, max-age=604800, immutable')
        self.send_header('X-Content-Type-Options', 'nosniff')
        if not is_html:
            self.send_header('ETag', etag)
        if encoded:
            self.send_header('Content-Encoding', 'gzip')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _plain(self, code, body):
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def get(path, headers=None):
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}{path}',
                                 headers=headers or {})
    try:
        r = urllib.request.urlopen(req)
        return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def main():
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    srv = socketserver.ThreadingTCPServer(('127.0.0.1', PORT), Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    time.sleep(0.3)

    checks = []

    # 1. Страница отдаётся и содержит код партии
    st, h, b = get('/', {'Accept-Encoding': 'gzip'})
    text = gzip.decompress(b) if h.get('Content-Encoding') == 'gzip' else b
    checks.append(('страница отдаётся', st == 200))
    checks.append(('код партии подставлен', CODE.encode() in text))
    checks.append(('страница сжата gzip', h.get('Content-Encoding') == 'gzip'))
    checks.append(('страница не кешируется', h.get('Cache-Control') == 'no-store'))
    print(f'  index.html: {len(b)} б по сети, {len(text)} б после распаковки '
          f'(экономия {100 - len(b) * 100 // len(text)}%)')

    # 2. Скрипт сжимается
    st, h, b = get('/app.js', {'Accept-Encoding': 'gzip'})
    raw = (ROOT / 'web/app.js').stat().st_size
    checks.append(('app.js сжат', h.get('Content-Encoding') == 'gzip'))
    checks.append(('app.js кешируется надолго',
                   'max-age=604800' in (h.get('Cache-Control') or '')))
    print(f'  app.js: {raw} б → {len(b)} б '
          f'(экономия {100 - len(b) * 100 // raw}%)')

    # 3. ETag и 304
    st, h, b = get('/cards/mafia.jpg')
    etag = h.get('ETag')
    checks.append(('у картинки есть ETag', bool(etag)))
    st2, h2, b2 = get('/cards/mafia.jpg', {'If-None-Match': etag})
    checks.append(('повторный запрос даёт 304', st2 == 304))
    checks.append(('304 без тела', len(b2) == 0))
    print(f'  карта: первый заход {len(b)} б, повторный {len(b2)} б (304)')

    # 4. Подмена на облегчённые версии
    st, h, b = get('/cards/card_back.jpg')
    orig = (ROOT / 'cards/card_back.jpg').stat().st_size
    checks.append(('рубашка отдаётся облегчённой', len(b) < orig))
    print(f'  рубашка: оригинал {orig // 1024} КБ → отдано {len(b) // 1024} КБ')

    st, h, b = get('/sounds/night_ambient.wav')
    orig = (ROOT / 'sounds/night_ambient.wav').stat().st_size
    checks.append(('фоновый луп облегчён', len(b) < orig))
    print(f'  луп ночи: оригинал {orig // 1024} КБ → отдано {len(b) // 1024} КБ')

    # 5. Мелкий звук не трогаем
    st, h, b = get('/sounds/tap.ogg')
    checks.append(('короткий звук отдаётся', st == 200))

    # 6. Неизвестный путь ведёт на главную, а не в 404.
    #    Кириллицу в адресе браузер шлёт в процентной кодировке — так и тут.
    st, h, b = get('/' + urllib.parse.quote('какая-то-ерунда'))
    checks.append(('неизвестный путь → редирект на игру', st == 200))

    # 4б. Карточки правил для браузера: те же пути, что в WebAssets.
    #     Игрок открывает «Правила и роли» после согласия с офертой — без
    #     этих файлов книга правил осталась бы текстом без картинок.
    for path, orig_rel in (
            ('/instructions/roles/01_mafia.jpg', 'instructions/roles/01_mafia.jpg'),
            ('/instructions/phases/01_night.jpg', 'instructions/phases/01_night.jpg'),
            ('/instructions/guides/01_host.jpg', 'instructions/guides/01_host.jpg'),
            ('/crimes/01_shooting.jpg', 'crimes/01_shooting.jpg')):
        st, h, b = get(path)
        orig = (ROOT / orig_rel).stat().st_size
        checks.append((f'{path} отдаётся', st == 200 and len(b) > 1000))
        checks.append((f'{path} облегчён ({orig // 1024} → {len(b) // 1024} КБ)',
                       len(b) < orig))

    # Вложенность допустима только для разрешённых папок: выход за каталог
    # по-прежнему закрыт.
    st, h, b = get('/instructions/../lib/main.dart')
    checks.append(('обход каталога карточек не проходит',
                   b'material' not in b and b'runApp' not in b))

    # 7. Защита от выхода за каталог
    st, h, b = get('/cards/..%2f..%2fpubspec.yaml')
    checks.append(('обход каталога не проходит', st in (200, 302, 404)
                   and b'sqflite' not in b))

    # 8. Живость
    st, h, b = get('/ping')
    checks.append(('/ping отвечает', st == 200 and b == b'ok'))

    # 9. Полный объём первой загрузки
    total = 0
    for p in ['/', '/style.css', '/app.js', '/manifest.webmanifest', '/sw.js',
              '/cards/card_back.jpg', '/cards/civilian.jpg',
              '/sounds/night_ambient.wav', '/sounds/day_ambient.wav',
              '/sounds/vote_ambient.wav', '/images/bg_night.jpg',
              # Книга правил в браузере: без них первый же открытый раздел
              # «Роли» останется без картинок.
              '/instructions/roles/01_mafia.jpg',
              '/instructions/phases/01_night.jpg']:
        _, _, bb = get(p, {'Accept-Encoding': 'gzip'})
        total += len(bb)
    print(f'\n  Первая загрузка игрока: {total / 1024 / 1024:.2f} МБ')
    print(f'  На 20 игроков:          {total * 20 / 1024 / 1024:.0f} МБ')
    checks.append(('загрузка игрока меньше 3 МБ', total < 3 * 1024 * 1024))

    srv.shutdown()

    print('\n' + '=' * 52)
    bad = []
    for name, ok in checks:
        print(f'  {"OK  " if ok else "FAIL"}  {name}')
        if not ok:
            bad.append(name)
    print('=' * 52)
    print('ИТОГ:', 'всё прошло' if not bad else f'провалено: {bad}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
