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
                # 1.12.0: «своими» считается вся мафия, включая шантажиста.
                if p.role in (MAFIA,DON) and any(SIDE[x.role]=='mafia' for x in t):
                    bug('MAFIA_SEES_OWN',f'seed{seed}')
                if p.role==BLACK and any(SIDE[x.role]=='mafia' for x in t):
                    bug('BLACK_SEES_OWN',f'seed{seed}')
                g.night_action(p.id, g.rnd.choice(t).id if t else None)
            if g.pending_night is None: g.finish_night()
            # Инварианты ночи. С 1.12.0 «естественных» смертей по-прежнему
            # не больше двух, но третьим может стать отмеченный охотником —
            # поэтому лишние смерти разрешены только как месть.
            o=g.pending_night
            if o:
                rev=o.get('revenge') or []
                if len(o['killed'])>2 and not rev:
                    bug('KILL_GT2',f"seed{seed}: {len(o['killed'])}")
                if len(o['killed'])>3:
                    bug('KILL_GT3',f'seed{seed}: {len(o["killed"])}')
                if o['healed'] and o['healed'] in o['killed'] and o['healed'] not in rev:
                    bug('HEAL_FAILED',f'seed{seed}: вылеченный погиб')
                if o.get('guarded') and o['guarded'] in o['killed'] and o['guarded'] not in rev:
                    bug('GUARD_FAILED',f'seed{seed}: прикрытый погиб')
                if o.get('guard_died'):
                    # Щит умирает вместо прикрытого ровно один раз — или
                    # не умирает вовсе, если доктор успел его вылечить.
                    n=o['killed'].count(o['guard_died'])
                    if n>1 or (n==0 and o.get('healed')!=o['guard_died']):
                        bug('GUARD_DOUBLE',f'seed{seed}')
                if o.get('silenced') and SIDE[g.by_id(o['silenced']).role]=='mafia':
                    bug('SILENCE_OWN',f'seed{seed}')
                if o.get('watched') and o.get('watched_acted') is None:
                    bug('WATCH_NO_ANSWER',f'seed{seed}')
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
# 1.12.0: тот же стол на 20, но со всеми новыми ролями — как в пресете
# приложения для 17+ игроков.
S20N={MAFIA:3,DON:1,BLACK:1,DOCTOR:1,COM:1,GUARD:1,PROS:1,WITNESS:1,HUNTER:1,MANIAC:1}
res=Counter(); rounds=[]
for seed in range(400):
    g=play(seed,S20,20); res[g.winner]+=1; rounds.append(g.round)
print(f"\n400 партий по 20 игроков:")
for w,c in res.most_common(): print(f"   {str(w):<12} {c:>4}  ({c/4:.0f}%)")
print(f"   раундов: мин {min(rounds)}  сред {sum(rounds)/len(rounds):.1f}  макс {max(rounds)}")

print(f"\n400 партий по 20 игроков со всеми ролями 1.12.0:")
res=Counter(); rounds=[]
for seed in range(400):
    g=play(seed,S20N,20); res[g.winner]+=1; rounds.append(g.round)
for w,c in res.most_common(): print(f"   {str(w):<12} {c:>4}  ({c/4:.0f}%)")
print(f"   раундов: мин {min(rounds)}  сред {sum(rounds)/len(rounds):.1f}  макс {max(rounds)}")

print("\nПограничные составы:")
cases=[("6 игроков, минимум",{MAFIA:1,DON:1},6),
       ("6 игроков + все спец",{MAFIA:1,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1},6),
       ("20, мафии почти половина",{MAFIA:8,DON:1},20),
       ("20, только мирные+1 мафия",{MAFIA:1},20),
       ("20, два маньяка нет — 1",{MANIAC:1,MAFIA:3,DON:1},20),
       ("8, ролей больше чем игроков",{MAFIA:5,DON:1,DOCTOR:1,COM:1,PROS:1,MANIAC:1},8),
       ("6, только новые роли",{MAFIA:1,DON:1,GUARD:1,WITNESS:1,HUNTER:1,BLACK:1},6),
       ("20, без стрелков — один шантажист",{BLACK:1},20)]
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
