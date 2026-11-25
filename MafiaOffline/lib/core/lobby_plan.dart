import 'constants.dart';

/// Состояние кнопки «Старт» в лобби и подписи к нему.
///
/// Вынесено из экрана в чистую модель по одной причине: это единственное
/// место, где решается, можно ли начать партию без полного стола. Ошибка
/// здесь либо блокирует игру («жду ещё троих»), либо запускает её молча
/// на двоих. Проверяется тестом без виджетов и без сервера.
class LobbyPlan {
  /// Сколько игроков уже в лобби: люди, боты и локальный игрок ведущего.
  final int players;

  /// Сколько игроков запланировал ведущий при создании партии.
  final int planned;

  /// Сколько из [players] — боты.
  final int bots;

  const LobbyPlan({
    required this.players,
    required this.planned,
    required this.bots,
  });

  /// Сколько ботов ещё можно добавить, не выходя за размер стола.
  int get botRoom => botRoomFor(players: players, planned: planned);

  /// До минимально играбельного стола не хватает.
  int get missing => players >= Rules.minPlayers ? 0 : Rules.minPlayers - players;

  /// Стол достиг минимума: боты не нужны, но и не мешают.
  bool get enough => missing == 0;

  /// Все запланированные места заняты.
  bool get full => planned > 0 && players >= planned;

  /// Кнопка «Старт» активна, только если за столом есть живой игрок.
  ///
  /// Боты одни — это не партия: движок отыграл бы её сам, а ведущий смотрел
  /// бы, как пять автоматов голосуют друг за друга. Такой «старт» выглядит
  /// как поломка, поэтому он запрещён. Ведущий лечится одной кнопкой
  /// «Играть одному» — она и сажает его за стол.
  bool get canStart => humans > 0;

  /// Подпись на кнопке старта.
  ///
  /// Отдельная ветка для «за столом только боты»: кнопка при этом
  /// неактивна, и надпись должна объяснять причину, а не звать в партию
  /// без единого живого игрока.
  String get startLabel {
    if (players == 0) return 'Ждём игроков';
    if (humans == 0) return 'Займите место — «Играть одному»';
    if (full) return 'Старт игры — раздать роли';
    if (!enough) return 'Начать — добрать $missing ${botWord(missing)}';
    return 'Начать партию: $players ${playerWord(players)}';
  }

  /// Пояснение под кнопкой. null — пояснять нечего.
  String? get startHint {
    if (players == 0) {
      return 'Подключитесь по QR или нажмите «Играть одному»';
    }
    if (humans == 0) {
      return 'За столом только боты. Нажмите «Играть одному» — '
          'вы займёте место одного из них.';
    }
    if (!enough) {
      return 'При старте автоматически добавится '
          '$missing ${botWord(missing)}';
    }
    return null;
  }

  /// Короткая сводка состава для карточки ботов.
  String get composition => 'людей: $humans · ботов: $bots';

  /// Живые люди за столом (включая ведущего, если он играет сам).
  int get humans => players - bots;
}

/// Сколько ботов можно добавить, не выходя за размер стола.
///
/// Верхняя граница — не только 20 (жёсткий лимит движка), но и размер,
/// выбранный ведущим при создании партии: если он собрал стол на 8,
/// «+1 бот» не должен делать из него 9 игроков втихую.
int botRoomFor({required int players, required int planned}) {
  final ceiling = planned > 0 && planned < Rules.maxPlayers
      ? planned
      : Rules.maxPlayers;
  final room = ceiling - players;
  return room > 0 ? room : 0;
}

/// Склонение «бот» по числу: 1 бот, 2 бота, 5 ботов.
String botWord(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return 'бот';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return 'бота';
  }
  return 'ботов';
}

/// Склонение «игрок» по числу: 1 игрок, 2 игрока, 5 игроков.
String playerWord(int count) {
  final mod10 = count % 10;
  final mod100 = count % 100;
  if (mod10 == 1 && mod100 != 11) return 'игрок';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return 'игрока';
  }
  return 'игроков';
}
