import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mafia_offline/core/constants.dart';
import 'package:mafia_offline/core/game_engine.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/models/phase_timings.dart';
import 'package:mafia_offline/models/player.dart';
import 'package:mafia_offline/models/role.dart';
import 'package:mafia_offline/storage/app_prefs.dart';
import 'package:mafia_offline/storage/session_store.dart';
import 'package:mafia_offline/ui/host/timing_settings.dart';

GameState table() => GameState(id: 'g', name: 'test', code: '123456',
  createdAt: DateTime.now(), phase: GamePhase.night, round: 1,
  players: [
    for (var i = 0; i < 6; i++) Player(id: '$i', name: '$i', colorHex: '#FFFFFF',
      role: i == 0 ? Role.mafia : i == 1 ? Role.doctor : Role.civilian),
  ]);
const custom = PhaseTimings(night: 42, day: 155, voting: 64, runoff: 22, lastWord: 17);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('авто сохраняет прежние формулы, первую ночь и соло', () {
    final s = table();
    final base = Rules.nightBaseSeconds + Rules.nightPerActiveSeconds * s.nightActive.length;
    expect(s.nightDuration, (base * Rules.firstNightFactor).round());
    expect(s.copyWith(round: 2).nightDuration, base);
    expect(s.dayDuration, Rules.dayPerPlayerSeconds * 6);
    expect(s.votingDuration, Rules.votingBaseSeconds + Rules.votingPerPlayerSeconds * 6);
    expect(s.runoffDuration, Rules.runoffBaseSeconds + Rules.runoffPerPlayerSeconds * 6);
    final solo = s.copyWith(players: s.players.map((p) => p.copyWith(isBot: p.id != '0')).toList());
    expect(solo.dayDuration, Rules.soloDaySeconds);
    expect(s.timings.lastWord, 30);
  });
  test('фиксированные значения не зависят от раунда, живых и ботов', () {
    final s = table().copyWith(timings: custom);
    expect(s.nightDuration, 42);
    expect(s.copyWith(round: 8).nightDuration, 42);
    expect(s.dayDuration, 155);
    expect(s.votingDuration, 64);
    expect(s.runoffDuration, 22);
    expect(s.copyWith(players: []).dayDuration, 155);
    final wire = TableRules.toWire(s);
    expect(wire['lastWordSeconds'], 17);
    expect(wire['timings'], custom.toJson());
    expect(TableRules.describe(s).join(), contains('ночь — 42 с'));
  });
  test('диапазоны, отсутствующие и повреждённые поля безопасны', () {
    for (final data in [null, 45, [], 'bad', {'night': -1, 'day': 1801, 'voting': 9,
      'runoff': '60', 'lastWord': 301}, {'night': 10.5, 'lastWord': true}]) {
      expect(PhaseTimings.fromJson(data).toJson(), const PhaseTimings().toJson());
    }
    expect(const PhaseTimings(night: -1, lastWord: 9999).toJson(), const PhaseTimings().toJson());
    expect(PhaseTimings.fromJson({'night': 10, 'day': 1800, 'lastWord': 300}).toJson(),
      const PhaseTimings(night: 10, day: 1800, lastWord: 300).toJson());
    expect(custom.withSeconds('night', 0).night, 0);
    expect(custom.withSeconds('night', 0).day, 155);
  });
  test('настройки следующего стола и сессия хранят все тайминги', () async {
    await AppPrefs.setTableRules(const TableRulePrefs(timings: custom));
    expect((await AppPrefs.tableRules()).timings.toJson(), custom.toJson());
    final store = SessionStore();
    await store.save(table().copyWith(timings: custom, timeLeft: 11));
    final restored = (await store.load())!;
    expect(restored.timings.toJson(), custom.toJson());
    expect(restored.timeLeft, 11);
    expect(restored.paused, isTrue);
  });
  test('старое сохранение и битые настройки возвращают авто', () async {
    final store = SessionStore();
    await store.save(table());
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonDecode(prefs.getString('active_session_v1')!) as Map<String, dynamic>;
    raw.remove('timings');
    await prefs.setString('active_session_v1', jsonEncode(raw));
    expect((await store.load())!.timings.toJson(), const PhaseTimings().toJson());
    await prefs.setString('rule_timings', '{bad');
    expect((await AppPrefs.tableRules()).timings.toJson(), const PhaseTimings().toJson());
  });
  testWidgets('редактор валидирует число, сохраняет и сбрасывает', (tester) async {
    var value = const PhaseTimings();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, update) => SingleChildScrollView(child: TimingSettings(value: value,
        onChanged: (v) => update(() => value = v))),
    ))));
    await tester.tap(find.text('Тайминги фаз'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ночь'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '9');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Введите целое число от 10 до 1800'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '87');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(value.night, 87);
    await tester.ensureVisible(find.text('Сбросить все тайминги'));
    await tester.tap(find.text('Сбросить все тайминги'));
    await tester.pumpAndSettle();
    expect(value.toJson(), const PhaseTimings().toJson());
  });
}
