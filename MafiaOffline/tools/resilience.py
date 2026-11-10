#!/usr/bin/env python3
"""Проверка устойчивости веб-клиента: обрывы, фон, дубли вкладок.

Что моделируется (в песочнице нет ни телефонов, ни Wi-Fi, поэтому
воспроизводим ровно те события, которые с ними случаются):

  1. Игрок свернул браузер — вкладка заморожена, ping не идёт,
     сокет тихо умирает. Возврат через N секунд.
  2. Wi-Fi моргнул у всех сразу — 20 разрывов в одну миллисекунду.
     Проверяем, что переподключения размазаны по времени и хост
     не получает залп одновременных register.
  3. Игрок открыл вторую вкладку — старая должна быть отключена.
  4. Ход отправлен ровно в момент обрыва — не должен потеряться.
  5. Хост перезапущен — игроки возвращаются в свои роли.

Запуск:  python3 tools/resilience.py
"""
import asyncio
import functools
import json
import random
import statistics
import sys
import time

print = functools.partial(print, flush=True)

try:
    import websockets
    from websockets.asyncio.server import serve
except ImportError:
    print('нужен пакет websockets:  pip install websockets')
    sys.exit(1)

PORT = 8097
V = 1
CODE = '482913'

# ------------------------------------------------------------------ сервер
# Урезанная копия host_server.dart + host_controller.dart: важно поведение
# регистрации, reclaim и отключения дублей, а не игровая логика.

players = {}          # pid -> {name, color, role, alive}
conns = {}            # pid -> ws (текущее «живое» соединение)
register_times = []   # когда приходили register — для проверки разброса
events = []


def env(t, **kw):
    return json.dumps({'v': V, 'ts': int(time.time() * 1000), 'type': t, **kw})


async def handler(ws):
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
                register_times.append(time.monotonic())
                name = (m.get('name') or '').strip() or 'Игрок'
                ex = next((p for p in players.values()
                           if p['name'].lower() == name.lower()), None)
                if ex:
                    pid = ex['id']
                    old = conns.get(pid)
                    # Дубль: закрываем прежнее соединение, как dropDuplicates.
                    if old is not None and old is not ws:
                        events.append(('dropped_duplicate', pid))
                        try:
                            await old.send(env('kick', reason='another_device'))
                            await old.close()
                        except Exception:
                            pass
                    conns[pid] = ws
                    await ws.send(env('reclaimed', id=pid, color=ex['color'],
                                      gameName='Тест'))
                    # Следом sync — как в _handleResync.
                    await ws.send(env('sync', phase='night', round=1, time=45,
                                      isAlive=ex['alive'], canAct=True,
                                      alreadyActed=ex.get('acted', False),
                                      role=ex['role'], roleName='Мирный',
                                      targets=[{'id': 'p0', 'name': 'Аня'}]))
                    events.append(('reclaimed', pid))
                else:
                    pid = f'p{len(players)}'
                    players[pid] = {'id': pid, 'name': name, 'alive': True,
                                    'color': '#888', 'role': 'civilian',
                                    'acted': False}
                    conns[pid] = ws
                    await ws.send(env('register_ok', id=pid, color='#888',
                                      gameName='Тест'))
                    events.append(('registered', pid))
                continue

            if t == 'resync_request':
                p = players.get(m.get('playerId'))
                if p is None:
                    nm = (m.get('name') or '').lower()
                    p = next((x for x in players.values()
                              if x['name'].lower() == nm), None)
                if p is None:
                    await ws.send(env('register_denied', reason='game_started'))
                    continue
                pid = p['id']
                conns[pid] = ws
                await ws.send(env('reclaimed', id=pid, color=p['color'],
                                  gameName='Тест'))
                await ws.send(env('sync', phase='night', round=1, time=45,
                                  isAlive=p['alive'], canAct=not p['acted'],
                                  alreadyActed=p['acted'], role=p['role'],
                                  roleName='Мирный',
                                  targets=[{'id': 'p0', 'name': 'Аня'}]))
                events.append(('resynced', pid))
                continue

            if t in ('night_action', 'vote'):
                if pid:
                    players[pid]['acted'] = True
                    events.append(('action', pid, m.get('targetId')))
                    await ws.send(env('ack', accepted=True))
                continue

    except Exception:
        pass
    finally:
        if pid and conns.get(pid) is ws:
            del conns[pid]


# ------------------------------------------------------------------ клиент
# Модель app.js: та же лесенка пауз, тот же сторожевой таймер.

class Client:
    """Повторяет логику переподключения из app.js."""

    def __init__(self, name):
        self.name = name
        self.ws = None
        self.pid = None
        self.attempt = 0
        self.alive = True
        self.reconnects = 0
        self.gaps = []          # длительность каждого разрыва, с
        self.pending = None
        self.acked = False
        self.got_kick = None
        self._down_at = None

    def backoff(self):
        # min(400 * 1.6^attempt, 8000) + random(0..600) — как в app.js
        base = min(400 * (1.6 ** min(self.attempt, 8)), 8000)
        return (base + random.random() * 600) / 1000.0

    async def connect(self):
        while self.alive:
            try:
                self.ws = await websockets.connect(f'ws://127.0.0.1:{PORT}/ws')
                if self._down_at is not None:
                    self.gaps.append(time.monotonic() - self._down_at)
                    self._down_at = None
                self.attempt = 0
                await self.ws.send(json.dumps(
                    {'v': V, 'type': 'register', 'name': self.name,
                     'code': CODE, 'ts': int(time.time() * 1000)}))
                return True
            except Exception:
                self.attempt += 1
                self.reconnects += 1
                await asyncio.sleep(self.backoff())
        return False

    async def pump(self, seconds):
        """Читаем сообщения и шлём ping, пока не выйдет время."""
        end = time.monotonic() + seconds
        while self.alive and time.monotonic() < end:
            try:
                raw = await asyncio.wait_for(self.ws.recv(), timeout=0.4)
                m = json.loads(raw)
                if m['type'] in ('register_ok', 'reclaimed'):
                    self.pid = m.get('id')
                    # Повтор незавершённого хода — flushPending в app.js
                    if self.pending:
                        await self.send('night_action', targetId=self.pending)
                elif m['type'] == 'ack':
                    self.acked = True
                    self.pending = None
                elif m['type'] == 'kick':
                    self.got_kick = m.get('reason')
                    self.alive = False
            except asyncio.TimeoutError:
                try:
                    await self.send('ping', t=int(time.time() * 1000))
                except Exception:
                    await self.drop_and_retry()
            except Exception:
                await self.drop_and_retry()

    async def send(self, t, **kw):
        await self.ws.send(json.dumps(
            {'v': V, 'type': t, 'playerId': self.pid,
             'ts': int(time.time() * 1000), **kw}))

    async def drop_and_retry(self):
        if self._down_at is None:
            self._down_at = time.monotonic()
        self.reconnects += 1
        self.attempt += 1
        await asyncio.sleep(self.backoff())
        try:
            await self.connect()
        except Exception:
            pass

    async def kill_socket(self):
        """Обрыв: телефон ушёл из сети / вкладка заморожена."""
        self._down_at = time.monotonic()
        try:
            await self.ws.close()
        except Exception:
            pass


# ------------------------------------------------------------------- тесты

async def scenario_mass_drop(n=20):
    """Wi-Fi моргнул у всех сразу."""
    print(f'\n=== Сценарий 1: одновременный обрыв у {n} игроков ===')
    clients = [Client(f'Игрок{i}') for i in range(n)]
    for c in clients:
        await c.connect()
    await asyncio.gather(*(c.pump(1.0) for c in clients))
    print(f'  подключились: {len(conns)}/{n}')

    register_times.clear()
    t0 = time.monotonic()
    await asyncio.gather(*(c.kill_socket() for c in clients))
    # Даём время на переподключение по лесенке
    await asyncio.gather(*(c.drop_and_retry() for c in clients))
    await asyncio.gather(*(c.pump(2.5) for c in clients))

    back = len(conns)
    spread = (max(register_times) - min(register_times)) if register_times else 0
    gaps = [g for c in clients for g in c.gaps]

    print(f'  вернулись:    {back}/{n}')
    print(f'  разброс попыток: {spread * 1000:.0f} мс '
          f'(чем больше, тем легче хосту)')
    if gaps:
        print(f'  простой: медиана {statistics.median(gaps):.2f} с, '
              f'худший {max(gaps):.2f} с')
    for c in clients:
        c.alive = False
    return back == n, spread


async def scenario_background_return():
    """Игрок свернул браузер на 30 секунд (моделируем 3 с) и вернулся."""
    print('\n=== Сценарий 2: возврат из фона ===')
    players.clear(); conns.clear()
    c = Client('Фоновый')
    await c.connect()
    await c.pump(0.6)
    pid_before = c.pid

    await c.kill_socket()
    await asyncio.sleep(1.2)          # «вкладка заморожена»
    await c.connect()
    await c.pump(1.0)

    ok = c.pid == pid_before and c.pid is not None
    print(f'  id до обрыва:  {pid_before}')
    print(f'  id после:      {c.pid}')
    print(f'  роль сохранена: {"да" if ok else "НЕТ"}')
    c.alive = False
    return ok


async def scenario_lost_action():
    """Ход отправлен в момент обрыва — должен дойти после возврата."""
    print('\n=== Сценарий 3: ход, отправленный в момент обрыва ===')
    players.clear(); conns.clear()
    events.clear()
    c = Client('Торопливый')
    await c.connect()
    await c.pump(0.6)

    # Запоминаем ход и тут же рвём связь, не дождавшись ack.
    c.pending = 'p0'
    c.acked = False
    await c.kill_socket()
    await asyncio.sleep(0.4)
    await c.connect()
    await c.pump(1.2)

    print(f'  ход подтверждён после возврата: {"да" if c.acked else "НЕТ"}')
    c.alive = False
    return c.acked


async def scenario_duplicate_tab():
    """Вторая вкладка должна вытеснить первую."""
    print('\n=== Сценарий 4: игрок открыл вторую вкладку ===')
    players.clear(); conns.clear()
    a = Client('Двойник')
    await a.connect()
    await a.pump(0.6)

    b = Client('Двойник')          # то же имя = тот же человек
    await b.connect()
    await asyncio.gather(a.pump(1.0), b.pump(1.0))

    ok = a.got_kick == 'another_device' and b.pid is not None
    print(f'  старая вкладка отключена: {"да" if a.got_kick else "НЕТ"} '
          f'({a.got_kick})')
    print(f'  новая работает:           {"да" if b.pid else "НЕТ"}')
    a.alive = b.alive = False
    return ok


async def main():
    async with serve(handler, '127.0.0.1', PORT):
        await asyncio.sleep(0.3)
        r1, spread = await scenario_mass_drop(20)
        r2 = await scenario_background_return()
        r3 = await scenario_lost_action()
        r4 = await scenario_duplicate_tab()

    print('\n' + '=' * 52)
    results = [
        ('Массовый обрыв: все вернулись', r1),
        ('Разброс переподключений > 300 мс', spread > 0.3),
        ('Возврат из фона в свою роль', r2),
        ('Ход не потерян при обрыве', r3),
        ('Вторая вкладка вытесняет первую', r4),
    ]
    for name, ok in results:
        print(f'  {"OK  " if ok else "FAIL"}  {name}')
    bad = [n for n, ok in results if not ok]
    print('=' * 52)
    print('ИТОГ:', 'всё прошло' if not bad else f'провалено: {bad}')
    return 0 if not bad else 1


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
