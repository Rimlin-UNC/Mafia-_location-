# Диагностика окружения сборки Мафия Offline
# Запуск:  powershell -ExecutionPolicy Bypass -File проверка-java.ps1
#
# Скрипт ничего не меняет — только смотрит и печатает отчёт.
# В конце подсказывает готовые команды под вашу ситуацию.

$ErrorActionPreference = "SilentlyContinue"

function Строка($t) { Write-Host $t }
function Заголовок($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Хорошо($t) { Write-Host "  [OK]  $t" -ForegroundColor Green }
function Плохо($t) { Write-Host "  [!!]  $t" -ForegroundColor Red }
function Инфо($t) { Write-Host "         $t" -ForegroundColor DarkGray }

Заголовок "Текущая JAVA_HOME"

$jh = $env:JAVA_HOME
if (-not $jh) {
    Плохо "JAVA_HOME не задана"
} elseif (Test-Path "$jh\bin\java.exe") {
    $v = & "$jh\bin\java.exe" -version 2>&1 | Select-Object -First 1
    Хорошо "$jh"
    Инфо $v
} else {
    Плохо "JAVA_HOME указывает в пустоту: $jh"
    Инфо "Папки нет — именно из-за этого падает сборка."
}

Заголовок "Поиск установленных JDK"

# Обычные места, куда попадают JDK на Windows
$корни = @(
    "C:\Program Files\Eclipse Adoptium",
    "C:\Program Files\Java",
    "C:\Program Files\Microsoft",
    "C:\Program Files\Amazon Corretto",
    "C:\Program Files\Zulu",
    "$env:LOCALAPPDATA\Programs\Eclipse Adoptium"
)

$найдено = @()

foreach ($к in $корни) {
    if (Test-Path $к) {
        Get-ChildItem $к -Directory | ForEach-Object {
            if (Test-Path "$($_.FullName)\bin\java.exe") { $найдено += $_.FullName }
        }
    }
}

# JDK внутри Android Studio — она есть почти у всех
foreach ($п in @("C:\Program Files\Android\Android Studio\jbr",
                 "C:\Program Files\Android\Android Studio\jre")) {
    if (Test-Path "$п\bin\java.exe") { $найдено += $п }
}

if ($найдено.Count -eq 0) {
    Плохо "Ни одной JDK не найдено"
    Инфо "Скачайте Temurin JDK 17 (msi):"
    Инфо "https://adoptium.net/temurin/releases/?version=17"
} else {
    $годная = $null
    foreach ($п in $найдено) {
        $v = & "$п\bin\java.exe" -version 2>&1 | Select-Object -First 1
        # Вытаскиваем мажорную версию: "17.0.13" -> 17
        $major = 0
        if ($v -match 'version "(\d+)') { $major = [int]$matches[1] }

        if ($major -ge 17 -and $major -le 22) {
            Хорошо "$п"
            Инфо "$v  <- подходит"
            if (-not $годная) { $годная = @{ path = $п; major = $major } }
        } else {
            Плохо "$п"
            Инфо "$v  <- не подходит (нужна 17-22)"
        }
    }
}

Заголовок "Что видит Flutter"

$fj = flutter doctor --verbose 2>&1 | Select-String "Java version|Java binary"
if ($fj) { $fj | ForEach-Object { Инфо $_.ToString().Trim() } }
else { Инфо "flutter doctor ничего не сказал про Java" }

Заголовок "Кеш дистрибутивов Gradle"

$dists = "$env:USERPROFILE\.gradle\wrapper\dists"
if (Test-Path $dists) {
    Get-ChildItem $dists -Directory | ForEach-Object { Инфо $_.Name }
    Инфо ""
    Инфо "Проекту нужна только gradle-8.3-all (или 8.9 для Java 21)."
    Инфо "Остальные папки можно удалить, они занимают место."
} else {
    Инфо "Кеш пуст — Gradle скачается при первой сборке."
}

Заголовок "Что делать"

if ($годная) {
    $p = $годная.path
    $m = $годная.major

    Строка ""
    Строка "Выполните три команды:"
    Строка ""
    Write-Host "  [Environment]::SetEnvironmentVariable('JAVA_HOME', '$p', 'User')" -ForegroundColor Yellow
    Write-Host "  flutter config --jdk-dir `"$p`"" -ForegroundColor Yellow
    Строка ""
    Строка "Затем ЗАКРОЙТЕ и заново откройте PowerShell, и собирайте:"
    Строка ""
    Write-Host "  flutter clean; flutter pub get; flutter build apk --release" -ForegroundColor Yellow

    if ($m -ge 21) {
        Строка ""
        Плохо "У вас Java $m — под неё нужна Gradle 8.9, а не 8.3."
        Инфо "Откройте android\gradle\wrapper\gradle-wrapper.properties"
        Инфо "и замените gradle-8.3-all.zip на gradle-8.9-all.zip"
    }
} else {
    Строка ""
    Строка "Сначала установите Temurin JDK 17 (галочка 'Set JAVA_HOME'):"
    Write-Host "  https://adoptium.net/temurin/releases/?version=17" -ForegroundColor Yellow
    Строка ""
    Строка "После установки закройте PowerShell, откройте заново"
    Строка "и запустите этот скрипт ещё раз."
}

Строка ""
