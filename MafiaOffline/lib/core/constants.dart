/// Общие константы приложения.
library;

class Net {
  /// Порт HTTP/WebSocket сервера ведущего.
  static const int gamePort = 8088;

  /// Порт UDP-обнаружения. Клиент шлёт сюда широковещательный запрос,
  /// ведущий отвечает своим IP-адресом.
  static const int discoveryPort = 45455;

  /// Версия протокола обмена сообщениями.
  static const int protocolVersion = 1;

  /// Периодичность ping от клиента.
  static const Duration pingInterval = Duration(seconds: 5);

  /// Через сколько без ping ведущий считает игрока отключившимся.
  static const Duration pingTimeout = Duration(seconds: 12);

  /// Как часто ведущий рассылает точное время таймера
  /// (между рассылками клиент считает сам).
  static const Duration timeSyncInterval = Duration(seconds: 3);

  /// Фора перед синхронным звуком: за это время команда успевает
  /// дойти до самого «медленного» телефона, и все стартуют вместе.
  static const Duration soundLeadTime = Duration(milliseconds: 350);

  /// Если команда опоздала больше чем на столько — играем сразу,
  /// без попытки попасть в общий момент.
  static const Duration soundMaxLateness = Duration(milliseconds: 1200);

  /// Попытки автоматического переподключения на клиенте.
  static const int reconnectAttempts = 3;
  static const Duration reconnectDelay = Duration(seconds: 2);
}

class Rules {
  static const int minPlayers = 6;
  static const int maxPlayers = 20;

  // Тайминги подобраны под реальную скорость людей за столом.
  // Проверено моделированием: человеку нужно 10-15 с на ночной ход
  // (открыть экран, прочитать список, выбрать, подтвердить) и 8-12 с
  // на голосование. Прежние значения давали 3 с на ход при 20 игроках —
  // фазы обрывались по таймауту, не дождавшись половины стола.

  /// Ночь = base + perActive * (число активных ночью живых игроков)
  static const int nightBaseSeconds = 20;
  static const int nightPerActiveSeconds = 10;

  /// День = perPlayer * (число живых), но не дольше [dayMaxSeconds]:
  /// 20 минут обсуждения одной фазой — слишком много, ведущий всё равно
  /// закрывает её вручную.
  static const int dayPerPlayerSeconds = 45;
  static const int dayMaxSeconds = 600;

  /// Голосование = base + perPlayer * (число живых)
  static const int votingBaseSeconds = 20;
  static const int votingPerPlayerSeconds = 4;
  static const int runoffBaseSeconds = 15;
  static const int runoffPerPlayerSeconds = 3;
}

/// Цвет по порядковому номеру слота. Фиксированная привязка, а не «первый
/// свободный»: иначе вернувшийся в свой слот игрок получал бы другой цвет,
/// если его прежний успел занять новый человек. Слотов ровно столько же,
/// сколько цветов (в партии не больше [Rules.maxPlayers]).
String colorForSlot(int slot) => kPlayerColors[slot % kPlayerColors.length];

/// Палитра цветов игроков. Цвета не повторяются в рамках партии.
const List<String> kPlayerColors = [
  '#FF5733', '#33FF57', '#3357FF', '#FF33A1', '#FFD733',
  '#33FFF5', '#F533FF', '#F5A623', '#7ED321', '#4A90E2',
  '#E94E77', '#50E3C2', '#B8E986', '#BD10E0', '#F8E71C',
  '#9013FE', '#417505', '#D0021B', '#8B572A', '#00BCD4',
];
