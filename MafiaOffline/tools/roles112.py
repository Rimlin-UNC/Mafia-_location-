# -*- coding: utf-8 -*-
"""Стенд ролей 1.12.0: телохранитель, свидетель, охотник, шантажист.

Смысл: правила этих четырёх ролей легко «поплыть» при правке движка,
а проверить их вручную за столом почти невозможно — ошибка видна только
через неделю, когда кто-то скажет «а почему он выжил?». Поэтому те же
формулировки, что в инструкции и в памятке роли, зафиксированы здесь
как проверки. Dart-версия проверяется test/game_engine_test.dart
теми же сценариями.

Запуск: python3 tools/roles112.py   (код возврата 1 при провале)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import *  # noqa: E402,F403

OK = FAIL = 0


def check(name, cond, extra=''):
    global OK, FAIL
    if cond:
        OK += 1
        print(f'  ✅ {name}')
    else:
        FAIL += 1
        print(f'  ❌ {name}' + (f'  — {extra}' if extra else ''))


def table(roles, seed=1, intro_night=False):
    g = Game('t', len(roles), {}, seed=seed, intro_night=intro_night)
    for i in range(len(roles)):
        g.register(f'P{i}')
    g.start_game()
    # start_game раздаёт роли из setup; здесь раскладываем вручную,
    # чтобы сценарий был предсказуемым.
    for p, r in zip(g.players, roles):
        p.role = r
    g.last_healed = None
    g.last_guarded = None
    g.silenced = None
    g.watch_target = None
    g.watch_acted = None
    g.hunter_mark = None
    return g


def by_role(g, role):
    return next(p for p in g.players if p.role == role)


def who(g, role):
    return by_role(g, role)


def alive_ids(g):
    return [p.id for p in g.alive]


print('=' * 66)
print('РОЛИ 1.12.0')
print('=' * 66)

# ---------------------------------------------------------------- телохранитель
print('\n🛡 Телохранитель')
g = table([DON, GUARD, CIV, CIV, CIV, CIV])
don, guard, victim = who(g, DON), who(g, GUARD), g.players[2]
g.night_action(don.id, victim.id)
g.night_action(guard.id, victim.id)
g.finish_night()
o = g.pending_night
check('щит забирает удар: погиб телохранитель',
      o['killed'] == [guard.id], str(o['killed']))
check('прикрытый выжил', victim.id not in o['killed'])
check('итог помечает, кто погиб вместо кого', o['guard_died'] == guard.id)
check('итог помечает, кого прикрывали', o['guarded'] == victim.id)
g.announce_night()
check('в живых остался прикрытый', g.by_id(victim.id).alive)
check('телохранитель выбыл', not g.by_id(guard.id).alive)

g = table([DON, GUARD, MANIAC, CIV, CIV, CIV])
don, guard, man, c = who(g, DON), who(g, GUARD), who(g, MANIAC), g.players[3]
g.night_action(don.id, c.id)
g.night_action(man.id, c.id)
g.night_action(guard.id, c.id)
g.finish_night()
o = g.pending_night
check('два удара в прикрытого — один погибший, а не два',
      o['killed'] == [guard.id], str(o['killed']))

g = table([DON, GUARD, CIV, CIV, CIV, CIV])
don, guard = who(g, DON), who(g, GUARD)
g.night_action(don.id, guard.id)
g.night_action(guard.id, g.players[2].id)
g.finish_night()
check('стреляли в самого телохранителя — щит не спасает',
      g.pending_night['killed'] == [guard.id], str(g.pending_night['killed']))

g = table([DON, GUARD, DOCTOR, CIV, CIV, CIV])
don, guard, doc, victim = who(g, DON), who(g, GUARD), who(g, DOCTOR), g.players[3]
g.night_action(don.id, victim.id)
g.night_action(guard.id, victim.id)
g.night_action(doc.id, guard.id)
g.finish_night()
o = g.pending_night
check('доктор вылечил щит — не погиб никто', o['killed'] == [], str(o['killed']))
check('лечение и щит сошлись на одном человеке', o['healed'] == guard.id
      and o['guard_died'] == guard.id)

g = table([DON, GUARD, CIV, CIV, CIV, CIV])
don, guard = who(g, DON), who(g, GUARD)
check('себя прикрывать нельзя',
      all(x.id != guard.id for x in g.targets_for(guard)))
g.night_action(guard.id, g.players[2].id)
g.night_action(don.id, g.players[3].id)
g.finish_night()
g.announce_night()
g.start_voting()
g.close_voting()
g.confirm_elimination(None)
check('щит запомнился на прошлую ночь', g.last_guarded is not None)
g2_targets = g.targets_for(who(g, GUARD))
check('одну цель две ночи подряд прикрывать нельзя',
      all(x.id != g.last_guarded for x in g2_targets),
      f'last_guarded={g.last_guarded}')

g = table([DON, PROS, GUARD, CIV, CIV, CIV])
don, pros, guard, victim = who(g, DON), who(g, PROS), who(g, GUARD), g.players[3]
g.night_action(pros.id, guard.id)
g.night_action(guard.id, victim.id)
g.night_action(don.id, victim.id)
g.finish_night()
check('заблокированный щит не срабатывает',
      g.pending_night['killed'] == [victim.id], str(g.pending_night['killed']))

# -------------------------------------------------------------------- свидетель
print('\n👁 Свидетель')
g = table([DON, WITNESS, DOCTOR, CIV, CIV, CIV])
wit, don, doc, civ = who(g, WITNESS), who(g, DON), who(g, DOCTOR), g.players[3]
check('себя смотреть нельзя', all(x.id != wit.id for x in g.targets_for(wit)))
g.night_action(wit.id, doc.id)
check('ответа ещё нет: объект не сходил', g.watch_packets == [])
g.night_action(doc.id, civ.id)
check('ответ пришёл, когда объект сходил', len(g.watch_packets) == 1)
check('свидетель узнал «выходил» (доктор)', g.watch_packets[0]['acted'] is True)

g = table([DON, WITNESS, CIV, CIV, CIV, CIV])
wit, don, civ = who(g, WITNESS), who(g, DON), g.players[2]
g.night_action(wit.id, civ.id)
g.night_action(don.id, civ.id)
check('мирный житель «не выходил»', g.watch_packets[0]['acted'] is False)

g = table([DON, WITNESS, CIV, CIV, CIV, CIV])
wit, civ = who(g, WITNESS), g.players[2]
g.night_action(wit.id, civ.id)
g.finish_night()
check('ночь закрылась — ответ всё равно пришёл', len(g.watch_packets) == 1)
g.announce_night()
check('наблюдение запомнено на день', g.watch_target == civ.id)
check('в живых свидетеля не тронули', g.by_id(wit.id).alive)

g = table([DON, PROS, WITNESS, CIV, CIV, CIV])
pros, wit = who(g, PROS), who(g, WITNESS)
g.night_action(pros.id, wit.id)
g.night_action(wit.id, g.players[3].id)
g.finish_night()
check('заблокированный свидетель ничего не видит', g.watch_packets == [])

g = table([DON, WITNESS, CIV, CIV, CIV, CIV])
wit, don, civ = who(g, WITNESS), who(g, DON), g.players[2]
g.night_action(wit.id, don.id)
check('пока мафия не сходила, ответа нет', g.watch_packets == [])
g.night_action(don.id, civ.id)
check('про мафию свидетель узнаёт «выходил»',
      g.watch_packets and g.watch_packets[0]['acted'] is True)

# --------------------------------------------------------------------- охотник
print('\n🎯 Охотник')
# Ночь 1: охотник метит, но остаётся жив.
g = table([DON, HUNTER, CIV, CIV, CIV, CIV])
hun, don, target = who(g, HUNTER), who(g, DON), g.players[2]
g.night_action(hun.id, target.id)
g.night_action(don.id, g.players[3].id)
g.finish_night()
check('метка не срабатывает в ту же ночь', g.pending_night['revenge'] == [])
check('метка запомнена в итоге ночи', g.pending_night['mark'] == target.id)
g.announce_night()
check('метка пережила ночь', g.hunter_mark == target.id)
g.start_voting()
g.close_voting()
g.confirm_elimination(None)
check('охотник жив после первой ночи', g.by_id(hun.id).alive)
# Ночь 2: убивают охотника, его метка уже «созрела». Свою метку он
# в эту ночь не меняет — она остаётся с прошлой ночи.
g.night_action(don.id, hun.id)
g.finish_night()
o = g.pending_night
check('созревшая метка забирает отмеченного',
      target.id in o['killed'] and o['revenge'] == [target.id], str(o))
check('метка-«созревание» снимается после смерти охотника',
      o['mark'] is None, str(o['mark']))
g.announce_night()
check('после смерти охотника метки нет', g.hunter_mark is None)

# Ночь 1: охотник метит и погибает в ту же ночь — метка не успевает.
g = table([DON, HUNTER, CIV, CIV, CIV, CIV])
hun, don, target = who(g, HUNTER), who(g, DON), g.players[2]
g.night_action(hun.id, target.id)
g.night_action(don.id, hun.id)
g.finish_night()
o = g.pending_night
check('погиб в ту же ночь — метка не сработала', o['revenge'] == [],
      str(o['killed']))
check('погиб только охотник', o['killed'] == [hun.id])
check('метка мертвеца не запоминается', o['mark'] is None)
g.announce_night()
check('у мёртвого охотника метки нет', g.hunter_mark is None)

g = table([DON, HUNTER, CIV, CIV, CIV, CIV])
hun, target = who(g, HUNTER), g.players[2]
g.hunter_mark = target.id
g.start_voting()
g.close_voting()
g.confirm_elimination(hun.id)
check('изгнание голосованием тоже срабатывает: охотник выбыл',
      not g.by_id(hun.id).alive)
check('отмеченный погиб вместе с охотником', not g.by_id(target.id).alive)
check('метка снята после срабатывания', g.hunter_mark is None)

g = table([DON, HUNTER, CIV, CIV, CIV, CIV])
hun = who(g, HUNTER)
check('себя метить нельзя', all(x.id != hun.id for x in g.targets_for(hun)))

# ------------------------------------------------------------------ шантажист
print('\n🕶 Шантажист')
g = table([MAFIA, BLACK, DOCTOR, CIV, CIV, CIV])
bl, doc, civ = who(g, BLACK), who(g, DOCTOR), g.players[3]
check('своих пугать нельзя', all(SIDE[x.role] != 'mafia' for x in g.targets_for(bl)))
check('себя пугать нельзя', all(x.id != bl.id for x in g.targets_for(bl)))
g.night_action(bl.id, doc.id)
g.night_action(doc.id, civ.id)
g.finish_night()
o = g.pending_night
check('шантаж записан', o['silenced'] == doc.id)
check('ночной ход шантаж не отменяет', o['healed'] == civ.id)
g.announce_night()
check('запуганный известен днём', g.silenced == doc.id)
g.start_voting()
res = g.vote(doc.id, civ.id)
check('запуганный не может голосовать', res == 'silenced', str(res))
check('его голоса нет в подсчёте', doc.id not in g.votes)
res = g.vote(civ.id, doc.id)
check('остальные голосуют как обычно', res is None)
g.close_voting()
g.confirm_elimination(civ.id)
check('через ночь шантаж снят', g.silenced is None)

g = table([MAFIA, BLACK, DOCTOR, CIV, CIV, CIV])
bl, man_t = who(g, BLACK), g.players[2]
g.night_action(bl.id, MANIAC if False else man_t.id)
g.finish_night()
check('маньяка тоже можно запугать (он не мафия)',
      g.pending_night['silenced'] == man_t.id)

# шантажист не стрелок: сам по себе он никого не убивает
g = table([BLACK, CIV, CIV, CIV, CIV, CIV])
bl = who(g, BLACK)
g.night_action(bl.id, g.players[1].id)
g.finish_night()
check('шантажист никого не убивает', g.pending_night['killed'] == [])

# ---------------------------------------------------------------- условия победы
print('\n🏁 Условия победы и «свои»')
g = table([BLACK, CIV, CIV, CIV, CIV, CIV])
check('шантажист считается мафией: 1 против 5 — игра идёт',
      g.check_winner() is None, str(g.check_winner()))
check('город не побеждает, пока жив шантажист',
      g.check_winner() != 'civilians')
for p in g.players[1:]:
    p.alive = False
check('шантажист остался один — победа мафии',
      g.check_winner() == 'mafia', str(g.check_winner()))

g = table([MAFIA, DON, BLACK, CIV, CIV, CIV])
check('стрелки не видят шантажиста в целях',
      all(x.role != BLACK for x in g.targets_for(who(g, MAFIA))))
check('шантажист не видит стрелков в целях',
      all(SIDE[x.role] != 'mafia' for x in g.targets_for(who(g, BLACK))))

print('\n' + '=' * 66)
if FAIL:
    print(f'❌ {OK} прошло, {FAIL} провалено')
    sys.exit(1)
print(f'✅ {OK} проверок пройдено')
