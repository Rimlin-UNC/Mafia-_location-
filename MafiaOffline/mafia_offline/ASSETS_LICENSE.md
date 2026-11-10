# Лицензии ассетов

## Звуковые эффекты — CC0 (Public Domain)

17 файлов в `assets/sounds/*.ogg` собраны из паков [OpenGameArt.org](https://opengameart.org) под лицензией **CC0 1.0 Universal**: общественное достояние, использование в любых целях, включая коммерческие, **атрибуция не требуется**.

| Пак | Автор | Что взято |
|---|---|---|
| [50 RPG Sound Effects](https://opengameart.org/content/50-rpg-sound-effects) | Kenney | `kill` (knifeSlice), `night_falls` (doorClose), `block` (creak), `reveal_card`/`hide_card` (book) |
| [80 CC0 RPG SFX](https://opengameart.org/content/80-cc0-rpg-sfx) | rubberduck | `heal` (spell), `check` (lock), `eliminated` (creature_die), `win_*`, `day_breaks`, `player_joined` |
| [54 Casino Sound Effects](https://opengameart.org/content/54-casino-sound-effects-cards-dice-chips) | Kenney | `roles_dealt` (card-shuffle), `tap` (chip-lay) |

Атрибуция не обязательна, но авторы её приветствуют — таблица выше выполняет эту роль.

## Атмосферные фоны — собственные

`night_ambient.wav`, `day_ambient.wav`, `vote_ambient.wav` синтезированы numpy специально для проекта (аддитивный синтез: дрон, имитация сердцебиения, отфильтрованный шум, тиканье). Принадлежат проекту, ограничений нет.

## Изображения — сгенерированы ИИ

Карты в `assets/cards/` и фоны `bg_night`, `bg_day` в `assets/images/` созданы генеративной моделью по заказу проекта. `bg_vote.jpg` и `hide_shield.png` отрисованы кодом (PIL).

Правовой статус ИИ-изображений различается по юрисдикциям: в США такие работы, как правило, не охраняются авторским правом; в ряде стран вопрос не урегулирован. Для коммерческого релиза стоит либо свериться с условиями использованного сервиса, либо заменить карты на работу иллюстратора.
