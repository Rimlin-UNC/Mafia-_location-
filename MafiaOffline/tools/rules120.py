# -*- coding: utf-8 -*-
"""Правила стола v1.2.0 и v1.3.0: ночь знакомства, последнее слово с повторным
голосованием, ответ комиссару сразу после выбора, журнал проверок.

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
check('заблокированный комиссар ответа не получает, но знает об этом',
      len(g.checks) == 1 and g.checks[0]['blocked'] and g.checks[0]['is_mafia'] is False)

print('\nКомиссар видит ответ сразу, как выбрал игрока (v1.3.0)')
NO_PROS = [DON, MAFIA, DOCTOR, COM, MANIAC, CIV, CIV, CIV]
g = table(NO_PROS)
com = who(g, COM)
check('до хода комиссара ответа нет', g.check_known_now() is None and g.check_packets == [])
g.night_action(com.id, who(g, MAFIA).id)
check('проститутки нет — ответ известен в момент выбора',
      len(g.check_packets) == 1 and g.check_packets[0][2]['is_mafia'] is True)
check('ночь при этом ещё идёт', g.phase == NIGHT and g.pending_night is None)
check('второй выбор за ночь сервер не принимает',
      g.night_action(com.id, who(g, DON).id) == 'already')
check('ответ не изменился после второй попытки',
      len(g.check_packets) == 1 and g.check_packets[0][2]['target'] == who(g, MAFIA).id)
for p in list(g.pending_actors): g.night_action(p.id, None)
g.announce_night()
check('утром второй пакет не уходит', len(g.check_packets) == 1 and len(g.checks) == 1)

g = table(ROLES)
com = who(g, COM); pros = who(g, PROS)
g.night_action(com.id, who(g, MAFIA).id)
check('проститутка ещё не сходила — ответ ждёт её хода',
      g.check_known_now() is None and g.check_packets == [])
g.night_action(who(g, DOCTOR).id, None)
check('чужой ход (доктор) ответа не приносит', g.check_packets == [])
g.night_action(pros.id, who(g, CIV).id)
check('проститутка сходила мимо — ответ приходит сразу',
      len(g.check_packets) == 1 and g.check_packets[0][2]['is_mafia'] is True
      and g.pending_night is None)

g = table(ROLES)
com = who(g, COM); pros = who(g, PROS)
g.night_action(pros.id, None)
g.night_action(com.id, who(g, CIV).id)
check('проститутка пропустила ход — ответ в момент выбора',
      len(g.check_packets) == 1 and g.check_packets[0][2]['is_mafia'] is False
      and not g.check_packets[0][2]['blocked'])

g = table(ROLES)
com = who(g, COM); pros = who(g, PROS)
g.night_action(pros.id, com.id)
g.night_action(com.id, who(g, MAFIA).id)
check('проститутка пришла к комиссару — «проверка не состоялась»',
      len(g.check_packets) == 1 and g.check_packets[0][2]['blocked'])
check('роль цели заблокированному не раскрыта', g.check_packets[0][2]['is_mafia'] is False)

g = table(ROLES)
com = who(g, COM)
g.night_action(com.id, who(g, MAFIA).id)
g.finish_night()   # таймер вышел, проститутка так и не сходила
check('ночь закрыта без хода проститутки — ответ уходит до рассвета',
      g.phase == NIGHT and len(g.check_packets) == 1 and g.check_packets[0][2]['is_mafia'])

g = table(ROLES, intro_night=True)
g.night_action(who(g, COM).id, who(g, MAFIA).id)
check('ночь знакомства: проститутка спит, ответ сразу', len(g.check_packets) == 1)

g = table(NO_PROS)
g.private_check = False
g.night_action(who(g, COM).id, who(g, MAFIA).id)
check('правило выключено — пакета нет, журнал ведётся',
      g.check_packets == [] and len(g.checks) == 1)

# Ранний ответ совпадает с итогом ночи — перебор целей и блокировок.
same = True
for tr in (DON, MAFIA, DOCTOR, PROS, MANIAC, CIV):
    for br in (None, COM, DON, CIV):
        g = table(ROLES)
        com = who(g, COM); pros = who(g, PROS)
        g.night_action(pros.id, who(g, br).id if br else None)
        g.night_action(com.id, who(g, tr).id)
        early = dict(g.checks[-1])
        g.finish_night()
        final = g._check_from_outcome(g.pending_night)
        if early != final: same = False
check('ранний ответ совпадает с итогом ночи', same)

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
check('после голосования — последнее слово, а не ночь',
      g.phase == DAY and g.last_word_id == out.id)
check('таймер последнего слова — 30 секунд', g.time_left == 30)
check('говорящий ещё в игре', out.alive and len(g.alive) == len(ROLES))
check('во время слова никто не голосует', g.vote(g.alive[0].id, g.alive[1].id) == 'wrong_phase')
check('во время слова никто не ходит', g.night_action(who(g, DON).id, None) == 'wrong_phase')
r = g.round
g.end_last_word()
check('после слова — повторное голосование, а не ночь',
      g.phase == VOTING and g.round == r and g.verdict_id == out.id
      and g.last_word_id is None)

print('\nПовторное голосование: выгнать или оставить (v1.3.0)')
check('обвиняемый не голосует', g.vote(out.id, None) == 'accused')
check('голосуют все живые, кроме него', len(g.voters) == len(ROLES) - 1)
check('в списке у голосующего — только обвиняемый',
      [x.id for x in g.targets_for(g.voters[0])] == [out.id])
# Стол поверил: большинство «оставить».
for i, p in enumerate(g.voters): g.vote(p.id, out.id if i < 3 else None)
check('все высказались — голосование закрыто', g.awaiting_vote_confirm)
check('подсчёт: 3 «выгнать», 6 «оставить»', g.verdict_exile == 3 and g.verdict_keep == 6)
check('решение — оставить', not g.verdict_passes)
g.confirm_verdict()
check('стол поверил — игрок остаётся, наступает ночь',
      out.alive and g.phase == NIGHT and g.round == r + 1 and g.verdict_id is None)
check('в журнале — «остаётся в игре»', any('остаётся в игре' in x for x in g.log))

def to_verdict(roles, pick):
    """Партия, доведённая до повторного голосования по игроку pick(g)."""
    g = table(roles, last_word=True)
    for p in list(g.night_active): g.night_action(p.id, None)
    if g.pending_night is None: g.finish_night()
    g.announce_night(); g.start_voting()
    out = pick(g)
    for p in list(g.alive): g.vote(p.id, out.id if p.id != out.id else None)
    g.confirm_elimination(out.id); g.end_last_word()
    return g, out

g, out = to_verdict(ROLES, lambda g: who(g, CIV))
for i, p in enumerate(g.voters): g.vote(p.id, out.id if i < 5 else None)
check('«выгнать» больше (5 против 4) — решение выгнать', g.verdict_passes)
r = g.round
g.confirm_verdict()
check('стол не поверил — игрок выбывает, наступает ночь',
      not out.alive and out.elim_reason == 'voted' and g.phase == NIGHT and g.round == r + 1)

g, out = to_verdict(ROLES + [CIV], lambda g: who(g, CIV))
for i, p in enumerate(g.voters): g.vote(p.id, out.id if i < 5 else None)
check('поровну (5 на 5) — в пользу игрока',
      g.verdict_exile == 5 and g.verdict_keep == 5 and not g.verdict_passes)
g.confirm_verdict()
check('при равенстве игрок остаётся', out.alive and g.phase == NIGHT)

g, out = to_verdict(ROLES, lambda g: who(g, CIV))
g.close_voting()
check('никто не проголосовал — игрок остаётся', not g.verdict_passes)
g.confirm_verdict()
check('после пустого голосования — ночь, все живы',
      out.alive and g.phase == NIGHT and len(g.alive) == len(ROLES))

g, out = to_verdict(ROLES, lambda g: who(g, CIV))
for p in g.voters: g.vote(p.id, None)
g.confirm_elimination(out.id)   # ведущий решил иначе, чем стол
check('последнее слово за ведущим: может выгнать вопреки голосам',
      not out.alive and g.phase == NIGHT)
check('второго последнего слова нет', g.last_word_id is None)

# Последний мафиози: слово и повторное голосование всё равно есть.
g, don = to_verdict([DON, CIV, CIV, CIV], lambda g: who(g, DON))
check('выбран последний мафиози — партия ещё идёт, он жив',
      g.phase == VOTING and don.alive and g.winner is None)
for p in g.voters: g.vote(p.id, don.id)
g.confirm_verdict()
check('повторное голосование подтвердило — победа города',
      g.phase == ENDED and g.winner == 'civilians')

g, don = to_verdict([DON, CIV, CIV, CIV], lambda g: who(g, DON))
for p in g.voters: g.vote(p.id, None)
g.confirm_verdict()
check('дон убедил стол — остаётся, партия продолжается',
      don.alive and g.phase == NIGHT and g.winner is None)

g = table(ROLES, last_word=True)
for p in list(g.night_active): g.night_action(p.id, None)
g.announce_night(); g.start_voting(); g.close_voting()
g.confirm_elimination(None)
check('никто не выбыл — слова нет, сразу ночь', g.phase == NIGHT and g.last_word_id is None)

# Второй тур при ничьей — и только потом последнее слово.
g = table(ROLES, last_word=True)
for p in list(g.night_active): g.night_action(p.id, None)
g.announce_night(); g.start_voting()
a, b = [p for p in g.players if p.role == CIV][:2]
for i, p in enumerate(g.alive): g.vote(p.id, (a if i % 2 else b).id)
check('ничья в первом голосовании', len(g.vote_leaders) == 2)
g.start_voting(candidates=g.vote_leaders)
check('второй тур — не повторное голосование', g.verdict_id is None and not g.is_verdict_vote)
for p in list(g.alive): g.vote(p.id, a.id if p.id != a.id else None)
g.confirm_elimination(a.id)
check('после второго тура — последнее слово', g.last_word_id == a.id and a.alive)

g = table(ROLES)
for p in list(g.night_active): g.night_action(p.id, None)
g.announce_night(); g.start_voting()
out = who(g, CIV)
for p in list(g.alive): g.vote(p.id, out.id if p.id != out.id else None)
g.confirm_elimination(out.id)
check('правило выключено — выбывает сразу, наступает ночь (как в 1.1.0)',
      g.phase == NIGHT and not out.alive)

print('\nПолные партии с обоими правилами: 300 прогонов')
stuck = wrong = twice = differ = 0
words = exiled = pardoned = early_out = wrong_ask = miscount = 0
for seed in range(300):
    n = 6 + seed % 15
    setup = {MAFIA: max(1, n // 4 - 1), DON: 1, DOCTOR: 1, COM: 1,
             PROS: 1 if n > 7 else 0, MANIAC: 1 if n > 11 else 0}
    g = Game('t', n, setup, seed=seed, intro_night=True, last_word=True)
    for i in range(n): g.register(f'И{i}')
    g.start_game()
    guard = 0; n1 = None; ask = None
    while g.phase != ENDED and guard < 400:
        guard += 1
        if g.phase == NIGHT:
            first = g.round == 1
            for p in list(g.night_active):
                t = g.targets_for(p)
                g.night_action(p.id, g.rnd.choice(t).id if t else None)
            if g.pending_night is None: g.finish_night()
            # Ответ комиссару: не больше одного за ночь и тот же, что в итоге.
            mine = [c for c in g.check_packets if c[0] == g.round]
            if len(mine) > 1: twice += 1
            final = g._check_from_outcome(g.pending_night)
            if (mine[0][2] if mine else None) != final: differ += 1
            if first and g.pending_night['killed']: wrong += 1
            g.announce_night()
            if first: n1 = len(g.alive)
        elif g.phase == DAY and g.last_word_id is not None:
            ask = g.last_word_id
            if not g.by_id(ask).alive: early_out += 1
            words += 1
            g.end_last_word()
        elif g.phase == VOTING and g.is_verdict_vote:
            if g.verdict_id != ask: wrong_ask += 1
            before = len(g.alive)
            for p in list(g.voters):
                g.vote(p.id, g.verdict_id if g.rnd.random() > .45 else None)
            g.close_voting()
            passes = g.verdict_passes
            g.confirm_verdict()
            if passes: exiled += 1
            else: pardoned += 1
            if g.phase != ENDED and len(g.alive) != before - (1 if passes else 0): miscount += 1
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
check('комиссар ни разу не получил два ответа за ночь', twice == 0)
check('ответ комиссару всегда совпал с итогом ночи', differ == 0)
check('говорящий последнее слово всегда ещё в игре', words > 0 and early_out == 0)
check('повторное голосование — всегда о том, кто говорил', wrong_ask == 0)
check('за каждым словом — повторное голосование', words == exiled + pardoned)
check('бывало и изгнание, и помилование', exiled > 0 and pardoned > 0)
check('число живых после решения стола сходится', miscount == 0)
print(f'    последних слов: {words}, выгнали: {exiled}, оставили: {pardoned}')

print('\n' + '=' * 56)
print(f'{OK} passed, {len(BAD)} failed')
for b in BAD: print('  ✗', b)
sys.exit(1 if BAD else 0)
