# -*- coding: utf-8 -*-
"""Правила стола v1.2.0: ночь знакомства, последнее слово, журнал проверок.

Стенд проверяет порт логики (tools/engine.py). Те же правила в Dart
покрыты test/rules_120_test.dart — формулировки проверок совпадают
намеренно, чтобы расхождение двух реализаций было видно сразу.

Запуск: python3 tools/rules120.py   (код возврата 1 — есть провал)
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *

OK = 0; BAD = []

def check(name, cond):
    global OK
    if cond: OK += 1
    else: BAD.append(name)
    print(f"  {'OK  ' if cond else 'FAIL'}  {name}")

def table(roles, **kw):
    """Партия с заданной раскладкой ролей (без случайной раздачи)."""
    g = Game('t', len(roles), {}, seed=1, **kw)
    for i, r in enumerate(roles):
        g.register(f'И{i}')
    for p, r in zip(g.players, roles):
        p.role = r
    g.start_night()
    return g

def who(g, role):
    return next(p for p in g.players if p.role == role)

ROLES = [DON, MAFIA, DOCTOR, COM, PROS, MANIAC, CIV, CIV, CIV, CIV]

print('Ночь знакомства')
g = table(ROLES, intro_night=True)
check('первая ночь помечена как знакомство', g.is_intro_night)
check('ходит только комиссар', [p.role for p in g.night_active] == [COM])
check('ход мафии сервер не принимает',
      g.night_action(who(g, DON).id, who(g, CIV).id) == 'not_active')
check('ход маньяка сервер не принимает',
      g.night_action(who(g, MANIAC).id, who(g, CIV).id) == 'not_active')
check('ход доктора сервер не принимает',
      g.night_action(who(g, DOCTOR).id, who(g, CIV).id) == 'not_active')
# Даже если ход убийцы попал в состояние в обход проверки — движок не убьёт.
g.night_actions[who(g, DON).id] = who(g, CIV).id
g.night_actions[who(g, MANIAC).id] = who(g, DOCTOR).id
check('комиссар проверяет', g.night_action(who(g, COM).id, who(g, MAFIA).id) is None)
check('ночь закрылась сама после хода комиссара', g.pending_night is not None)
check('никто не погиб', g.pending_night['killed'] == [])
check('проверка рядовой мафии — «мафия»', g.pending_night['is_mafia'] is True)
g.announce_night()
check('все живы после знакомства', len(g.alive) == len(ROLES))
check('наступил день', g.phase == DAY)
check('проверка записана в журнал', len(g.checks) == 1 and g.checks[0]['round'] == 1)
check('доктор не «запомнил» лечение', g.last_healed is None)

# Вторая ночь — обычная.
g.start_voting(); g.close_voting(); g.confirm_elimination(None)
check('вторая ночь — обычная', g.phase == NIGHT and g.round == 2 and not g.is_intro_night)
check('во вторую ночь ходят все ночные роли', len(g.night_active) == 6)
victim = who(g, CIV)
for p in list(g.night_active):
    t = {DON: victim.id, MAFIA: victim.id}.get(p.role)
    g.night_action(p.id, t)
check('во вторую ночь мафия убивает', g.pending_night['killed'] == [victim.id])

print('\nНочь знакомства выключена (как в 1.1.0)')
g = table(ROLES)
check('первая ночь обычная', not g.is_intro_night and len(g.night_active) == 6)

print('\nНочь знакомства без комиссара')
g = table([DON, MAFIA, DOCTOR, CIV, CIV, CIV], intro_night=True)
check('ходить некому', g.night_active == [])
g.finish_night(); g.announce_night()
check('ночь проходит без жертв и без проверки',
      len(g.alive) == 6 and g.checks == [] and g.phase == DAY)

print('\nПроверки комиссара')
g = table(ROLES)
com = who(g, COM)
for p in list(g.night_active):
    g.night_action(p.id, who(g, DON).id if p.role == COM else None)
g.announce_night()
check('дон на проверке — «не мафия»', g.checks[-1]['is_mafia'] is False)
check('проверка принадлежит комиссару', g.checks_by(com.id) == g.checks)
check('чужих проверок игрок не видит', g.checks_by(who(g, CIV).id) == [])

g = table(ROLES)
com = who(g, COM)
for p in list(g.night_active):
    t = {COM: who(g, MAFIA).id, DON: com.id, MAFIA: com.id}.get(p.role)
    g.night_action(p.id, t)
g.announce_night()
check('комиссар убит этой же ночью', not com.alive)
check('его последняя проверка всё равно записана',
      len(g.checks) == 1 and g.checks[0]['by'] == com.id and g.checks[0]['is_mafia'])

g = table(ROLES)
com = who(g, COM)
for p in list(g.night_active):
    t = {COM: who(g, MAFIA).id, PROS: com.id}.get(p.role)
    g.night_action(p.id, t)
g.announce_night()
check('заблокированный комиссар проверку не получает', g.checks == [])

print('\nДоктор')
g = table(ROLES)
doc = who(g, DOCTOR)
check('доктора нет в собственном списке целей',
      all(x.id != doc.id for x in g.targets_for(doc)))
for p in list(g.night_active):
    t = {DOCTOR: doc.id, DON: doc.id, MAFIA: doc.id}.get(p.role)
    g.night_action(p.id, t)
check('самолечение не спасает', g.pending_night['killed'] == [doc.id])

print('\nПоследнее слово')
g = table(ROLES, last_word=True)
for p in list(g.night_active): g.night_action(p.id, None)
g.announce_night(); g.start_voting()
out = who(g, CIV)
for p in list(g.alive): g.vote(p.id, out.id if p.id != out.id else None)
g.confirm_elimination(out.id)
check('после изгнания — последнее слово, а не ночь',
      g.phase == DAY and g.last_word_id == out.id)
check('таймер последнего слова — 30 секунд', g.time_left == 30)
check('говорящий уже выбыл', not out.alive)
check('во время слова никто не голосует', g.vote(g.alive[0].id, g.alive[1].id) == 'wrong_phase')
check('во время слова никто не ходит', g.night_action(who(g, DON).id, None) == 'wrong_phase')
r = g.round
g.end_last_word()
check('после слова — ночь следующего раунда',
      g.phase == NIGHT and g.round == r + 1 and g.last_word_id is None)

g = table(ROLES, last_word=True)
for p in list(g.night_active): g.night_action(p.id, None)
g.announce_night(); g.start_voting(); g.close_voting()
g.confirm_elimination(None)
check('никто не выбыл — слова нет, сразу ночь', g.phase == NIGHT and g.last_word_id is None)

# Изгнание, которое заканчивает партию: слова не будет.
g = table([DON, CIV, CIV, CIV], last_word=True)
g.finish_night(); g.announce_night(); g.start_voting()
don = who(g, DON)
for p in list(g.alive): g.vote(p.id, don.id if p.id != don.id else None)
g.confirm_elimination(don.id)
check('изгнание решило партию — финал без последнего слова',
      g.phase == ENDED and g.winner == 'civilians' and g.last_word_id is None)

g = table(ROLES)
for p in list(g.night_active): g.night_action(p.id, None)
g.announce_night(); g.start_voting()
out = who(g, CIV)
for p in list(g.alive): g.vote(p.id, out.id if p.id != out.id else None)
g.confirm_elimination(out.id)
check('правило выключено — сразу ночь (как в 1.1.0)', g.phase == NIGHT)

print('\nПолные партии с обоими правилами: 300 прогонов')
stuck = wrong = 0
for seed in range(300):
    n = 6 + seed % 15
    setup = {MAFIA: max(1, n // 4 - 1), DON: 1, DOCTOR: 1, COM: 1,
             PROS: 1 if n > 7 else 0, MANIAC: 1 if n > 11 else 0}
    g = Game('t', n, setup, seed=seed, intro_night=True, last_word=True)
    for i in range(n): g.register(f'И{i}')
    g.start_game()
    guard = 0; n1 = None
    while g.phase != ENDED and guard < 400:
        guard += 1
        if g.phase == NIGHT:
            first = g.round == 1
            for p in list(g.night_active):
                t = g.targets_for(p)
                g.night_action(p.id, g.rnd.choice(t).id if t else None)
            if g.pending_night is None: g.finish_night()
            if first and g.pending_night['killed']: wrong += 1
            g.announce_night()
            if first: n1 = len(g.alive)
        elif g.phase == DAY and g.last_word_id is not None:
            g.end_last_word()
        elif g.phase == DAY:
            g.start_voting()
        elif g.phase == VOTING:
            for p in list(g.alive):
                t = g.targets_for(p)
                g.vote(p.id, g.rnd.choice(t).id if t and g.rnd.random() > .15 else None)
            g.close_voting()
            L = g.vote_leaders
            if len(L) > 1 and not g.runoff:
                g.start_voting(candidates=L); continue
            g.confirm_elimination(L[0] if len(L) == 1 else None)
    if guard >= 400: stuck += 1
    if n1 is not None and n1 != n: wrong += 1
check('ни одна партия не зависла', stuck == 0)
check('в первую ночь никто не погиб ни в одной партии', wrong == 0)

print('\n' + '=' * 56)
print(f'{OK} passed, {len(BAD)} failed')
for b in BAD: print('  ✗', b)
sys.exit(1 if BAD else 0)
