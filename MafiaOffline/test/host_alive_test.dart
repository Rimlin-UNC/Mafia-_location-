import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mafia_offline/net/wifi_joiner.dart';

// Проверка «отвечает ли ведущий» ходит по настоящему HTTP, поэтому тесты
// лежат отдельно: привязка виджетов здесь не создаётся и запросы
// не подменяются заглушкой.
void main() {
  Future<HttpServer> serve(String pingBody, {int status = 200}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = req.uri.path == '/ping' ? status : 404;
      req.response.write(req.uri.path == '/ping' ? pingBody : 'no');
      await req.response.close();
    });
    return server;
  }

  test('ведущий отвечает на /ping — телефон в его сети', () async {
    final server = await serve('ok');
    addTearDown(() => server.close(force: true));
    expect(await WifiJoiner.hostAlive('127.0.0.1', port: server.port), isTrue);
  });

  test('по адресу отвечает кто-то другой — это не ведущий', () async {
    final other = await serve('<html>router</html>');
    addTearDown(() => other.close(force: true));
    expect(await WifiJoiner.hostAlive('127.0.0.1', port: other.port), isFalse);

    final broken = await serve('ok', status: 500);
    addTearDown(() => broken.close(force: true));
    expect(await WifiJoiner.hostAlive('127.0.0.1', port: broken.port), isFalse);
  });

  test('по адресу никого нет — false, без исключения', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    expect(await WifiJoiner.hostAlive('127.0.0.1', port: port), isFalse);
  });
}
