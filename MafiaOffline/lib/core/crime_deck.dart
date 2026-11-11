import '../models/role.dart';

/// Способы, которыми мафия убирает игрока. Влияют только на текст:
/// на правила, очерёдность и подсчёт голосов не влияют никак.
///
/// Зачем это нужно: сухое «Ночь 1: погиб Вася» — это строка в логе.
/// «Ночь 1: Вася — отравлен в ресторане» — это сцена, которую за столом
/// обсуждают. Ведущий читает способ вслух, приложение пишет его в протокол.
enum CrimeType {
  shooting,
  strangulation,
  drowning,
  poison,
  fall,
  bomb,
  knife,
  train,
  gas,
  electricity,
}

/// Карточка злодеяния: как назвать и что сказать вслух.
class Crime {
  final CrimeType type;

  /// Короткое название для протокола: «Огнестрел».
  final String name;

  /// Фраза для оглашения: «снят выстрелом в переулке».
  final String phrase;

  /// Карточка-иллюстрация. Может отсутствовать: тогда в UI остаётся
  /// только текст, и это нормально — картинка не обязательна.
  final String? image;

  const Crime({
    required this.type,
    required this.name,
    required this.phrase,
    this.image,
  });

  static const List<Crime> all = [
    Crime(
      type: CrimeType.shooting,
      name: 'Огнестрел',
      phrase: 'снят выстрелом в переулке',
      image: 'assets/crimes/01_shooting.jpg',
    ),
    Crime(
      type: CrimeType.strangulation,
      name: 'Удушение',
      phrase: 'задушен в подсобке',
      image: 'assets/crimes/02_strangulation.jpg',
    ),
    Crime(
      type: CrimeType.drowning,
      name: 'Утопление',
      phrase: 'утоплен в канале',
      image: 'assets/crimes/03_drowning.jpg',
    ),
    Crime(
      type: CrimeType.poison,
      name: 'Яд',
      phrase: 'отравлен за ужином',
      image: 'assets/crimes/04_poison.jpg',
    ),
    Crime(
      type: CrimeType.fall,
      name: 'Падение',
      phrase: 'сорвался с пожарной лестницы',
      image: 'assets/crimes/05_fall.jpg',
    ),
    Crime(
      type: CrimeType.bomb,
      name: 'Взрыв',
      phrase: 'погиб при взрыве автомобиля',
      image: 'assets/crimes/06_bomb.jpg',
    ),
    Crime(
      type: CrimeType.knife,
      name: 'Нож',
      phrase: 'найден с ножом в переулке',
      image: 'assets/crimes/07_knife.jpg',
    ),
    Crime(
      type: CrimeType.train,
      name: 'Поезд',
      phrase: 'не дождался поезда на платформе',
      image: 'assets/crimes/08_train.jpg',
    ),
    Crime(
      type: CrimeType.gas,
      name: 'Газ',
      phrase: 'задохнулся от газа в квартире',
      image: 'assets/crimes/09_gas.jpg',
    ),
    Crime(
      type: CrimeType.electricity,
      name: 'Электричество',
      phrase: 'убит током в подвале',
      image: 'assets/crimes/10_electricity.jpg',
    ),
  ];

  static Crime of(CrimeType type) =>
      all.firstWhere((c) => c.type == type, orElse: () => all.first);

  /// Только огнестрел доступен мафии-стрелку по умолчанию: остальные
  /// способы — «как это выглядело», их выбирает ведущий для атмосферы.
  static const CrimeType defaultMafia = CrimeType.shooting;

  /// Строка для протокола партии.
  String logLine(String victim) => '$victim — $phrase';
}

/// Кто может «украсить» смерть способом: мафия и маньяк.
/// Город выгоняет голосованием — там способ не нужен.
bool crimeAppliesTo(RoleType? role) =>
    role == RoleType.mafia || role == RoleType.don || role == RoleType.maniac;
