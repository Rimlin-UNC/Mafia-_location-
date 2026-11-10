# -*- coding: utf-8 -*-
"""Условие победы мафии: m >= c+k. Проверяем на реальных раскладах."""
import os, sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *
print("Правило: мафия побеждает при mafia >= civ + maniac")
print(f"{'мафия':>6}{'мирн':>6}{'мань':>6} | результат")
print("-"*40)
for m,c,k in [(1,1,0),(1,2,0),(2,2,0),(2,3,0),(1,0,1),(1,1,1),(2,1,1),(1,2,1),(0,1,1),(0,0,1),(0,2,0)]:
    pl=[]
    pl+= [DON]*min(m,1) + [MAFIA]*max(0,m-1)
    pl+= [CIV]*c + [MANIAC]*k
    g=Game('t',len(pl),{},seed=1)
    for i,r in enumerate(pl):
        g.register(f'p{i}'); g.players[i].role=r
    print(f"{m:>6}{c:>6}{k:>6} | {g.check_winner()}")
