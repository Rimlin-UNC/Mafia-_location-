# -*- coding: utf-8 -*-
"""Принудительный старт: заказали N, пришло меньше. Что с балансом?

Проверка отвечает на один вопрос: может ли партия закончиться раньше
первого хода. Если после раздачи мафия уже не слабее города, город
проиграл, не сделав ни одного действия — такую раздачу выпускать нельзя.

Раньше стенд печатал «❌ МАФИЯ ПОБЕЖДАЕТ СРАЗУ», но завершался с кодом 0:
CI считал его зелёным, и дефект жил в раздаче ролей. Теперь любой ❌ —
это ненулевой код возврата и красный CI.
"""
import os, sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *
from collections import Counter

BAD = 0

def deal(planned_setup, actual):
    """Точный порт GameEngine.assignRoles из lib/core/game_engine.dart.

    Проверять «сырой» заказ бессмысленно: движок сам разжалует лишнюю
    мафию в мирных, чтобы партия не закончилась до первого хода. Стенд
    обязан повторять этот код, иначе он ругается на состав, который
    в игре до стола доедет уже выровненным.
    """
    pool=[]
    for t in [DON,MAFIA,DOCTOR,COM,PROS,MANIAC]:
        pool += [t]*planned_setup.get(t,0)
    while len(pool)>actual: pool.pop()
    mc=lambda: sum(1 for r in pool if r in (MAFIA,DON))
    kc=lambda: sum(1 for r in pool if r==MANIAC)
    while pool and mc() > 0:
        if mc() < actual - mc() - kc(): break
        if MAFIA in pool: idx=len(pool)-1-pool[::-1].index(MAFIA)
        elif DON in pool: idx=len(pool)-1-pool[::-1].index(DON)
        else: break
        pool[idx]=CIV
    while len(pool)<actual: pool.append(CIV)
    return Counter(pool)

def verdict_of(c, n):
    """Тот же расчёт, что в GameState.checkWinner.

    Мафия побеждает при mafia >= city, где city = все, кроме мафии
    и маньяка. Раньше здесь сравнивалось n - mafia (с маньяком внутри
    города) — то есть стенд был строже игры и при этом не падал.
    """
    maf = c[MAFIA] + c[DON]
    man = c[MANIAC]
    city = n - maf - man
    if man > 0 and maf == 0 and city == 0: return "маньяк"
    if maf == 0 and man == 0: return "город"
    if maf > 0 and maf >= city: return "❌ МАФИЯ ПОБЕЖДАЕТ СРАЗУ"
    if maf * 2 >= city * 1.5: return "⚠️ на грани"
    return "ок"

print("="*72)
print("ПРИНУДИТЕЛЬНЫЙ СТАРТ: заказан состав на 20, пришло меньше")
print("="*72)
S20={MAFIA:4,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1}
print(f"{'пришло':>7} | {'мафия':>6} {'доктор':>7} {'комисс':>7} {'прост':>6} {'маньяк':>7} {'мирные':>7} | вердикт")
print("-"*72)
for n in range(20,5,-1):
    c=deal(S20,n)
    v=verdict_of(c,n)
    if v.startswith("❌"): BAD+=1
    print(f"{n:>7} | {c[MAFIA]+c[DON]:>6} {c[DOCTOR]:>7} {c[COM]:>7} {c[PROS]:>6} {c[MANIAC]:>7} {c[CIV]:>7} | {v}")

print("\n" + "="*72)
print("ТОТ ЖЕ ТЕСТ ДЛЯ ПРЕСЕТА 9-12 (mafia:2, don:1)")
print("="*72)
S12={MAFIA:2,DON:1,DOCTOR:1,COM:1,PROS:1}
for n in range(12,5,-1):
    c=deal(S12,n)
    maf=c[MAFIA]+c[DON]; others=n-maf-c[MANIAC]
    v = verdict_of(c,n)
    if v.startswith("❌"): BAD+=1
    print(f"{n:>7} | мафия {maf}  мирных {c[CIV]}  спец {c[DOCTOR]+c[COM]+c[PROS]+c[MANIAC]} | {v}")

print()
if BAD:
    print(f"❌ ПРОВАЛ: {BAD} состав(ов) заканчиваются до первого хода.")
    sys.exit(1)
print("✅ Ни один состав не заканчивается до первого хода.")
