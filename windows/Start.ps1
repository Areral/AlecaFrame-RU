$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AlecaFrameRU.psm1') -Force

$appId          = Get-AfruAppId
$repoRoot       = Split-Path -Parent $PSScriptRoot
$localizer      = Join-Path (Join-Path $repoRoot 'dist') 'alecaframe-ru.js'
$extensionsRoot = Join-Path $env:LOCALAPPDATA "Overwolf\Extensions\$appId"
$logRoot        = Join-Path $env:LOCALAPPDATA 'Overwolf\Log'
$stateRoot      = Join-Path $env:LOCALAPPDATA 'AlecaFrame-RU'
$consentFile    = Join-Path $stateRoot 'consent-v1'
$reportOnlyFile = Join-Path $stateRoot 'report-only-v1'
$launcherLog    = Join-Path $stateRoot 'launcher.log'
$disableFlag    = '--ow-disable-features=extension-validation,read-opk-from-memory'
# Новые сборки Overwolf (0.310.1.1 у DDA-007/AlecaFrame-ZH) закрывают изменённое приложение и с $disableFlag.
# Этот флаг оставляет проверку, но переводит её в режим «только записать в журнал».
$reportOnlyFlag = '--ow-enable-features=force-validation-report-only'

function Write-Log([string]$Message) {
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    Add-Content -LiteralPath $launcherLog -Value ("{0} {1}" -f (Get-Date -Format o), $Message) -Encoding UTF8
}

function Step([string]$Message) { Write-Host "  $Message"; Write-Log $Message }

function Read-Yes([string]$Prompt) { "$(Read-Host $Prompt)".Trim() -match '^(да|д|y|yes)$' }

function Confirm-Consent {
    if (Test-Path -LiteralPath $consentFile) { return }
    Write-Host ''
    Write-Host '  AlecaFrame-RU: русский интерфейс для AlecaFrame' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Что сейчас произойдёт:'
    Write-Host '   1. Overwolf будет закрыт и запущен заново (все его приложения перезапустятся).'
    Write-Host '   2. В 9 страниц AlecaFrame будет добавлена одна строка, подключающая файл перевода.'
    Write-Host '   3. Пока открыто это окно, Overwolf работает с ОТКЛЮЧЕННОЙ проверкой целостности'
    Write-Host '      файлов приложений (флаг extension-validation). Это касается ВСЕХ приложений Overwolf,'
    Write-Host '      не только AlecaFrame. Без этого Overwolf закрыл бы изменённый AlecaFrame.'
    Write-Host '   4. Когда вы выйдете из Overwolf, все файлы вернутся в исходное состояние.'
    Write-Host ''
    Write-Host '  Подписка и платные функции не затрагиваются. Реклама остаётся как есть, пока вы сами'
    Write-Host '  не свернёте её блок: Настройки -> AlecaFrame-RU.'
    Write-Host ''
    if (-not (Read-Yes '  Продолжить? (да / нет)')) {
        throw [System.OperationCanceledException]::new('Отменено, ничего не изменено.')
    }
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    Set-Content -LiteralPath $consentFile -Value (Get-Date -Format o)
}

function Confirm-ReportOnly {
    if (Test-Path -LiteralPath $reportOnlyFile) { return $true }
    Write-Host ''
    Write-Host '  Ваша сборка Overwolf проверяет файлы даже с флагом extension-validation и закрыла' -ForegroundColor Yellow
    Write-Host '  изменённый AlecaFrame (HashMismatch). Файлы AlecaFrame уже возвращены в исходное состояние.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Можно перезапустить Overwolf с ещё одним флагом: force-validation-report-only.'
    Write-Host '  С ним Overwolf по-прежнему сверяет файлы, но о несовпадениях только пишет в свой журнал'
    Write-Host '  и не закрывает приложение. Как и первый флаг, это касается ВСЕХ приложений Overwolf'
    Write-Host '  и действует, только пока открыто это окно. Так же запускает китайский перевод DDA-007.'
    Write-Host ''
    if (-not (Read-Yes '  Перезапустить Overwolf с этим флагом? Ответ запомнится. (да / нет)')) { return $false }
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    Set-Content -LiteralPath $reportOnlyFile -Value (Get-Date -Format o)
    Write-Log 'Пользователь разрешил force-validation-report-only.'
    $true
}

function Wait-LogLine([string]$Path, [string]$Pattern, [datetime]$Since, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $failure = Get-AfruIntegrityFailure -Since $Since -LogRoot $logRoot
        if ($failure) {
            $script:integrityFailure = $failure
            throw 'Overwolf закрыл AlecaFrame из-за проверки файлов (HashMismatch).'
        }
        if (Test-Path -LiteralPath $Path) {
            $item = Get-Item -LiteralPath $Path
            if ($item.LastWriteTime -ge $Since.AddSeconds(-2) -and
                (Get-Content -LiteralPath $Path -Tail 80 -ErrorAction SilentlyContinue) -match $Pattern) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    $false
}

# Overwolf может перезапуститься сам (например, после обновления) и потерять флаги.
function Assert-Flags([string[]]$Flags) {
    $processes = @(Get-AfruOverwolfProcess)
    $state = Get-AfruFlagState -Processes $processes -Flags $Flags
    if ($state -ne $script:flagState) {
        $script:flagState = $state
        Write-Log "Флаги в командной строке Overwolf: $state"
        foreach ($process in $processes) { Write-Log "  $($process.Path) $($process.CommandLine)" }
    }
    if ($state -eq 'none') { throw 'Overwolf закрылся во время запуска. Запустите Start.cmd ещё раз.' }
    if ($state -eq 'missing') {
        throw ('Overwolf работает без нужного флага: скорее всего, он обновился и перезапустился сам. ' +
               "Запустите Start.cmd ещё раз. Если повторится, создайте issue и приложите журнал: $launcherLog")
    }
}

function Write-IntegrityDiagnostics {
    $failure = $script:integrityFailure
    if (-not $failure) { return }
    Write-Log "HashMismatch: $($failure.Line)"
    Write-Log "Журнал Overwolf: $($failure.Trace)"
    foreach ($line in (Get-AfruTraceExcerpt -Trace $failure.Trace)) { Write-Log "  trace: $line" }
}

function Invoke-Session([bool]$ReportOnly) {
    $flags = @($disableFlag)
    if ($ReportOnly) { $flags += $reportOnlyFlag }
    $script:flagState = $null
    $script:integrityFailure = $null

    Step 'Закрываю Overwolf...'
    Stop-AfruOverwolf
    # На случай прерванного прошлого запуска.
    $null = Remove-AfruLocalizer -VersionPath $versionDir.FullName -ExtensionsRoot $extensionsRoot -BackupRoot $backupRoot

    if ($ReportOnly) { Step 'Запускаю Overwolf (проверка файлов только пишет в журнал)...' } else { Step 'Запускаю Overwolf...' }
    Write-Log ('Флаги: ' + ($flags -join ' '))
    $startedAt = Get-Date
    $script:overwolfStarted = $true
    Start-Process -FilePath $install.Overwolf -ArgumentList $flags
    $null = Wait-AfruOverwolf -TimeoutSeconds 60
    Assert-Flags $flags

    # Первый запуск идёт на нетронутых файлах, чтобы AlecaFrame спокойно инициализировался.
    Step 'Запускаю AlecaFrame...'
    $null = Start-AfruApp -Launcher $install.Launcher -TimeoutSeconds 120 -Since $startedAt
    $bgLog = Join-Path $env:LOCALAPPDATA 'Overwolf\Log\Apps\AlecaFrame\BackGround.html.log'
    if (-not (Wait-LogLine $bgLog 'Plugin initialization successful!' $startedAt 90)) {
        Write-Log 'Нет сообщения об инициализации за 90 с, продолжаю.'
    }
    Start-Sleep -Seconds 3
    Assert-Flags $flags

    Step 'Подключаю русский интерфейс...'
    $patchedAt = Get-Date
    $pages = Add-AfruLocalizer -VersionPath $versionDir.FullName -ExtensionsRoot $extensionsRoot `
        -LocalizerSource $localizer -BackupRoot $backupRoot
    Write-Log ("Страницы: " + ($pages -join ', '))
    Stop-AfruRenderer
    Start-Sleep -Seconds 3
    $null = Start-AfruApp -Launcher $install.Launcher -TimeoutSeconds 120 -Since $patchedAt

    $mainLog = Join-Path $env:LOCALAPPDATA 'Overwolf\Log\Apps\AlecaFrame\MainWindow.html.log'
    if (-not (Wait-LogLine $mainLog '\[AlecaFrame-RU\] loaded' $patchedAt 60)) {
        throw "Перевод не загрузился (в журнале AlecaFrame нет отметки). Подробности: $launcherLog"
    }
}

$install = $null
$versionDir = $null
$backupRoot = $null
$script:overwolfStarted = $false
$script:integrityFailure = $null
$script:flagState = $null
$failed = $false
try {
    Write-Host ''
    if (-not (Test-Path -LiteralPath $localizer)) { throw "Не найден файл перевода: $localizer" }
    Confirm-Consent

    $install = Find-AfruOverwolf
    $versionDir = Get-AfruVersionDirectory -ExtensionsRoot $extensionsRoot
    $backupRoot = Join-Path (Join-Path $stateRoot 'backup') $versionDir.Name
    $overwolfVersion = (Get-Item -LiteralPath $install.Overwolf).VersionInfo.FileVersion
    Step "AlecaFrame $($versionDir.Name), Overwolf $overwolfVersion ($($install.Overwolf))"

    $reportOnly = Test-Path -LiteralPath $reportOnlyFile
    try {
        Invoke-Session $reportOnly
    }
    catch {
        if ($reportOnly -or -not $script:integrityFailure) { throw }
        Write-IntegrityDiagnostics
        $script:integrityFailure = $null
        Write-Log 'HashMismatch при флаге extension-validation: возвращаю файлы и предлагаю force-validation-report-only.'
        Stop-AfruOverwolf
        $null = Remove-AfruLocalizer -VersionPath $versionDir.FullName -ExtensionsRoot $extensionsRoot -BackupRoot $backupRoot
        if (-not (Confirm-ReportOnly)) {
            throw [System.OperationCanceledException]::new(
                'Отменено. Файлы AlecaFrame возвращены. Запустите Overwolf как обычно, AlecaFrame будет на английском.')
        }
        Invoke-Session $true
    }

    Write-Host ''
    Write-Host '  Готово: AlecaFrame на русском.' -ForegroundColor Green
    Write-Host '  НЕ ЗАКРЫВАЙТЕ это окно. Когда закончите, выйдите из Overwolf (значок в трее -> Exit):'
    Write-Host '  файлы AlecaFrame вернутся в исходное состояние, и окно закроется само.'
    Write-Log 'Русский интерфейс загружен.'
    while (Get-Process -Name 'Overwolf' -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 }
    Write-Log 'Overwolf закрыт пользователем.'
}
catch [System.OperationCanceledException] {
    Write-Host "  $($_.Exception.Message)"
    exit 0
}
catch {
    $failed = $true
    $message = $_.Exception.Message
    if ($script:integrityFailure) {
        Write-IntegrityDiagnostics
        $message = ('Overwolf закрыл AlecaFrame (HashMismatch) даже с флагом force-validation-report-only: ' +
                    "с этой сборкой Overwolf перевод пока не работает. Создайте issue и приложите журнал: $launcherLog")
    }
    Write-Log "ОШИБКА: $message"
    Write-Host ''
    Write-Host "  Ошибка: $message" -ForegroundColor Red
    Write-Host '  Файлы AlecaFrame возвращаются в исходное состояние. Если AlecaFrame всё равно не открывается, запустите Uninstall.cmd.'
    exit 1
}
finally {
    if ($versionDir) {
        if ($script:overwolfStarted -and $failed) {
            try { Stop-AfruOverwolf } catch { Write-Log "ОШИБКА при закрытии Overwolf: $($_.Exception.Message)" }
        }
        try {
            $null = Remove-AfruLocalizer -VersionPath $versionDir.FullName -ExtensionsRoot $extensionsRoot -BackupRoot $backupRoot
            Write-Log 'Файлы AlecaFrame возвращены в исходное состояние.'
        }
        catch { Write-Log "ОШИБКА при возврате файлов: $($_.Exception.Message)" }
    }
}
