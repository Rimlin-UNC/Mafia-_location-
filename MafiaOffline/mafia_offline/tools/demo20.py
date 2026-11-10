# -*- coding: utf-8 -*-
"""Демо-партия на 20 игроков с проверкой инвариантов на каждом шаге."""
import sys, random
sys.path.insert(0,'/home/user/mafia_offline/tools')
from engine import *

NAMES=['Анна','Иван','Пётр','Сергей','Мария','Олег','Дина','Костя','Лена','Артём',
       'Вера','Гриша','Даша','Егор','Жанна','Захар','Инна','Кирилл','Люба','Миша']
SETUP={MAFIA:4,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1}   # пресет 17-20

BUGS=[]
def bug(tag,msg):
    BUGS.append((tag,msg)); print(f"   🐛 [{tag}] {msg}")

def check_invariants(g,step):
    # 1. роль ровно одна и она валидна
    for p in g.players:
        if p.role is None: bug('ROLE_NULL',f'{p.name} без роли на шаге {step}')
    # 2. цвета уникальны
    cols=[p.color for p in g.players]
    if len(set(cols))!=len(cols): bug('COLOR_DUP',f'дубли цветов на {step}')
    # 3. имена уникальны
    nm=[p.name.lower() for p in g.players]
    if len(set(nm))!=len(nm): bug('NAME_DUP',f'дубли имён на {step}')
    # 4. мёртвые не голосуют и не ходят
    # Проверяем только внутри активной фазы: словари намеренно не чистятся
    # при переходе, но все потребители сверяются с фазой.
    if g.phase==NIGHT:
        for pid in g.night_actions:
            p=g.by_id(pid)
            if p and not p.alive: bug('DEAD_ACTS',f'{p.name} мёртв, но сходил ({step})')
    if g.phase==VOTING:
        for pid in g.votes:
            p=g.by_id(pid)
            if p and not p.alive: bug('DEAD_VOTES',f'{p.name} мёртв, но голосует ({step})')
    # 5. счётчик живых не растёт
    return len(g.alive)

def run(seed,verbose=False):
    g=Game('Демо 20',20,SETUP,seed=seed)
    for n in NAMES:
        r=g.register(n)
        if r[0]!='OK': bug('REG',f'{n}: {r}')
    if len(g.players)!=20: bug('REG_COUNT',f'подключилось {len(g.players)}/20')

    g.start_game()
    for p in g.players: p.role_ack=True

    # состав ролей соответствует пресету?
    from collections import Counter
    cnt=Counter(p.role for p in g.players)
    for role,want in SETUP.items():
        if cnt[role]!=want: bug('SETUP',f'{role}: роздано {cnt[role]}, заказано {want}')
    if cnt[CIV]!=20-sum(SETUP.values()):
        bug('SETUP_CIV',f'мирных {cnt[CIV]}, ожидалось {20-sum(SETUP.values())}')

    prev_alive=20; guard=0
    while g.phase!=ENDED and guard<200:
        guard+=1
        if g.phase==NIGHT:
            for p in list(g.night_active):
                t=g.targets_for(p)
                # проверка: мафия не видит своих
                if p.role in (MAFIA,DON):
                    if any(x.role in (MAFIA,DON) for x in t):
                        bug('MAFIA_SEES_OWN',f'{p.name} видит союзника в целях')
                if p.role==DOCTOR and g.last_healed:
                    if any(x.id==g.last_healed for x in t):
                        bug('DOC_REPEAT','доктор может лечить ту же цель дважды')
                if p.role in (PROS,COM) and any(x.id==p.id for x in t):
                    bug('SELF_TARGET',f'{p.role} может выбрать себя')
                if t: g.night_action(p.id, g.rnd.choice(t).id)
                else: g.night_action(p.id, None)
            if g.pending_night is None: g.finish_night()
            g.announce_night()
        elif g.phase==DAY:
            g.start_voting()
        elif g.phase==VOTING:
            for p in list(g.alive):
                t=g.targets_for(p)
                g.vote(p.id, g.rnd.choice(t).id if t and g.rnd.random()>0.15 else None)
            g.close_voting()
            leaders=g.vote_leaders
            if len(leaders)>1 and not g.runoff:
                g.start_voting(candidates=leaders)   # второй тур
                continue
            g.confirm_elimination(leaders[0] if len(leaders)==1 else None)
        a=check_invariants(g,f'{g.phase}/{g.round}')
        if a>prev_alive: bug('ALIVE_UP',f'живых стало больше: {prev_alive}->{a}')
        prev_alive=a
    if guard>=200: bug('INFINITE','партия не закончилась за 200 итераций')
    return g

print("="*64); print("ДЕМО-ПАРТИЯ: 20 ИГРОКОВ"); print("="*64)
g=run(seed=42,verbose=True)
print(f"\nПодключилось: 20  Раундов: {g.round}  Победа: {g.winner}")
print(f"Выжило: {len(g.alive)}  Звуков: {len(g.sounds)}")
print("\nСостав:")
from collections import Counter
for r,c in Counter(p.role for p in g.players).most_common(): print(f"   {r:<14} {c}")
print("\nЛог (последние 8):")
for l in g.log[-8:]: print("   ",l)
print(f"\n{'✅ БАГОВ НЕ НАЙДЕНО' if not BUGS else f'🐛 НАЙДЕНО {len(BUGS)} ПРОБЛЕМ'}")
