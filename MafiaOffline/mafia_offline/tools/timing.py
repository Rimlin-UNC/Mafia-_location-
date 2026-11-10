# -*- coding: utf-8 -*-
"""Хватает ли времени фаз при 20 игроках? Формулы из core/constants.dart."""
NIGHT_BASE, NIGHT_PER = 10, 2
DAY_PER = 60
VOTING, RUNOFF = 30, 20

print("="*74)
print("ТАЙМИНГИ ФАЗ (формулы из constants.dart)")
print("="*74)
print(f"{'живых':>6}{'активн':>8}{'НОЧЬ':>9}{'на 1 ход':>10}{'ДЕНЬ':>9}{'ГОЛОС':>8}{'на 1 голос':>12}")
print("-"*74)
for alive,active in [(20,8),(18,8),(16,7),(14,7),(12,6),(10,5),(8,4),(6,3)]:
    night=NIGHT_BASE+NIGHT_PER*active
    per_action=night/active
    day=DAY_PER*alive
    per_vote=VOTING/alive
    flag=""
    if per_action<8: flag+=" ❌ночь"
    if per_vote<3: flag+=" ❌голос"
    if day>900: flag+=" ⚠️день"
    print(f"{alive:>6}{active:>8}{night:>7}с{per_action:>9.1f}с{day//60:>7}м{VOTING:>7}с{per_vote:>11.1f}с{flag}")

print("\nСколько РЕАЛЬНО нужно человеку:")
print("  ночной ход: открыть экран + прочитать список + выбрать + подтвердить ≈ 10-15 с")
print("  голос:      прочитать список из N + выбрать + подтвердить      ≈ 8-12 с")
print("\nВЫВОД:")
n20=NIGHT_BASE+NIGHT_PER*8
print(f"  Ночь при 20 игроках = {n20} с на 8 ходящих ({n20/8:.1f} с на человека) — НЕ ХВАТАЕТ")
print(f"  Голосование = {VOTING} с на 20 человек ({VOTING/20:.1f} с на человека) — НЕ ХВАТАЕТ")
print(f"  День при 20 игроках = {DAY_PER*20//60} минут — слишком долго для одной фазы")
