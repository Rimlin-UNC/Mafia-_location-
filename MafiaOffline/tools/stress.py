# -*- coding: utf-8 -*-
"""Массовый прогон: 400 партий на 20 игроков + пограничные составы."""
import os, sys
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *

NAMES=[f'И{i}' for i in range(20)]
BUGS=Counter(); EX=[]
def bug(t,m):
    BUGS[t]+=1
    if len(EX)<14: EX.append(f'[{t}] {m}')

def play(seed,setup,n_players,names=None):
    g=Game('t',n_players,setup,seed=seed)
    for n in (names or NAMES)[:n_players]: g.register(n)
    g.start_game()
    guard=0; prev=len(g.alive)
    while g.phase!=ENDED and guard<300:
        guard+=1
        if g.phase==NIGHT:
            for p in list(g.night_active):
                t=g.targets_for(p)
                if p.role in (MAFIA,DON) and any(x.role in (MAFIA,DON) for x in t):
                    bug('MAFIA_SEES_OWN',f'seed{seed}')
                g.night_action(p.id, g.rnd.choice(t).id if t else None)
            if g.pending_night is None: g.finish_night()
            # инвариант: убитых не больше 2 за ночь
            o=g.pending_night
            if o and len(o['killed'])>2: bug('KILL_GT2',f"seed{seed}: {len(o['killed'])}")
            if o and o['healed'] and o['healed'] in o['killed']:
                bug('HEAL_FAILED',f'seed{seed}: вылеченный погиб')
            g.announce_night()
        elif g.phase==DAY: g.start_voting()
        elif g.phase==VOTING:
            for p in list(g.alive):
                t=g.targets_for(p)
                if any(x.id==p.id for x in t): bug('SELF_VOTE',f'seed{seed}')
                g.vote(p.id, g.rnd.choice(t).id if t and g.rnd.random()>0.15 else None)
            g.close_voting()
            L=g.vote_leaders
            if len(L)>1 and not g.runoff:
                g.start_voting(candidates=L); continue
            g.confirm_elimination(L[0] if len(L)==1 else None)
        a=len(g.alive)
        if a>prev: bug('ALIVE_UP',f'seed{seed}')
        prev=a
        # инвариант: победа не пропущена
        if g.phase!=ENDED and g.check_winner() is not None:
            bug('WIN_MISSED',f'seed{seed}: {g.check_winner()} не задетектирована')
    if guard>=300: bug('INFINITE',f'seed{seed}')
    # финал: победа корректна?
    if g.phase==ENDED:
        al=g.alive
        m=sum(1 for p in al if SIDE[p.role]=='mafia')
        k=sum(1 for p in al if SIDE[p.role]=='solo')
        c=sum(1 for p in al if SIDE[p.role]=='civ')
        if g.winner=='civilians' and (m>0 or k>0): bug('WIN_WRONG',f'город победил при m={m} k={k}')
        if g.winner=='mafia' and m==0: bug('WIN_WRONG','мафия победила без мафии')
        if g.winner=='maniac' and k==0: bug('WIN_WRONG','маньяк победил без маньяка')
    return g

print("="*66); print("НАГРУЗОЧНЫЙ ТЕСТ"); print("="*66)
S20={MAFIA:4,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1}
res=Counter(); rounds=[]
for seed in range(400):
    g=play(seed,S20,20); res[g.winner]+=1; rounds.append(g.round)
print(f"\n400 партий по 20 игроков:")
for w,c in res.most_common(): print(f"   {str(w):<12} {c:>4}  ({c/4:.0f}%)")
print(f"   раундов: мин {min(rounds)}  сред {sum(rounds)/len(rounds):.1f}  макс {max(rounds)}")

print("\nПограничные составы:")
cases=[("6 игроков, минимум",{MAFIA:1,DON:1},6),
       ("6 игроков + все спец",{MAFIA:1,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1},6),
       ("20, мафии почти половина",{MAFIA:8,DON:1},20),
       ("20, только мирные+1 мафия",{MAFIA:1},20),
       ("20, два маньяка нет — 1",{MANIAC:1,MAFIA:3,DON:1},20),
       ("8, ролей больше чем игроков",{MAFIA:5,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1},8)]
for label,setup,n in cases:
    r=Counter(); rr=[]
    for seed in range(60):
        g=play(seed+9000,setup,n); r[g.winner]+=1; rr.append(g.round)
    print(f"   {label:<30} {dict(r)}  ср.раундов {sum(rr)/len(rr):.1f}")

print("\n" + "="*66)
if BUGS:
    print(f"🐛 НАЙДЕНО: {sum(BUGS.values())} срабатываний, {len(BUGS)} типов")
    for t,c in BUGS.most_common(): print(f"   {t}: {c}")
    print("\nПримеры:")
    for e in EX: print("   ",e)
else:
    print("✅ ИНВАРИАНТЫ НЕ НАРУШЕНЫ")
# Код возврата = вердикт. Без него CI зелёный при найденных инвариантах.
sys.exit(1 if BUGS else 0)
