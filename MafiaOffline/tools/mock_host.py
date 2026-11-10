#!/usr/bin/env python3
"""Эмулятор ведущего для проверки веб-клиента.

Повторяет протокол Dart-сервера (host_server.dart + host_controller.dart):
раздаёт ту же статику и говорит теми же пакетами. Нужен только для тестов —
в реальной игре сервер работает внутри Android-приложения.
"""
import asyncio, functools, json, mimetypes, pathlib, sys, time
print = functools.partial(print, flush=True)
from http import HTTPStatus

import websockets
from websockets.asyncio.server import serve

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'assets'
WEB, PORT, V = ROOT / 'web', 8090, 1
CODE = '482913'

ROUTES = {'/': 'index.html', '/index.html': 'index.html',
          '/style.css': 'style.css', '/app.js': 'app.js'}
DIRS = {'/cards/': ROOT / 'cards', '/sounds/': ROOT / 'sounds',
        '/images/': ROOT / 'images'}

players, conns = {}, {}
state = {'phase': 'waiting', 'round': 0, 'time': 0}
COLORS = ['#FF5733', '#33FF57', '#3357FF', '#FF33A1', '#FFD733', '#33FFF5']
log = []


def env(t, **kw):
    return json.dumps({'v': V, 'ts': int(time.time() * 1000), 'type': t, **kw})


async def send(pid, t, **kw):
    ws = conns.get(pid)
    if ws:
        try:
            await ws.send(env(t, **kw))
        except Exception:
            pass


async def broadcast(t, **kw):
    for pid in list(conns):
        await send(pid, t, **kw)


async def push_lobby():
    await broadcast('lobby', gameName='Тестовая партия', planned=6,
                    players=[{'id': p['id'], 'name': p['name'], 'color': p['color'],
                              'isAlive': p['alive'], 'isConnected': True}
                             for p in players.values()])


def http_handler(connection, request):
    """Раздача статики — точный аналог _serveStatic в Dart."""
    path = request.path.split('?')[0]
    if path == '/ws':
        return None  # апгрейд до WebSocket

    body, ctype = None, 'application/octet-stream'
    if path in ROUTES:
        f = WEB / ROUTES[path]
        if f.exists():
            body = f.read_bytes()
            ctype = mimetypes.guess_type(f.name)[0] or 'text/html'
            if f.suffix == '.html':
                boot = json.dumps({'code': CODE})
                body = body.replace(
                    b'<script src="/app.js"></script>',
                    f'<script>window.__MAFIA__={boot};</script>\n'
                    '<script src="/app.js"></script>'.encode())
    else:
        for pref, d in DIRS.items():
            if path.startswith(pref):
                name = path[len(pref):]
                f = d / name
                if '/' not in name and f.exists():
                    body = f.read_bytes()
                    ctype = mimetypes.guess_type(f.name)[0] or 'application/octet-stream'
                break

    if body is None:
        return connection.respond(HTTPStatus.NOT_FOUND, '404\n')

    # respond() принимает только текст, поэтому бинарный ответ
    # (картинки, звуки) собираем вручную.
    from websockets.http11 import Response
    from websockets.datastructures import Headers
    if 'text' in ctype or 'javascript' in ctype:
        ctype += '; charset=utf-8'
    return Response(200, 'OK', Headers({
        'Content-Type': ctype,
        'Content-Length': str(len(body)),
        'Cache-Control': 'no-store',
    }), body)


async def ws_handler(ws):
    pid = None
    try:
        async for raw in ws:
            m = json.loads(raw)
            t = m.get('type')

            if t == 'ping':
                await ws.send(env('pong', hostTime=int(time.time() * 1000),
                                  echo=m.get('t', 0)))
                continue

            if t == 'register':
                name = (m.get('name') or '').strip() or 'Игрок'
                ex = next((p for p in players.values()
                           if p['name'].lower() == name.lower()), None)
                if ex:
                    if ex['id'] in conns:
                        await ws.send(env('register_denied', reason='name_taken'))
                        continue
                    pid = ex['id']; conns[pid] = ws
                    await ws.send(env('reclaimed', id=pid, color=ex['color'],
                                      gameName='Тестовая партия'))
                else:
                    pid = f'p{len(players)}'
                    players[pid] = {'id': pid, 'name': name, 'alive': True,
                                    'color': COLORS[len(players) % len(COLORS)],
                                    'role': None}
                    conns[pid] = ws
                    await ws.send(env('register_ok', id=pid,
                                      color=players[pid]['color'],
                                      gameName='Тестовая партия'))
                    print(f'  + подключился {name} ({pid})')
                await push_lobby()

            elif t == 'role_ack':
                print(f'  ✓ {players[pid]["name"]} подтвердил роль')

            elif t in ('night_action', 'vote'):
                print(f'  → {players[pid]["name"]}: {t} → {m.get("targetId")}')
                await ws.send(env('ack', accepted=True))

            elif t == 'resync_request':
                await send(pid, 'sync', phase=state['phase'], round=state['round'],
                           time=state['time'], isAlive=True, canAct=False,
                           role=players[pid].get('role'))
    except Exception:
        pass
    finally:
        if pid:
            conns.pop(pid, None)
            print(f'  - отключился {pid}')


async def scenario():
    """Прогоняет партию: роли → ночь → день → голосование → финал."""
    while len(players) < 1:
        await asyncio.sleep(0.4)
    await asyncio.sleep(1.5)

    roles = [('mafia', 'Мафия', '🔫'), ('doctor', 'Доктор', '💉'),
             ('commissioner', 'Комиссар', '🔎'), ('civilian', 'Мирный житель', '👤')]
    for i, pid in enumerate(list(players)):
        r = roles[i % len(roles)]
        players[pid]['role'] = r[0]
        await send(pid, 'role_assign', role=r[0], roleName=r[1], roleEmoji=r[2],
                   roleDescription='Тестовое описание роли.',
                   teammates=[{'name': 'Пётр', 'isDon': True}] if r[0] == 'mafia' else [])
    print('→ роли розданы')
    await asyncio.sleep(3)

    # НОЧЬ
    state.update(phase='night', round=1, time=40)
    alive = [{'id': p['id'], 'name': p['name'], 'color': p['color']}
             for p in players.values()]
    ms = int(time.time() * 1000)
    await broadcast('sound', asset='sounds/night_falls.ogg', playAt=ms + 400, volume=1)
    for pid, p in players.items():
        act = p['role'] in ('mafia', 'doctor', 'commissioner')
        await send(pid, 'phase', phase='night', round=1, time=40, paused=False,
                   isAlive=True, canAct=act,
                   targets=[a for a in alive if a['id'] != pid] if act else [],
                   prompt={'mafia': 'Кого убить этой ночью?',
                           'doctor': 'Кого спасти?',
                           'commissioner': 'Кого проверить?'}.get(p['role'], 'Спите'))
    print('→ ночь 1')
    await asyncio.sleep(12)

    # ДЕНЬ
    ms = int(time.time() * 1000)
    await broadcast('sound', asset='sounds/kill.ogg', playAt=ms + 400, volume=1)
    await broadcast('night_result', round=1, killed=['p0'],
                    text='Город просыпается. Этой ночью мы потеряли Анну.')
    state.update(phase='day', time=60)
    for pid in players:
        await send(pid, 'phase', phase='day', round=1, time=60, paused=False,
                   isAlive=True, canAct=False, targets=[], prompt='Обсуждайте')
    print('→ день 1')
    await asyncio.sleep(8)

    # ГОЛОСОВАНИЕ
    state.update(phase='voting', time=30)
    for pid in players:
        await send(pid, 'phase', phase='voting', round=1, time=30, paused=False,
                   isAlive=True, canAct=True,
                   targets=[a for a in alive if a['id'] != pid],
                   prompt='Кого отправляем из города?')
    print('→ голосование')
    await asyncio.sleep(12)

    await broadcast('game_over', winner='civilians', title='Победили мирные жители',
                    reveal=[{'name': p['name'], 'role': p['role'] or '—',
                             'emoji': '👤', 'isAlive': p['alive']}
                            for p in players.values()])
    print('→ финал')


async def main():
    async with serve(ws_handler, '0.0.0.0', PORT, process_request=http_handler):
        print(f'Мок-сервер: http://127.0.0.1:{PORT}/?g={CODE}')
        await scenario()
        await asyncio.sleep(6)
        print('сценарий завершён')

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
