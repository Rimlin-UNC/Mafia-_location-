import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mafia_offline/net/network_policy.dart';
import 'package:mafia_offline/models/game_state.dart';
import 'package:mafia_offline/models/game_phase.dart';
import 'package:mafia_offline/storage/session_store.dart';
import 'package:mafia_offline/net/web_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('команда привязана к сокету, не к присланному playerId', () {
    expect(NetworkPolicy.ownsCommand(null, 'victim'), isFalse);
    expect(NetworkPolicy.ownsCommand('me', 'victim'), isFalse);
    expect(NetworkPolicy.ownsCommand('me', null), isFalse);
    expect(NetworkPolicy.ownsCommand('me', 'me'), isTrue);
  });
  test('знание имени и ID не заменяет случайное доказательство владения', () {
    expect(NetworkPolicy.ownsSlot(null, null), isFalse);
    expect(NetworkPolicy.ownsSlot('device-0001', null), isFalse);
    expect(NetworkPolicy.ownsSlot('device-0001', 'device-0002'), isFalse);
    expect(NetworkPolicy.ownsSlot('short', 'short'), isFalse);
    expect(NetworkPolicy.ownsSlot('device-0001', 'device-0001'), isTrue);
  });
  test('эпоха защищает и одинаковые фазы, и туры одного раунда', () {
    expect(NetworkPolicy.currentTurn(null, 10), isFalse);
    expect(NetworkPolicy.currentTurn('10', 10), isFalse);
    expect(NetworkPolicy.currentTurn(10.0, 10), isFalse);
    expect(NetworkPolicy.currentTurn(9, 10), isFalse);
    expect(NetworkPolicy.currentTurn(10, 10), isTrue);
  });
  test('записи сессии не обгоняют друг друга; clear завершает очередь', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore();
    final s = GameState(id: 'g', name: 'test', code: '123456', createdAt: DateTime.now(),
      phase: GamePhase.night);
    final writes = [for (var i = 0; i < 20; i++) store.save(s.copyWith(actionEpoch: i))];
    await Future.wait(writes);
    expect((await store.load())!.actionEpoch, 19);
    final pending = store.save(s);
    await store.clear();
    await pending;
    expect(await store.load(), isNull);
  });
  test('одновременные загрузки одного файла используют общий Future', () async {
    WebAssets.clearCache();
    final a = WebAssets.load('/app.js');
    final b = WebAssets.load('/app.js');
    final bytes = await Future.wait([a, b]);
    expect(bytes[0], isNotNull);
    expect(identical(bytes[0], bytes[1]), isTrue);
    expect(WebAssets.cacheBytes, bytes[0]!.length);
    final html = utf8.decode((await WebAssets.load('/', gameCode: '123456'))!);
    expect(html, contains('/app.js?${WebAssets.assetVersion}'));
    expect(html, contains('/style.css?${WebAssets.assetVersion}'));
    WebAssets.clearCache();
  });
}
