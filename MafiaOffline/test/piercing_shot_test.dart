import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mafia_offline/core/game_engine.dart';
import 'package:mafia_offline/core/bot_engine.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/storage/session_store.dart';
import 'package:mafia_offline/storage/app_prefs.dart';

GameState table({bool guard = false, bool hunter = false}) => GameState(
  id: 'g', name: 'test', code: '123456', createdAt: DateTime.now(),
  phase: GamePhase.night, round: 2, piercingShot: true,
  piercingRequests: const ['m'],
  players: [
    for (final e in {'m': Role.mafia, 'd': Role.doctor, 'v': hunter ? Role.hunter : Role.civilian,
      'x': Role.civilian, 'p': Role.prostitute, if (guard) 'g': Role.bodyguard}.entries)
      Player(id: e.key, name: e.key, colorHex: '#FFFFFF', role: e.value),
  ],
  nightActions: {'m': 'v', 'd': 'v', if (guard) 'g': 'v'},
);
NightOutcome night(GameState s) => GameEngine.resolveNight(s, random: Random(1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('выключено по умолчанию; без запроса доктор спасает', () {
    final s = table();
    expect(night(s.copyWith(piercingShot: false)).killedIds, isEmpty);
    expect(night(s.copyWith(piercingRequests: [])).killedIds, isEmpty);
    expect(night(s.copyWith(piercingSpent: true)).killedIds, isEmpty);
    expect(night(s).killedIds, ['v']);
    expect(night(s).piercingUsed, isTrue);
  });
  test('заряд не тратится в ночь знакомства, при блокировке или пропуске', () {
    final s = table();
    for (final state in [s.copyWith(introNight: true, round: 1),
      s.copyWith(nightActions: {'m': 'v', 'd': 'v', 'p': 'm'}),
      s.copyWith(nightActions: {'m': null, 'd': 'v'})]) {
      expect(night(state).piercingUsed, isFalse);
      expect(night(state).killedIds, isEmpty);
    }
  });
  test('поддельные запросы от мирного, мёртвого или шантажиста не работают', () {
    final s = table();
    expect(night(s.copyWith(piercingRequests: ['x', 'missing'])).piercingUsed, isFalse);
    final dead = s.players.map((p) => p.id == 'm' ? p.copyWith(isAlive: false) : p).toList();
    expect(night(s.copyWith(players: dead)).piercingUsed, isFalse);
    final black = s.players.map((p) => p.id == 'm' ? p.copyWith(role: Role.blackmailer) : p).toList();
    expect(night(s.copyWith(players: black)).piercingUsed, isFalse);
  });
  test('проигравший голос команды не расходует заряд; дон может использовать', () {
    final s = table();
    final withDon = s.copyWith(players: [...s.players,
      const Player(id: 'don', name: 'Дон', colorHex: '#FFFFFF', role: Role.don)],
      nightActions: {'m': 'v', 'don': 'x', 'd': 'x'});
    expect(night(withDon).mafiaTargetId, 'x');
    expect(night(withDon).piercingUsed, isFalse);
    expect(night(withDon.copyWith(piercingRequests: ['don'])).killedIds, ['x']);
  });
  test('телохранитель принимает удар; доктор может спасти щит', () {
    final s = table(guard: true);
    expect(night(s).killedIds, ['g']);
    expect(night(s).piercingUsed, isTrue);
    expect(night(s.copyWith(nightActions: {'m': 'v', 'g': 'v', 'd': 'g'})).killedIds, isEmpty);
    expect(night(s.copyWith(nightActions: {'m': 'v', 'g': 'v', 'd': 'v', 'p': 'g'})).killedIds, ['v']);
  });
  test('смерть охотника запускает месть; дубли смертей не появляются', () {
    final s = table(hunter: true).copyWith(hunterMarkId: 'x');
    expect(night(s).killedIds, ['v', 'x']);
    expect(night(s).revengeIds, ['x']);
    final out = GameEngine.resolveAttacks(s, mafiaTarget: 'v', maniacTarget: 'v', healedId: 'v', piercing: true);
    expect(out.killed, ['v', 'x']);
  });
  test('сохранение помнит правило, запросы и расход; старое состояние выключено', () async {
    final store = SessionStore();
    await store.save(table().copyWith(piercingSpent: true));
    final restored = (await store.load())!;
    expect(restored.piercingShot, isTrue);
    expect(restored.piercingSpent, isTrue);
    expect(restored.piercingRequests, ['m']);
    expect(night(restored).piercingUsed, isFalse);
    await AppPrefs.setTableRules(const TableRulePrefs(piercingShot: true));
    expect((await AppPrefs.tableRules()).piercingShot, isTrue);
  });
  test('боты запрашивают только разрешённый заряд, без чтения чужих ходов', () {
    final s = table().copyWith(players: table().players.map((p) => p.copyWith(isBot: true)).toList(), nightActions: {});
    final requests = <String>{};
    for (var seed = 0; seed < 30; seed++) {
      requests.addAll(BotEngine.piercingRequestsFor(s, {'m': 'v', 'd': 'v'}, Random(seed)));
      expect(BotEngine.piercingRequestsFor(s.copyWith(piercingSpent: true), {'m': 'v'}, Random(seed)), isEmpty);
    }
    expect(requests, {'m'});
  });
  test('публичные правила не содержат приватный расход и заявки', () {
    final wire = TableRules.toWire(table());
    expect(wire['piercingShot'], isTrue);
    expect(wire.containsKey('piercingSpent'), isFalse);
    expect(wire.containsKey('piercingRequests'), isFalse);
  });
}
