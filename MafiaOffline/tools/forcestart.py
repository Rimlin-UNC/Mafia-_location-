# -*- coding: utf-8 -*-
"""Принудительный старт: заказали N, пришло меньше. Что с балансом?"""
import os, sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *
from collections import Counter

def deal(planned_setup, actual):
    """Порт assignRoles: пул строится по заказу, режется под фактическое число."""
    pool=[]
    for t in [DON,MAFIA,DOCTOR,COM,PROS,MANIAC]:
        pool += [t]*planned_setup.get(t,0)
    while len(pool)>actual: pool.pop()
    while len(pool)<actual: pool.append(CIV)
    return Counter(pool)

print("="*72)
print("ПРИНУДИТЕЛЬНЫЙ СТАРТ: заказан состав на 20, пришло меньше")
print("="*72)
S20={MAFIA:4,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1}
print(f"{'пришло':>7} | {'мафия':>6} {'доктор':>7} {'комисс':>7} {'прост':>6} {'маньяк':>7} {'мирные':>7} | вердикт")
print("-"*72)
for n in range(20,5,-1):
    c=deal(S20,n)
    maf=c[MAFIA]+c[DON]; others=n-maf
    verdict = "❌ МАФИЯ ПОБЕЖДАЕТ СРАЗУ" if maf>=others else ("⚠️ на грани" if maf*2>=others*1.5 else "ок")
    print(f"{n:>7} | {maf:>6} {c[DOCTOR]:>7} {c[COM]:>7} {c[PROS]:>6} {c[MANIAC]:>7} {c[CIV]:>7} | {verdict}")

print("\n" + "="*72)
print("ТОТ ЖЕ ТЕСТ ДЛЯ ПРЕСЕТА 9-12 (mafia:2, don:1)")
print("="*72)
S12={MAFIA:2,DON:1,DOCTOR:1,COM:1,PROS:1}
for n in range(12,5,-1):
    c=deal(S12,n)
    maf=c[MAFIA]+c[DON]; others=n-maf
    verdict = "❌ МАФИЯ ПОБЕЖДАЕТ СРАЗУ" if maf>=others else "ок"
    print(f"{n:>7} | мафия {maf}  мирных {c[CIV]}  спец {c[DOCTOR]+c[COM]+c[PROS]} | {verdict}")
