# -*- coding: utf-8 -*-
"""Пограничные и злонамеренные сценарии."""
import os, sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *
ok=fail=0
def chk(n,got,exp):
    global ok,fail
    if got==exp: ok+=1; print(f"  ✅ {n}")
    else: fail+=1; print(f"  ❌ {n}: got={got} exp={exp}")

S={MAFIA:2,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1}
def mk(n=12,seed=1):
    g=Game('t',n,S,seed=seed)
    for i in range(n): g.register(f'P{i}')
    g.start_game(); return g

print("ЗАЩИТА ОТ НЕКОРРЕКТНЫХ ДЕЙСТВИЙ:")
g=mk()
p=g.night_active[0]
g.night_action(p.id,g.targets_for(p)[0].id)
chk("повторный ночной ход отклонён", g.night_action(p.id,'p0'), 'already')
dead=next(x for x in g.players if x.role==CIV); dead.alive=False
chk("мёртвый не ходит", g.night_action(dead.id,'p0'), 'dead')
civ=next(x for x in g.players if x.role==CIV and x.alive)
chk("пассивная роль не ходит", g.night_action(civ.id,'p0'), 'not_active')
chk("ход в неверной фазе", (lambda: (setattr(g,'phase',DAY), g.night_action(p.id,'p0'))[1])(), 'wrong_phase')

print("\nГОЛОСОВАНИЕ:")
g=mk(); g.phase=VOTING; g.votes={}
v=g.alive[0]
g.vote(v.id,g.alive[1].id)
chk("повторный голос отклонён", g.vote(v.id,g.alive[2].id), 'already')
g2=mk(); g2.phase=VOTING; g2.runoff=[g2.alive[0].id,g2.alive[1].id]
g2.vote(g2.alive[3].id, g2.alive[5].id)   # не кандидат
chk("голос за не-кандидата -> воздержался", g2.votes[g2.alive[3].id], None)
g3=mk(); g3.phase=VOTING
for pl in g3.alive: g3.vote(pl.id,None)
chk("все воздержались -> лидеров нет", g3.vote_leaders, [])

print("\nВСЕ ОТКЛЮЧИЛИСЬ / НИКТО НЕ ХОДИТ:")
g=mk()
for pl in g.night_active: g.night_action(pl.id,None)
chk("ночь без действий завершается", g.pending_night is not None, True)
chk("никто не погиб", g.pending_night['killed'], [])

print("\nОДИН ИГРОК ОСТАЛСЯ:")
g=mk()
for pl in g.players[1:]: pl.alive=False
w=g.check_winner()
chk("один живой -> есть победитель", w is not None, True)

print("\nВСЕ МЕРТВЫ:")
g=mk()
for pl in g.players: pl.alive=False
chk("никого не осталось -> nobody", g.check_winner(), 'nobody')

print("\nПЕРЕПОДКЛЮЧЕНИЕ ПОСРЕДИ НОЧИ:")
g=mk()
pl=g.night_active[0]; pl.connected=False
r=g.register(pl.name)
chk("вернулся в свой слот", r[0], 'RECLAIM')
chk("роль на месте", g.by_id(r[1]).role is not None, True)
chk("может сходить после возврата", g.night_action(pl.id, g.targets_for(pl)[0].id), None)

print("\nЛИМИТ ИГРОКОВ:")
g=Game('t',20,S,seed=1)
for i in range(20): g.register(f'X{i}')
chk("21-й получает отказ", g.register('X99'), ('DENY','game_full'))

print(f"\n{ok} passed, {fail} failed")
# Ненулевой код возврата обязателен: раньше стенд печатал «❌» и
# завершался успешно, поэтому CI не замечал провала.
sys.exit(1 if fail else 0)
