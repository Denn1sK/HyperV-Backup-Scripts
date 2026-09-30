<#
.SYNOPSIS
    Интерактивная настройка резервного копирования Hyper-V.

.DESCRIPTION
    Спрашивает папку для бэкапов, срок хранения, режим (все ВМ или список),
    время ежедневного запуска, скрывать ли окно. Сохраняет всё в
    VMBackup\settings.json. Умеет регистрировать/удалять задачу в
    Планировщике заданий.

.PARAMETER RegisterTask
    Зарегистрировать задачу в Планировщике по сохранённым настройкам.

.PARAMETER UnregisterTask
    Удалить задачу из Планировщика.

.PARAMETER Show
    Показать текущий конфиг и статус задачи, ничего не менять.

.EXAMPLE
    .\Setup-VMBackup.ps1
    Пройти настройку заново.

.EXAMPLE
    .\Setup-VMBackup.ps1 -Show
    Посмотреть текущие настройки.

.EXAMPLE
    .\Setup-VMBackup.ps1 -RegisterTask
    Поставить задачу в Планировщик.

.EXAMPLE
    .\Setup-VMBackup.ps1 -UnregisterTask
    Удалить задачу из Планировщика.
#>

[CmdletBinding()]
param(
    [switch]$RegisterTask,
    [switch]$UnregisterTask,
    [switch]$Show
)

# ==============================================================
# Пути и вспомогательные функции
# ==============================================================

$SetupPath    = $PSCommandPath
$SetupDir     = Split-Path -Parent $SetupPath
$BackupScript = Join-Path $SetupDir 'Backup-HyperV.ps1'
$WorkDir      = Join-Path $SetupDir 'VMBackup'
$SettingsFile = Join-Path $WorkDir 'settings.json'
$SetupLog     = Join-Path $WorkDir 'Setup-VMBackup.log'

$TaskName = 'VMBackup-HyperV'

if (-not (Test-Path $WorkDir)) {
    New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
}

function Write-SetupLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')]
        [string]$Level = 'INFO',
        [switch]$NoConsole
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if (-not $NoConsole) {
        $color = switch ($Level) {
            'OK'    { 'Green' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
    Add-Content -Path $SetupLog -Value $line -Encoding UTF8
}

function Read-RetainDays {
    Write-Host ""
    Write-Host "Сколько дней хранить резервные копии?" -ForegroundColor Cyan
    Write-Host "  Введите число (7, 14, 30, 90)." -ForegroundColor DarkGray
    Write-Host "  Enter = 30 дней." -ForegroundColor DarkGray
    Write-Host "  0 = бессрочно (с подтверждением)." -ForegroundColor DarkGray

    while ($true) {
        $answer = Read-Host "Срок хранения, дней [30]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return 30 }
        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 0) {
            if ($parsed -eq 0) {
                $confirm = Read-Host "  Бессрочно. Точно? (y/N)"
                if ($confirm -match '^[YyДд]') { return 0 }
                else { continue }
            }
            return $parsed
        }
        Write-Host "  Некорректное значение. Целое число >= 0." -ForegroundColor Red
    }
}

function Read-Mode {
    Write-Host ""
    Write-Host "Что бэкапить?" -ForegroundColor Cyan
    Write-Host "  1 - Все ВМ (рекомендуется)" -ForegroundColor DarkGray
    Write-Host "  2 - Только перечисленные ВМ" -ForegroundColor DarkGray

    while ($true) {
        $answer = Read-Host "Выбор [1]"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -eq '1') {
            return @{ Mode = 'All'; VMs = @() }
        }
        if ($answer -eq '2') {
            $all = (Get-VM).Name
            if (-not $all) {
                Write-Host "  На хосте нет ВМ." -ForegroundColor Red
                continue
            }
            Write-Host "  Доступные ВМ:" -ForegroundColor DarkGray
            $all | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            $line = Read-Host "Имена через запятую"
            $list = $line -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            $bad = $list | Where-Object { $_ -notin $all }
            if ($bad) {
                Write-Host "  Не найдены: $($bad -join ', ')" -ForegroundColor Red
                continue
            }
            if ($list.Count -eq 0) {
                Write-Host "  Пустой список." -ForegroundColor Red
                continue
            }
            return @{ Mode = 'ByName'; VMs = $list }
        }
        Write-Host "  Введите 1 или 2." -ForegroundColor Red
    }
}

function Read-ScheduleTime {
    Write-Host ""
    Write-Host "Во сколько запускать бэкап ежедневно?" -ForegroundColor Cyan
    Write-Host "  Формат: HH:mm (например, 03:00)." -ForegroundColor DarkGray
    Write-Host "  Enter = 03:00." -ForegroundColor DarkGray

    while ($true) {
        $answer = Read-Host "Время [03:00]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return '03:00' }
        try {
            $ts = [datetime]::ParseExact($answer, 'HH:mm', $null)
            return $ts.ToString('HH:mm')
        } catch {
            Write-Host "  Неверный формат. Пример: 03:00" -ForegroundColor Red
        }
    }
}

function Read-SilentMode {
    Write-Host ""
    Write-Host "Запускать задачу без окна PowerShell?" -ForegroundColor Cyan
    Write-Host "  Да  - окно не будет показываться (рекомендуется)" -ForegroundColor DarkGray
    Write-Host "  Нет - окно будет появляться при каждом запуске" -ForegroundColor DarkGray

    while ($true) {
        $answer = Read-Host "Скрывать окно? (Y/n)"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^[YyДд]') { return $true }
        if ($answer -match '^[NnНн]') { return $false }
        Write-Host "  Введите Y или N." -ForegroundColor Red
    }
}

# Собрать аргументы для Backup-HyperV.ps1 по конфигу
function Get-BackupScriptArgs {
    param(
        [PSCustomObject]$Config
    )
    if ($Config.Mode -eq 'ByName' -and @($Config.VMs).Count -gt 0) {
        $vmList = (@($Config.VMs) | ForEach-Object { "`"$_`"" }) -join ','
        return "-Name $vmList"
    }
    return '-All'
}

# ==============================================================
# Показ текущего состояния
# ==============================================================
if ($Show) {
    Write-Host ""
    Write-Host "=== Текущие настройки ===" -ForegroundColor Cyan

    if (Test-Path $SettingsFile) {
        $s = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        Write-Host "Конфиг         : $SettingsFile"
        Write-Host "Папка бэкапов  : $($s.Destination)"
        Write-Host "Срок хранения  : $(if ([int]$s.RetainDays -gt 0) { "$($s.RetainDays) дней" } else { 'бессрочно' })"
        Write-Host "Режим          : $($s.Mode)"
        if ($s.Mode -eq 'ByName') {
            Write-Host "ВМ             : $(@($s.VMs) -join ', ')"
        }
        Write-Host "Время запуска  : $($s.ScheduleTime)"
        Write-Host "Без окна       : $(if ($null -ne $s.Silent -and [bool]$s.Silent) { 'да' } else { 'нет' })"
        Write-Host "Обновлён       : $($s.UpdatedAt)"
    }
    else {
        Write-Host "Конфиг не найден: $SettingsFile" -ForegroundColor Yellow
    }

    Write-Host ""
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host "Задача в Планировщике : зарегистрирована" -ForegroundColor Green
        Write-Host "  Состояние           : $($task.State)"
        Write-Host "  Действие            : $($task.Actions.Execute) $($task.Actions.Arguments)"
        Write-Host "  Последний запуск    : $($info.LastRunTime)"
        Write-Host "  Результат           : $($info.LastTaskResult)"
    }
    else {
        Write-Host "Задача в Планировщике : не зарегистрирована" -ForegroundColor Yellow
    }
    Write-Host ""
    return
}

# ==============================================================
# Удаление задачи
# ==============================================================
if ($UnregisterTask) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-SetupLog "Задача '$TaskName' не найдена." 'WARN'
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-SetupLog "Задача '$TaskName' удалена." 'OK'
    return
}

# ==============================================================
# Регистрация задачи по текущему конфигу
# ==============================================================
if ($RegisterTask) {
    if (-not (Test-Path $SettingsFile)) {
        Write-SetupLog "Конфиг не найден. Сначала выполните настройку: .\Setup-VMBackup.ps1" 'ERROR'
        return
    }
    if (-not (Test-Path $BackupScript)) {
        Write-SetupLog "Не найден Backup-HyperV.ps1 рядом с Setup: $BackupScript" 'ERROR'
        return
    }

    $s = Get-Content $SettingsFile -Raw | ConvertFrom-Json
    $time = [datetime]::ParseExact($s.ScheduleTime, 'HH:mm', $null)
    $silent = if ($null -ne $s.Silent) { [bool]$s.Silent } else { $false }

    $scriptArgs = Get-BackupScriptArgs -Config $s

    # Общие аргументы powershell.exe
    $psBase = "-NoProfile -ExecutionPolicy Bypass"
    if ($silent) {
        $psBase += " -WindowStyle Hidden"
    }
    $fullArgs = "$psBase -File `"$BackupScript`" $scriptArgs"

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $fullArgs
    $trigger = New-ScheduledTaskTrigger -Daily -At $time
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settingsTask = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12)

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settingsTask `
        -Description 'Резервное копирование ВМ Hyper-V (экспорт)' | Out-Null

    Write-SetupLog "Задача '$TaskName' зарегистрирована на $($s.ScheduleTime) ежедневно." 'OK'
    Write-SetupLog "  Без окна : $silent" 'INFO'
    Write-SetupLog "  Команда  : powershell.exe $fullArgs" 'INFO'
    return
}

# ==============================================================
# Интерактивная настройка
# ==============================================================

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Настройка VMBackup" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$old = $null
if (Test-Path $SettingsFile) {
    try { $old = Get-Content $SettingsFile -Raw | ConvertFrom-Json } catch { $old = $null }
}

# 1. Папка
$defaultDest = if ($old -and $old.Destination) { $old.Destination } else { 'E:\HyperV-Backups' }
Write-Host ""
Write-Host "Папка для резервных копий." -ForegroundColor Cyan
Write-Host "  Должна быть на другом физическом диске или сетевой шаре." -ForegroundColor DarkGray
$destInput = Read-Host "Папка [$defaultDest]"
$Destination = if ([string]::IsNullOrWhiteSpace($destInput)) { $defaultDest } else { $destInput }

$qualifier = Split-Path -Qualifier $Destination -ErrorAction SilentlyContinue
if ($qualifier -and -not (Test-Path $qualifier)) {
    Write-SetupLog "Диск '$qualifier' недоступен." 'ERROR'
    return
}

# 2. Срок хранения
if ($old -and $null -ne $old.RetainDays) {
    Write-Host ""
    Write-Host "Текущий срок хранения: $(if ([int]$old.RetainDays -gt 0) { "$($old.RetainDays) дней" } else { 'бессрочно' })" -ForegroundColor DarkGray
}
$retain = Read-RetainDays

# 3. Режим
if ($old -and $old.Mode) {
    Write-Host ""
    Write-Host "Текущий режим: $($old.Mode)" -ForegroundColor DarkGray
}
$modeInfo = Read-Mode

# 4. Время запуска
if ($old -and $old.ScheduleTime) {
    Write-Host ""
    Write-Host "Текущее время запуска: $($old.ScheduleTime)" -ForegroundColor DarkGray
}
$scheduleTime = Read-ScheduleTime

# 5. Silent
if ($old -and $null -ne $old.Silent) {
    Write-Host ""
    Write-Host "Текущий режим окна: $(if ([bool]$old.Silent) { 'без окна' } else { 'с окном' })" -ForegroundColor DarkGray
}
$silent = Read-SilentMode

# 6. Сохранение
$settings = [PSCustomObject]@{
    Destination  = $Destination
    RetainDays   = $retain
    Mode         = $modeInfo.Mode
    VMs          = @($modeInfo.VMs)
    ScheduleTime = $scheduleTime
    Silent       = $silent
    CreatedAt    = if ($old -and $old.CreatedAt) { $old.CreatedAt } else { (Get-Date -Format 'o') }
    UpdatedAt    = (Get-Date -Format 'o')
}
$settings | ConvertTo-Json -Depth 4 | Set-Content -Path $SettingsFile -Encoding UTF8

Write-SetupLog "Конфиг сохранён: $SettingsFile" 'OK'
Write-Host ""
Write-Host "Итог:" -ForegroundColor Cyan
Write-Host "  Папка      : $Destination"
Write-Host "  Хранение   : $(if ($retain -gt 0) { "$retain дней" } else { 'бессрочно' })"
Write-Host "  Режим      : $($modeInfo.Mode)"
if ($modeInfo.Mode -eq 'ByName') {
    Write-Host "  ВМ         : $(@($modeInfo.VMs) -join ', ')"
}
Write-Host "  Время      : $scheduleTime ежедневно"
Write-Host "  Без окна   : $(if ($silent) { 'да' } else { 'нет' })"

# 7. Предложить зарегистрировать задачу
Write-Host ""
$reg = Read-Host "Зарегистрировать задачу в Планировщике сейчас? (y/N)"
if ($reg -match '^[YyДд]') {
    & $SetupPath -RegisterTask
}
else {
    Write-Host ""
    Write-Host "Позже можно зарегистрировать так:" -ForegroundColor DarkGray
    Write-Host "  .\Setup-VMBackup.ps1 -RegisterTask" -ForegroundColor White
}

Write-Host ""
Write-Host "Проверить состояние:" -ForegroundColor DarkGray
Write-Host "  .\Setup-VMBackup.ps1 -Show" -ForegroundColor White
Write-Host "Запустить бэкап вручную:" -ForegroundColor DarkGray
Write-Host "  .\Backup-HyperV.ps1 -Execute" -ForegroundColor White