import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mafia_offline/storage/suspicion_store.dart';
import 'package:mafia_offline/models/player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('заметка переживает открытие экрана и изолирована по партии и игроку', () async {
    const store = SuspicionStore('host|123456|me');
    expect(await store.save({'p1': const SuspicionNote(text: 'Сменил голос', mark: 'suspect')}), isTrue);
    final restored = await const SuspicionStore('host|123456|me').load();
    expect(restored['p1']!.text, 'Сменил голос');
    expect(restored['p1']!.mark, 'suspect');
    expect(await const SuspicionStore('host|123457|me').load(), isEmpty);
    expect(await const SuspicionStore('host|123456|other').load(), isEmpty);
  });

  test('повреждённые данные и старые типы не ломают блокнот', () async {
    SharedPreferences.setMockInitialValues({'private_notes_v1:test': '{broken'});
    expect(await const SuspicionStore('test').load(), isEmpty);
    expect(SuspicionNote.fromJson({'text': 42, 'mark': 'mafia'}).text, '');
    expect(SuspicionNote.fromJson({'mark': 'mafia'}).mark, '');
    expect(SuspicionNote.fromJson({'text': 'a' * 600}).text.length, 500);
  });

  test('приватная запись не появляется в публичном Player JSON', () async {
    const player = Player(id: 'p1', name: 'Ира', colorHex: '#123456');
    await const SuspicionStore('private').save({'p1': const SuspicionNote(text: 'SECRET', mark: 'trust')});
    expect(jsonEncode(player.toPublicJson()), isNot(contains('SECRET')));
    expect(player.toPublicJson().containsKey('note'), isFalse);
  });
}
