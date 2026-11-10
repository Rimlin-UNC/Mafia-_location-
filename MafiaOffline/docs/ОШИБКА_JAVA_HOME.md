# Ошибка «JAVA_HOME is set to an invalid directory»

```
ERROR: JAVA_HOME is set to an invalid directory:
C:\Program Files\Eclipse Adoptium\jdk-17.0.13.11-hotspot
```

## Хорошая новость

**Первая проблема решена.** Ошибки `Unsupported class file major version 69`
больше нет — значит Java 25 из сборки ушла, Flutter послушался настройки.

Теперь Gradle спотыкается на другом: переменная `JAVA_HOME` указывает на папку,
**которой на диске не существует**. Сборка падает за 107 мс — она даже не
начинается, Gradle просто не находит Java по указанному адресу.

---

## Почему папки нет

Три обычные причины, по убыванию вероятности:

1. **Java 17 ещё не установлена.** Путь был вписан «на будущее» (или скопирован
   из инструкции), а установщик Temurin так и не запускался.
2. **Установлена другая сборка.** Temurin обновляется, и номер версии в имени
   папки меняется: `jdk-17.0.13.11-hotspot` → `jdk-17.0.16.8-hotspot`.
   Путь с точностью до последней цифры перестаёт совпадать.
3. **Установлена в другое место** — например в `C:\Users\Ym\...` вместо
   `C:\Program Files\...`, если при установке был выбран режим «только для меня».

---

## Шаг 1. Посмотрите, что реально лежит на диске

В PowerShell:

```powershell
dir "C:\Program Files\Eclipse Adoptium"
```

**Если папка не существует** («Cannot find path») — Java 17 не установлена,
переходите к шагу 2.

**Если внутри есть папка вида `jdk-17.0.16.8-hotspot`** — Java есть, но номер
версии другой. Пропустите шаг 2, идите сразу к шагу 3 и подставьте
**настоящее** имя папки.

Заодно проверьте, нет ли Java в других обычных местах:

```powershell
dir "C:\Program Files\Java" -ErrorAction SilentlyContinue
dir "C:\Program Files\Android\Android Studio\jbr" -ErrorAction SilentlyContinue
```

---

## Шаг 2. Установите Java 17 (если её нет)

Скачайте **Eclipse Temurin JDK 17, Windows x64, .msi**:

https://adoptium.net/temurin/releases/?version=17

При установке отметьте галочку **«Set JAVA_HOME variable»** — тогда путь
пропишется сам и правильно.

После установки **закройте и заново откройте PowerShell** — переменные среды
подхватываются только новыми окнами.

---

## Шаг 3. Пропишите правильный путь

Сначала уберите сломанное значение и задайте верное. Подставьте то имя папки,
которое реально увидели в шаге 1:

```powershell
$jdk = "C:\Program Files\Eclipse Adoptium\jdk-17.0.16.8-hotspot"
```

Проверьте, что путь живой — команда должна напечатать версию:

```powershell
& "$jdk\bin\java.exe" -version
```

Ожидаемый ответ: `openjdk version "17.0.x"`. Если ошибка — путь всё ещё неверен,
вернитесь к шагу 1.

Теперь задайте переменную **для своего пользователя, навсегда**:

```powershell
[Environment]::SetEnvironmentVariable("JAVA_HOME", $jdk, "User")
```

И скажите Flutter то же самое:

```powershell
flutter config --jdk-dir $jdk
```

**Закройте PowerShell и откройте заново.** Проверьте:

```powershell
echo $env:JAVA_HOME
flutter doctor --verbose | Select-String "Java"
```

---

## Запасной вариант: JDK от Android Studio

Android Studio привозит свою JDK — отдельно ставить ничего не нужно. Проверьте:

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\java.exe" -version
```

Если печатает `17.x` или `21.x` — используйте её:

```powershell
$jdk = "C:\Program Files\Android\Android Studio\jbr"
[Environment]::SetEnvironmentVariable("JAVA_HOME", $jdk, "User")
flutter config --jdk-dir $jdk
```

Только учтите: **если это Java 21**, обновите Gradle до 8.9. Откройте
`android\gradle\wrapper\gradle-wrapper.properties` и замените в последней строке
`gradle-8.3-all.zip` на `gradle-8.9-all.zip`. Проект с 8.9 проверен — собирается
без единой ошибки компиляции.

Соответствие версий:

| Ваша Java | Нужна Gradle |
|---|---|
| 17 | 8.3 (уже прописана) |
| 21 | 8.9 |
| 25 | не поддерживается, нужна Java 17 |

---

## Шаг 4. Сборка

```powershell
cd D:\mafia\android\mafia_offline
flutter clean
flutter pub get
flutter build apk --release
```

Готовый файл: `build\app\outputs\flutter-apk\app-release.apk`

---

## Отдельно: ваша копия проекта устарела

В логе видно два расхождения с тем, что лежит в проекте:

| В вашем логе | В актуальном проекте |
|---|---|
| `package_info_plus 10.2.1 (overridden)` | `8.3.1` |
| `gradle-8.14-all` в кеше | `gradle-8.3-all` |

Значит на диске `D:` лежит **более старая версия проекта**. Она может собраться
и потом падать по причинам, которые давно исправлены.

Распакуйте свежий архив `MafiaOffline-project-1.0.4.zip` в чистую папку и
собирайте оттуда. Заодно очистите кеш Gradle от лишних дистрибутивов:

```powershell
dir "$env:USERPROFILE\.gradle\wrapper\dists"
```

Лишние папки (`gradle-8.14-all` и т.п.) можно удалить — каждая занимает
несколько сотен мегабайт, а нужная скачается сама.
