#!/usr/bin/env python3
"""Эмулирует браузерного игрока: проверяет весь путь через WebSocket."""
import asyncio, json, time
import websockets

URL = 'ws://127.0.0.1:8090/ws'
got, ok, fail = [], 0, 0


def chk(name, cond):
    global ok, fail
    if cond:
        ok += 1; print(f'  ✅ {name}')
    else:
        fail += 1; print(f'  ❌ {name}')


async def player(name, act=True):
    """Один игрок: регистрация, ping, роль, ночное действие."""
    async with websockets.connect(URL) as ws:
        await ws.send(json.dumps({'v': 1, 'ts': int(time.time() * 1000),
                                  'type': 'register', 'name': name, 'code': '482913'}))
        pid, mine = None, []
        t0 = int(time.time() * 1000)
        await ws.send(json.dumps({'v': 1, 'ts': t0, 'type': 'ping', 't': t0}))

        end = time.time() + 44
        while time.time() < end:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=2)
            except asyncio.TimeoutError:
                continue
            m = json.loads(raw)
            mine.append(m['type'])
            got.append(m['type'])

            if m['type'] == 'register_ok':
                pid = m['id']
            elif m['type'] == 'pong':
                rtt = int(time.time() * 1000) - m.get('echo', t0)
                if name == 'Аня':
                    chk(f'pong несёт hostTime и echo (rtt {rtt} мс)',
                        'hostTime' in m and m.get('echo') == t0)
            elif m['type'] == 'role_assign':
                if name == 'Аня':
                    chk('role_assign: роль, название, эмодзи',
                        all(k in m for k in ('role', 'roleName', 'roleEmoji')))
                await ws.send(json.dumps({'v': 1, 'ts': 0, 'type': 'role_ack',
                                          'playerId': pid}))
            elif m['type'] == 'phase' and m.get('canAct') and act:
                tg = m.get('targets') or []
                if tg:
                    await ws.send(json.dumps({
                        'v': 1, 'ts': 0,
                        'type': 'vote' if m['phase'] == 'voting' else 'night_action',
                        'playerId': pid, 'targetId': tg[0]['id']}))
            elif m['type'] == 'game_over':
                break
        return mine


async def main():
    global ok, fail
    results = await asyncio.gather(
        player('Аня'), player('Боря'), player('Вика'), player('Гоша'))

    print()
    chk('все 4 игрока зарегистрированы', got.count('register_ok') == 4)
    chk('лобби разослано всем', got.count('lobby') >= 4)
    chk('роль пришла каждому', got.count('role_assign') == 4)
    chk('фазы разосланы', got.count('phase') >= 8)
    chk('ack на действия получен', 'ack' in got)
    chk('команда звука доставлена', got.count('sound') >= 4)
    chk('итог ночи объявлен', 'night_result' in got)
    chk('игра завершилась', got.count('game_over') == 4)

    # Повторное имя при активной связи должно отклоняться,
    # а при разорванной — возвращать в свой слот (reclaim).
    async with websockets.connect(URL) as ws:
        await ws.send(json.dumps({'v': 1, 'ts': 0, 'type': 'register',
                                  'name': 'Аня', 'code': '482913'}))
        m = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
        chk('возврат в свой слот по имени (reclaim)', m['type'] == 'reclaimed')

    print(f'\n{ok} passed, {fail} failed')

asyncio.run(main())
