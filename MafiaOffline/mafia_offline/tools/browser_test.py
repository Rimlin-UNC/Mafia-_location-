#!/usr/bin/env python3
"""Проверка веб-клиента в настоящем браузерном движке (Chromium).

Поднимает эмулятор ведущего и открывает страницу в реальном браузере —
тот же движок, что в Chrome на Android. Проверяется то, что нельзя
проверить чтением кода: реально ли отрисовались экраны, работают ли
нажатия, переживает ли клиент обрыв связи.

Запуск:  python3 tools/browser_test.py
"""
import asyncio
import functools
import gzip
import json
import pathlib
import sys
import threading
import time
import http.server
import socketserver

print = functools.partial(print, flush=True)

try:
    from playwright.async_api import async_playwright
except ImportError:
    print('нужен playwright:  pip install playwright && playwright install chromium')
    sys.exit(1)

try:
    import websockets
    from websockets.asyncio.server import serve
except ImportError:
    print('нужен websockets:  pip install websockets')
    sys.exit(1)

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'assets'
HTTP_PORT = 8121
WS_PORT = 8122
CODE = '482913'
V = 1

# ------------------------------------------------------------- HTTP-статика

ROUTES = {'/': 'web/index.html', '/style.css': 'web/style.css',
          '/app.js': 'web/app.js', '/sw.js': 'web/sw.js',
          '/manifest.webmanifest': 'web/manifest.webmanifest'}


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
        body = f.read_bytes()
        if path == '/':
            boot = json.dumps({'code': CODE, 'v': 'test'})
            body = body.replace(
                b'<script src="/app.js"></script>',
                f'<script>window.__MAFIA__={boot};</script>\n'
                '<script src="/app.js"></script>'.encode())
            # Клиент ходит в /ws на том же хосте, а сокет у нас на другом
            # порту — подменяем адрес только в тесте.
            body = body.replace(
                b'<script src="/app.js">',
                f'<script>window.__WS__="ws://127.0.0.1:{WS_PORT}/ws";</script>'
                '<script src="/app.js">'.encode())
        ct = {'.html': 'text/html; charset=utf-8', '.css': 'text/css',
              '.js': 'application/javascript', '.jpg': 'image/jpeg',
              '.png': 'image/png', '.wav': 'audio/wav', '.ogg': 'audio/ogg',
              '.webmanifest': 'application/manifest+json'}.get(f.suffix, 'text/plain')
        self.send_response(200)
        self.send_header('Content-Type', ct)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ------------------------------------------------------------ WebSocket-хост

players, conns = {}, {}
srv_state = {'phase': 'waiting', 'round': 0, 'kill_next': False}
seen = []


def env(t, **kw):
    return json.dumps({'v': V, 'ts': int(time.time() * 1000), 'type': t, **kw})


async def ws_handler(ws):
    pid = None
    try:
        async for raw in ws:
            m = json.loads(raw)
            t = m.get('type')
            seen.append(t)

            if t == 'ping':
                await ws.send(env('pong', hostTime=int(time.time() * 1000),
                                  echo=m.get('t', 0)))
                continue

            if t == 'register':
                name = (m.get('name') or '').strip() or 'Игрок'
                ex = next((p for p in players.values()
                           if p['name'].lower() == name.lower()), None)
                if ex:
                    pid = ex['id']
                    conns[pid] = ws
                    await ws.send(env('reclaimed', id=pid, color=ex['color'],
                                      gameName='Тестовая партия'))
                    await ws.send(env('sync', phase=srv_state['phase'],
                                      round=srv_state['round'], time=40,
                                      isAlive=True, canAct=True,
                                      alreadyActed=False, role='commissioner',
                                      roleName='Комиссар', roleEmoji='🕵',
                                      prompt='Кого проверить?',
                                      targets=[{'id': 'x1', 'name': 'Борис',
                                                'color': '#3357FF'}]))
                else:
                    pid = f'p{len(players)}'
                    players[pid] = {'id': pid, 'name': name, 'color': '#FF5733'}
                    conns[pid] = ws
                    await ws.send(env('register_ok', id=pid, color='#FF5733',
                                      gameName='Тестовая партия'))
                await ws.send(env('lobby', gameName='Тестовая партия', planned=6,
                                  players=[{'id': p['id'], 'name': p['name'],
                                            'color': p['color'], 'isAlive': True,
                                            'isConnected': True}
                                           for p in players.values()]))
                continue

            if t == 'resync_request':
                await ws.send(env('sync', phase=srv_state['phase'],
                                  round=srv_state['round'], time=40,
                                  isAlive=True, canAct=True, alreadyActed=False,
                                  role='commissioner', roleName='Комиссар',
                                  roleEmoji='🕵', prompt='Кого проверить?',
                                  targets=[{'id': 'x1', 'name': 'Борис',
                                            'color': '#3357FF'}]))
                continue

            if t in ('night_action', 'vote'):
                await ws.send(env('ack', accepted=True))
                continue
    except Exception:
        pass
    finally:
        if pid and conns.get(pid) is ws:
            del conns[pid]


async def push(t, **kw):
    for ws in list(conns.values()):
        try:
            await ws.send(env(t, **kw))
        except Exception:
            pass


# ------------------------------------------------------------------- сценарий

async def main():
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    http_srv = socketserver.ThreadingTCPServer(('127.0.0.1', HTTP_PORT), H)
    http_srv.daemon_threads = True
    threading.Thread(target=http_srv.serve_forever, daemon=True).start()

    checks = []
    console_errors = []

    async with serve(ws_handler, '127.0.0.1', WS_PORT):
        async with async_playwright() as pw:
            browser = await pw.chromium.launch()
            ctx = await browser.new_context(
                viewport={'width': 390, 'height': 844},   # iPhone 14
                is_mobile=True, has_touch=True,
                user_agent='Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)'
                           ' AppleWebKit/605.1.15 (KHTML, like Gecko)'
                           ' Version/17.0 Mobile/15E148 Safari/604.1')
            page = await ctx.new_page()

            page.on('console', lambda m: console_errors.append(m.text)
                    if m.type == 'error' else None)
            page.on('pageerror', lambda e: console_errors.append(str(e)))

            await page.goto(f'http://127.0.0.1:{HTTP_PORT}/')
            await page.wait_for_timeout(500)

            # 1. Экран входа отрисовался, код подставлен из ссылки
            code_val = await page.input_value('#in-code')
            checks.append(('код партии подставлен автоматически', code_val == CODE))
            checks.append(('экран входа активен',
                           await page.is_visible('#scr-join')))

            # 2. Валидация: пустое имя не пускает
            await page.click('#btn-join')
            await page.wait_for_timeout(200)
            err = await page.text_content('#join-error')
            checks.append(('пустое имя не пропускается', 'имя' in (err or '').lower()))

            # 3. Вход в игру
            await page.fill('#in-name', 'Аня')
            await page.click('#btn-join')
            await page.wait_for_timeout(900)
            checks.append(('после входа показано лобби',
                           await page.is_visible('#scr-lobby')))
            lobby = await page.text_content('#lobby-list')
            checks.append(('игрок виден в списке лобби', 'Аня' in (lobby or '')))

            # 4. Раздача роли
            await push('role_assign', role='commissioner', roleName='Комиссар',
                       roleEmoji='🕵', roleDescription='Проверяет игроков',
                       teammates=[])
            await page.wait_for_timeout(400)
            checks.append(('экран предупреждения о роли показан',
                           await page.is_visible('#scr-reveal')))

            await page.click('#btn-reveal')
            await page.wait_for_timeout(300)
            checks.append(('после подтверждения виден экран игры',
                           await page.is_visible('#scr-game')))
            checks.append(('роль подтверждена хосту', 'role_ack' in seen))

            # 5. Ночная фаза с выбором цели
            srv_state['phase'] = 'night'
            srv_state['round'] = 1
            await push('phase', phase='night', round=1, time=30, paused=False,
                       isAlive=True, canAct=True, prompt='Кого проверить?',
                       targets=[{'id': 'x1', 'name': 'Борис', 'color': '#3357FF'},
                                {'id': 'x2', 'name': 'Вика', 'color': '#33FF57'}])
            await page.wait_for_timeout(400)

            checks.append(('показан список целей',
                           await page.is_visible('#action-area')))
            n_targets = await page.locator('#targets .p').count()
            checks.append(('обе цели отрисованы', n_targets == 2))

            # Кнопка отправки заблокирована, пока не выбрана цель
            checks.append(('кнопка неактивна без выбора',
                           await page.is_disabled('#btn-send')))

            _shots = pathlib.Path(__file__).resolve().parent.parent.parent / 'docs'
            _shots.mkdir(exist_ok=True)
            await page.screenshot(path=str(_shots / 'web_night.png'))
            await page.locator('#targets .p').first.click()
            await page.wait_for_timeout(200)
            checks.append(('после выбора кнопка активна',
                           not await page.is_disabled('#btn-send')))
            checks.append(('выбранная цель подсвечена',
                           await page.locator('#targets .p.sel').count() == 1))

            await page.click('#btn-send')
            await page.wait_for_timeout(400)
            checks.append(('ход отправлен', 'night_action' in seen))
            checks.append(('показано «выбор принят»',
                           await page.is_visible('#idle-area')))

            # 6. Таймер идёт
            t1 = await page.text_content('#phase-timer')
            await page.wait_for_timeout(2100)
            t2 = await page.text_content('#phase-timer')
            checks.append(('таймер отсчитывает', t1 != t2))

            # 7. Справка по роли
            await page.click('#btn-myrole')
            await page.wait_for_timeout(300)
            sheet = await page.text_content('#sheet-body')
            checks.append(('справка открывается и содержит роль',
                           'ЗАДАЧА' in (sheet or '')))
            await page.click('#sheet-close')
            await page.wait_for_timeout(200)

            # 8. Результат ночи
            await push('night_result', text='Этой ночью убит Борис',
                       killed=[{'id': 'x1', 'name': 'Борис'}])
            await page.wait_for_timeout(300)
            ban = await page.text_content('#banner')
            checks.append(('баннер события показан', 'Борис' in (ban or '')))

            # 9. Обрыв связи: браузер должен заметить и показать это
            for ws in list(conns.values()):
                await ws.close()
            await page.wait_for_timeout(1200)
            conn_txt = await page.text_content('#conn-text')
            checks.append(('обрыв связи виден игроку',
                           'одключ' in (conn_txt or '') or
                           'вяз' in (conn_txt or '')))

            # 10. Автовосстановление
            await page.wait_for_timeout(3500)
            back = await page.text_content('#conn-text')
            checks.append(('связь восстановилась сама',
                           back == 'Подключено' or len(conns) > 0))

            # 11. Голосование после возврата
            srv_state['phase'] = 'voting'
            await push('phase', phase='voting', round=1, time=25, paused=False,
                       isAlive=True, canAct=True, prompt='Кого выгнать?',
                       targets=[{'id': 'x2', 'name': 'Вика', 'color': '#33FF57'}])
            await page.wait_for_timeout(400)
            btn = await page.text_content('#btn-send')
            checks.append(('в голосовании кнопка называется иначе',
                           'олос' in (btn or '')))

            # 12. Гибель игрока
            await push('eliminated', reason='vote', round=1)
            await page.wait_for_timeout(400)
            checks.append(('экран выбывшего показан',
                           await page.is_visible('#dead-area')))

            # 13. Конец игры
            await push('game_over', title='Победил город',
                       reveal=[{'name': 'Аня', 'role': 'Комиссар',
                                'emoji': '🕵', 'isAlive': False}])
            await page.wait_for_timeout(400)
            checks.append(('итоговый экран показан',
                           await page.is_visible('#scr-over')))
            rev = await page.text_content('#reveal-list')
            checks.append(('расклад ролей виден', 'Комиссар' in (rev or '')))

            # 14. Скриншоты — глазами посмотреть, что вышло
            shots = pathlib.Path(__file__).resolve().parent.parent.parent / 'docs'
            shots.mkdir(exist_ok=True)
            await page.screenshot(path=str(shots / 'web_over.png'))

            await page.goto(f'http://127.0.0.1:{HTTP_PORT}/')
            await page.wait_for_timeout(400)
            await page.screenshot(path=str(shots / 'web_join.png'))

            await browser.close()

    http_srv.shutdown()

    # Ошибок в консоли быть не должно: они означают, что часть кода
    # молча не отработала.
    real_errors = [e for e in console_errors
                   if 'favicon' not in e.lower() and 'sw.js' not in e.lower()]
    checks.append(('нет ошибок JavaScript в консоли', not real_errors))

    print('\n' + '=' * 56)
    bad = []
    for name, ok in checks:
        print(f'  {"OK  " if ok else "FAIL"}  {name}')
        if not ok:
            bad.append(name)
    print('=' * 56)
    if real_errors:
        print('Ошибки консоли:')
        for e in real_errors[:8]:
            print('   ', e[:150])
    print(f'ИТОГ: {len(checks) - len(bad)}/{len(checks)}',
          'всё прошло' if not bad else f'— провалено: {bad}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(asyncio.run(main()))
