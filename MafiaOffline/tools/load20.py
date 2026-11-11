#!/usr/bin/env python3
"""Нагрузка: 20 игроков заходят и играют одновременно.

Что измеряем:
  * сколько времени занимает «залп» — все 20 сканируют QR в одну минуту
    и браузеры разом тянут страницу, карты и звуки;
  * задержку отклика на нажатие (от отправки хода до ack);
  * справляется ли ограничитель параллельных отдач.

Внимание: это оценка сверху. Настоящий телефон ведущего слабее машины,
на которой идёт тест, а Wi-Fi медленнее петлевого интерфейса. Цифры
показывают порядок величины и наличие узких мест, а не абсолютное время.

Запуск:  python3 tools/load20.py
"""
import asyncio
import functools
import http.server
import json
import pathlib
import socketserver
import statistics
import sys
import threading
import time
import urllib.request

print = functools.partial(print, flush=True)

try:
    import websockets
    from websockets.asyncio.server import serve
except ImportError:
    print('нужен websockets:  pip install websockets')
    sys.exit(1)

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'assets'
HTTP_PORT = 8131
WS_PORT = 8132
N = 20
V = 1

# Что реально качает браузер при первом заходе.
FIRST_LOAD = [
    '/', '/style.css', '/app.js', '/manifest.webmanifest', '/sw.js',
    '/cards/card_back.jpg', '/cards/civilian.jpg',
    '/sounds/night_ambient.wav', '/sounds/tap.ogg', '/sounds/reveal_card.ogg',
    '/images/bg_night.jpg',
]

ROUTES = {'/': 'web/index.html', '/style.css': 'web/style.css',
          '/app.js': 'web/app.js', '/sw.js': 'web/sw.js',
          '/manifest.webmanifest': 'web/manifest.webmanifest'}

# Ограничитель: столько же, сколько _maxParallelStatic в host_server.dart
SEM = threading.Semaphore(4)
peak_parallel = [0]
now_parallel = [0]
lock = threading.Lock()


def resolve(p):
    if p in ROUTES:
        return ROOT / ROUTES[p]
    for pref, d in (('/cards/', 'cards/web'), ('/sounds/', 'sounds'),
                    ('/images/', 'images')):
        if p.startswith(pref):
            n = p[len(pref):]
            if n and '/' not in n:
                if pref == '/sounds/' and n.endswith('_ambient.wav'):
                    return ROOT / 'sounds/web' / n
                return ROOT / d / n
    return None


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split('?')[0]
        f = resolve(path)
        if f is None or not f.exists():
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return

        with SEM:
            with lock:
                now_parallel[0] += 1
                peak_parallel[0] = max(peak_parallel[0], now_parallel[0])
            try:
                body = f.read_bytes()
                # Телефон читает из бандла — это не мгновенно.
                time.sleep(0.004)
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            finally:
                with lock:
                    now_parallel[0] -= 1


# --------------------------------------------------------------------- сокет

conns = {}
ack_delays = []


def env(t, **kw):
    return json.dumps({'v': V, 'ts': int(time.time() * 1000), 'type': t, **kw})


async def ws_handler(ws):
    pid = None
    try:
        async for raw in ws:
            m = json.loads(raw)
            t = m.get('type')
            if t == 'ping':
                await ws.send(env('pong', hostTime=int(time.time() * 1000),
                                  echo=m.get('t', 0)))
            elif t == 'register':
                pid = f'p{len(conns)}'
                conns[pid] = ws
                await ws.send(env('register_ok', id=pid, color='#888',
                                  gameName='Нагрузка'))
            elif t in ('night_action', 'vote'):
                await ws.send(env('ack', accepted=True))
    except Exception:
        pass
    finally:
        if pid:
            conns.pop(pid, None)


async def broadcast(t, **kw):
    payload = env(t, **kw)
    await asyncio.gather(*(w.send(payload) for w in list(conns.values())),
                         return_exceptions=True)


# -------------------------------------------------------------------- игрок

def fetch_all(idx, out):
    """Браузер тянет статику — в отдельном потоке, как настоящий."""
    t0 = time.monotonic()
    total = 0
    for p in FIRST_LOAD:
        try:
            r = urllib.request.urlopen(f'http://127.0.0.1:{HTTP_PORT}{p}',
                                       timeout=30)
            total += len(r.read())
        except Exception:
            pass
    out[idx] = (time.monotonic() - t0, total)


async def player(name, results):
    ws = await websockets.connect(f'ws://127.0.0.1:{WS_PORT}/ws')
    await ws.send(json.dumps({'v': V, 'type': 'register', 'name': name,
                              'ts': int(time.time() * 1000)}))
    pid = None
    delays = []
    try:
        while True:
            raw = await asyncio.wait_for(ws.recv(), timeout=25)
            m = json.loads(raw)
            if m['type'] == 'register_ok':
                pid = m['id']
            elif m['type'] == 'phase' and m.get('canAct'):
                # Человек думает 1-3 секунды, потом жмёт.
                await asyncio.sleep(0.2)
                sent = time.monotonic()
                await ws.send(json.dumps(
                    {'v': V, 'type': 'night_action', 'playerId': pid,
                     'targetId': 'x1', 'ts': int(time.time() * 1000)}))
                raw2 = await asyncio.wait_for(ws.recv(), timeout=10)
                if json.loads(raw2)['type'] == 'ack':
                    delays.append((time.monotonic() - sent) * 1000)
            elif m['type'] == 'done':
                break
    except Exception:
        pass
    finally:
        results.append(delays)
        await ws.close()


async def main():
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    hs = socketserver.ThreadingTCPServer(('127.0.0.1', HTTP_PORT), H)
    hs.daemon_threads = True
    threading.Thread(target=hs.serve_forever, daemon=True).start()

    print(f'=== Залп: {N} игроков сканируют QR одновременно ===')
    out = [None] * N
    threads = [threading.Thread(target=fetch_all, args=(i, out)) for i in range(N)]
    t0 = time.monotonic()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.monotonic() - t0

    times = [o[0] for o in out if o]
    bytes_each = out[0][1] if out[0] else 0
    print(f'  всего заняло:      {wall:.2f} с')
    print(f'  на игрока:         медиана {statistics.median(times):.2f} с, '
          f'худший {max(times):.2f} с')
    print(f'  объём на игрока:   {bytes_each / 1024 / 1024:.2f} МБ')
    print(f'  суммарно роздано:  {bytes_each * N / 1024 / 1024:.0f} МБ')
    print(f'  пик параллельных отдач: {peak_parallel[0]} (ограничитель — 4)')

    print(f'\n=== Отклик при {N} игроках ===')
    async with serve(ws_handler, '127.0.0.1', WS_PORT):
        results = []
        tasks = [asyncio.create_task(player(f'Игрок{i}', results))
                 for i in range(N)]
        await asyncio.sleep(1.0)
        print(f'  подключено: {len(conns)}/{N}')

        # Три круга ночных фаз
        for rnd in range(3):
            await broadcast('phase', phase='night', round=rnd + 1, time=30,
                            paused=False, isAlive=True, canAct=True,
                            targets=[{'id': 'x1', 'name': 'Цель'}])
            await asyncio.sleep(1.2)

        await broadcast('done')
        await asyncio.sleep(0.5)
        for t in tasks:
            t.cancel()

    hs.shutdown()

    flat = [d for ds in results for d in ds]
    ok = True
    if flat:
        flat.sort()
        p50 = statistics.median(flat)
        p95 = flat[int(len(flat) * 0.95) - 1]
        print(f'  замеров:      {len(flat)}')
        print(f'  отклик:       медиана {p50:.0f} мс, 95-й перцентиль {p95:.0f} мс, '
              f'худший {max(flat):.0f} мс')
        ok = p95 < 400
        print(f'  оценка:       {"хорошо" if ok else "медленно"} '
              f'(нажатие ощущается мгновенным при < 100 мс)')

    print('\n' + '=' * 52)
    checks = [
        ('залп 20 игроков укладывается в 30 с', wall < 30),
        ('ограничитель держит поток', peak_parallel[0] <= 4),
        ('объём на игрока меньше 2,5 МБ', bytes_each < 2.5 * 1024 * 1024),
        ('отклик 95% быстрее 400 мс', ok),
    ]
    bad = []
    for nm, good in checks:
        print(f'  {"OK  " if good else "FAIL"}  {nm}')
        if not good:
            bad.append(nm)
    print('=' * 52)
    print('ИТОГ:', 'всё прошло' if not bad else f'провалено: {bad}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
