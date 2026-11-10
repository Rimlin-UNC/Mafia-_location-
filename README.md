# Mafia — офлайн-игра «Мафия» (локальный сервер на телефоне ведущего)

Репозиторий содержит проект **«Мафия Offline» (v1.0.5+5)** — игру, которая работает
**полностью без интернета**: ведущий разворачивает сервер на своём Android-телефоне
(точка доступа Wi-Fi), а игроки заходят **в обычном браузере** по QR-коду — устанавливать
им ничего не нужно.

> **Вся работа с проектом ведётся в папке [`MafiaOffline/`](MafiaOffline/).**
> Корень репозитория — только точка входа и этот README.

---

## Структура репозитория

```
Mafia-_location-/
├── README.md                  ← этот файл (точка входа)
├── LICENSE                    ← MIT, © 2026 Rimlin-UNC
├── .gitignore                 ← исключает *.apk, *.keystore, local.properties, build/
└── MafiaOffline/              ← ВСЁ по проекту «Мафия Offline» (см. ниже)
    ├── README.md              ← краткая памятка проекта (из исходного архива)
    ├── ПОЛНОЕ_ОПИСАНИЕ_ПРОЕКТА.md  ← полное архитектурное описание (79 КБ)
    ├── MafiaOffline-project-1.0.5.zip  ← исходный чистый архив (7,2 МБ, 271 файл)
    ├── mafia_offline/         ← сам Flutter-проект (отсюда собирается APK)
    │   ├── lib/               ← Dart-код: core, models, net, host, player, services, storage, ui
    │   ├── assets/            ← карты, звуки, фоны, веб-клиент (assets/web/)
    │   ├── android/           ← Android-обёртка (applicationId com.example.mafia_offline)
    │   ├── ios/               ← iOS-обёртка (сборка для iPhone — Mac + Xcode)
    │   ├── test/              ← 37 юнит-тестов (game_engine_test, wifi_qr_test, widget_test)
    │   └── tools/             ← Python-стенды: demo20, stress, load20, browser_test и др.
    ├── docs/                  ← документация, макеты, отчёты, ТЗ
    ├── uploads/               ← исходный файл заказчика (mafia.txt)
    ├── keystore/              ← debug.keystore (подпись APK; в git не коммитится)
    └── apk/                   ← готовые APK (в git не коммитятся, см. ниже)
```

Полный инвентарь с привязкой к Google Диску: [`MafiaOffline/ИНВЕНТАРЬ.md`](MafiaOffline/ИНВЕНТАРЬ.md).

---

## Быстрый старт

### Для ведущего (играть)

1. Поставить APK только на телефон ведущего (см. `MafiaOffline/apk/` или Google Диск).
2. Прочитать [`MafiaOffline/docs/ВЕДУЩЕМУ.md`](MafiaOffline/docs/ВЕДУЩЕМУ.md) — как провести партию.
3. Включить точку доступа → «Я ведущий» → состав → показать QR-код.
4. Игроки сканируют QR камерой → открывается браузер → имя → лобби → игра.

Интернет не нужен: достаточно раздачи Wi-Fi с телефона ведущего.

### Для разработчика (собрать)

```bash
cd MafiaOffline/mafia_offline
flutter pub get
flutter build apk --release
# Готовый файл: build/app/outputs/flutter-apk/app-release.apk
```

Требования: Flutter 3.24.x, Dart `>=3.0.0 <4.0.0`, JDK 17 (не Java 25 — см.
[`docs/ОШИБКА_СБОРКИ.md`](MafiaOffline/docs/ОШИБКА_СБОРКИ.md)).

Проверки:

```bash
cd MafiaOffline/mafia_offline
flutter test                    # 37 юнит-тестов
python3 tools/demo20.py         # демо-партия на 20 игроков
python3 tools/stress.py         # 400 партий, проверка инвариантов
bash    tools/run_test.sh       # веб-клиент: HTTP + WebSocket
```

---

## Ключевая архитектура (кратко)

```
ТЕЛЕФОН ВЕДУЩЕГО (APK)                     КЛИЕНТЫ
HttpServer :8088 ── GET / ──▶ 🌐 браузер (iPhone / Android / ноутбук)
  ├── статика веб-клиента (assets/web/)
  └── WS /ws ──▶ 📱 нативный клиент (резервный режим игрока в APK)
UDP :45455 — автопоиск ведущего
Вся игровая логика — на телефоне ведущего (HostController + GameEngine)
```

- **Сеть:** чистый `dart:io` (без внешних серверов), WebSocket + JSON-протокол.
- **Игроки:** браузерный и нативный клиенты неотличимы для сервера, могут играть в одной партии.
- **Почему не Bluetooth:** лимит Android `BTA_GATTC_CONN_MAX = 7` (стабильно 4–6), Wi-Fi держит 20 устройств.
- **Роли (7):** мафия, дон, доктор, комиссар, проститутка, маньяк, мирный житель. Состав 6–20 игроков.
- **Детали:** [`MafiaOffline/ПОЛНОЕ_ОПИСАНИЕ_ПРОЕКТА.md`](MafiaOffline/ПОЛНОЕ_ОПИСАНИЕ_ПРОЕКТА.md) (14 разделов).

---

## Готовые APK и ключ подписи

| Файл | Размер | Назначение |
|---|---|---|
| `MafiaOffline-1.0.5-arm64.apk` | 25 МБ | актуальная версия, телефоны 2018+ (64-bit) |
| `MafiaOffline-1.0.4-arm64.apk` | 24 МБ | предыдущая версия (архив) |
| `MafiaOffline-1.0.4-universal.apk` | 37 МБ | предыдущая версия, любой телефон (архив) |

- APK лежат в `MafiaOffline/apk/` локально, но **в git не коммитятся** (`.gitignore`: `*.apk`).
  Источник правды для APK — Google Диск (папка «Мафия Offline (v1.0.5)»), см. инвентарь.
- Ключ подписи `MafiaOffline/keystore/debug.keystore` (SHA-256 `117b5d7e…9b6dff`)
  также в git не коммитится (`.gitignore`: `*.keystore`). Без него нельзя выпустить
  обновление поверх установленной версии — храните резервную копию отдельно.
- В `MafiaOffline/README.md` также упоминается `MafiaOffline-1.0.5-universal.apk` (39 МБ) —
  на Диске в папке проекта его нет, есть только arm64-сборка 1.0.5. См. открытые вопросы
  в [`docs/OPEN_QUESTIONS.md`](MafiaOffline/docs/OPEN_QUESTIONS.md).

---

## Документация

| Файл | О чём |
|---|---|
| [`MafiaOffline/ПОЛНОЕ_ОПИСАНИЕ_ПРОЕКТА.md`](MafiaOffline/ПОЛНОЕ_ОПИСАНИЕ_ПРОЕКТА.md) | полное архитектурное описание (основной документ разработчика) |
| [`MafiaOffline/README.md`](MafiaOffline/README.md) | краткая памятка проекта |
| [`MafiaOffline/docs/ВЕДУЩЕМУ.md`](MafiaOffline/docs/ВЕДУЩЕМУ.md) | как провести партию |
| [`MafiaOffline/docs/УСТАНОВКА.md`](MafiaOffline/docs/УСТАНОВКА.md) | установка и первый запуск |
| [`MafiaOffline/docs/CHANGELOG_1.0.5.md`](MafiaOffline/docs/CHANGELOG_1.0.5.md) | изменения 1.0.5 (веб-режим, устойчивость) |
| [`MafiaOffline/docs/CHANGELOG_1.0.4.md`](MafiaOffline/docs/CHANGELOG_1.0.4.md) | изменения 1.0.4 |
| [`MafiaOffline/docs/CHANGELOG_1.0.3.md`](MafiaOffline/docs/CHANGELOG_1.0.3.md) | изменения 1.0.3 |
| [`MafiaOffline/docs/WEB_SERVER.md`](MafiaOffline/docs/WEB_SERVER.md) | устройство веб-сервера |
| [`MafiaOffline/docs/TEST_REPORT.md`](MafiaOffline/docs/TEST_REPORT.md) | отчёт о тестировании |
| [`MafiaOffline/docs/OPEN_QUESTIONS.md`](MafiaOffline/docs/OPEN_QUESTIONS.md) | открытые вопросы и принятые решения |
| [`MafiaOffline/docs/ТЗ_Мафия_Offline_v1.0.docx`](MafiaOffline/docs/ТЗ_Мафия_Offline_v1.0.docx) | техническое задание |
| [`MafiaOffline/ИНВЕНТАРЬ.md`](MafiaOffline/ИНВЕНТАРЬ.md) | сверка Google Диск ↔ локальные файлы |

---

## Разработка по регламенту (кратко)

Работа ведётся по полному циклу из ТЗ заказчика: трассируемость
(требование → задача → тест → код → приёмка), итерации от MVP, quality gates
(DoR / PR Gate / Release Gate / DoD), атомарные PR, без секретов в коде,
ADR для критичных решений, подтверждение человека перед прод-деплоем.
Формат отчёта: *Статус / Требование / Изменения / Тесты / CI / Риски / Следующий шаг*.

Текущий статус на момент переноса (2026-11-10): исходники v1.0.5+5 перенесены
из Google Диска в `MafiaOffline/`, инвентарь сверен. Следующий шаг — по выбору
заказчика (например: проверка на реальных устройствах, доработка по
`OPEN_QUESTIONS.md`, или новая фича по ТЗ).

---

## Источник файлов

Все файлы перенесены из Google Диска, папка **«Мафия Offline (v1.0.5)»**
(идентификатор `1id4vkIAfA33te3-NFCY9NUUv9G2gGNQl`). Прямые ссылки и сверка —
в [`MafiaOffline/ИНВЕНТАРЬ.md`](MafiaOffline/ИНВЕНТАРЬ.md).
