<#
.SYNOPSIS
    Резервное копирование виртуальных машин Hyper-V через экспорт.

.DESCRIPTION
    Читает настройки из VMBackup\settings.json (создаётся Setup-VMBackup.ps1).
    Если конфига нет — создаёт базовый и продолжает (не падает).
    Без параметров — тестовый режим (dry-run): показывает план, ничего
    не копирует. Реальный запуск: -Execute (по конфигу), -All или -Name.

    При запуске с -Silent не пишет в консоль (лог всё равно ведётся).
    Предназначен для запуска вручную или из Планировщика.

.PARAMETER Execute
    Выполнить реальный бэкап по режиму из конфига.

.PARAMETER All
    Разово: все ВМ, игнорируя режим из конфига. Реальный бэкап.

.PARAMETER Name
    Разово: указанные ВМ. Реальный бэкап.

.PARAMETER WhatIf
    Принудительный dry-run (даже вместе с -Execute).

.PARAMETER RetainDays
    Переопределить срок хранения на один запуск (не сохраняется).

.PARAMETER Silent
    Не выводить ничего в консоль, только писать в лог.

.EXAMPLE
    .\Backup-HyperV.ps1
    Тест: показать, что было бы сделано.

.EXAMPLE
    .\Backup-HyperV.ps1 -Execute
    Реальный бэкап по настройкам из конфига.

.EXAMPLE
    .\Backup-HyperV.ps1 -All
    Разово все ВМ, реальный бэкап.

.EXAMPLE
    .\Backup-HyperV.ps1 -Name "VM1","VM2"
    Разово две ВМ, реальный бэкап.

.EXAMPLE
    .\Backup-HyperV.ps1 -Execute -WhatIf
    Принудительный тест.

.EXAMPLE
    .\Backup-HyperV.ps1 -All -Silent
    Реальный бэкап без вывода в консоль (для Планировщика).
#>

[CmdletBinding(DefaultParameterSetName = 'Config')]
param(
    [Parameter(ParameterSetName = 'Config')]
    [switch]$Execute,

    [Parameter(ParameterSetName = 'All', Mandatory = $true)]
    [switch]$All,

    [Parameter(ParameterSetName = 'ByName', Mandatory = $true)]
    [string[]]$Name,

    [switch]$WhatIf,

    [int]$RetainDays = -1,

    [switch]$Silent
)

# ==============================================================
# 1. Подготовка
# ==============================================================

$ScriptPath   = $PSCommandPath
$ScriptDir    = Split-Path -Parent $ScriptPath
$WorkDir      = Join-Path $ScriptDir 'VMBackup'
$SettingsFile = Join-Path $WorkDir 'settings.json'
$LogFile      = Join-Path $WorkDir 'Backup-HyperV.log'

if (-not (Test-Path $WorkDir)) {
    New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')]
        [string]$Level = 'INFO',
        [switch]$NoConsole
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if (-not $NoConsole -and -not $Silent) {
        $color = switch ($Level) {
            'OK'    { 'Green' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ==============================================================
# 2. Конфиг: загрузить или создать базовый
# ==============================================================

$settings = $null
$configWasCreated = $false

if (Test-Path $SettingsFile) {
    try {
        $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "Конфиг повреждён, пересоздаём: $_" 'WARN'
        $settings = $null
    }
}

if (-not $settings) {
    $defaultDest = Join-Path $ScriptDir 'Backups'
    $settings = [PSCustomObject]@{
        Destination  = $defaultDest
        RetainDays   = 30
        Mode         = 'All'
        VMs          = @()
        ScheduleTime = '03:00'
        Silent       = $false
        CreatedAt    = (Get-Date -Format 'o')
        UpdatedAt    = (Get-Date -Format 'o')
    }
    $settings | ConvertTo-Json -Depth 4 | Set-Content -Path $SettingsFile -Encoding UTF8
    $configWasCreated = $true
    Write-Log "Конфиг не найден. Создан базовый: $SettingsFile" 'WARN'
    Write-Log "  Папка бэкапов : $defaultDest" 'WARN'
    Write-Log "  Хранение      : 30 дней" 'WARN'
    Write-Log "  Режим         : все ВМ" 'WARN'
    Write-Log "Для тонкой настройки запустите Setup-VMBackup.ps1" 'WARN'
}

$Destination      = $settings.Destination
$retainFromConfig = [int]$settings.RetainDays
$RetainDays       = if ($RetainDays -ge 0) { $RetainDays } else { $retainFromConfig }
$modeFromConfig   = $settings.Mode
$vmsFromConfig    = @($settings.VMs)

# ==============================================================
# 3. Определяем режим запуска
# ==============================================================

$isExplicitReal = ($PSCmdlet.ParameterSetName -in @('All','ByName')) -or $Execute
$isTestMode = $WhatIf -or (-not $isExplicitReal)

Write-Log "===== Запуск Backup-HyperV ====="
Write-Log "Режим          : $(if ($isTestMode) {'ТЕСТ (dry-run)'} else {'РЕАЛЬНЫЙ'})"
Write-Log "Папка бэкапов  : $Destination"
Write-Log "Хранение, дней : $(if ($RetainDays -gt 0) { $RetainDays } else { 'бессрочно' })"
Write-Log "Набор ВМ       : $($PSCmdlet.ParameterSetName)"
Write-Log "Silent         : $Silent"

if (-not $Silent -and $isTestMode -and -not $WhatIf -and -not $isExplicitReal) {
    Write-Host ""
    Write-Host "Запуск без параметров = тестовый режим (dry-run)." -ForegroundColor Magenta
    Write-Host "Для реального бэкапа добавьте -Execute, -All или -Name." -ForegroundColor Magenta
}

# ==============================================================
# 4. Сбор списка ВМ
# ==============================================================

Import-Module Hyper-V -ErrorAction Stop

if ($PSCmdlet.ParameterSetName -eq 'All') {
    $vms = Get-VM
}
elseif ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $vms = foreach ($vmName in $Name) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($vm) { $vm }
        else { Write-Log "ВМ '$vmName' не найдена. Пропускаю." 'WARN' }
    }
}
else {
    if ($modeFromConfig -eq 'ByName' -and $vmsFromConfig.Count -gt 0) {
        $vms = foreach ($vmName in $vmsFromConfig) {
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if ($vm) { $vm }
            else { Write-Log "ВМ '$vmName' из конфига не найдена. Пропускаю." 'WARN' }
        }
    }
    else {
        $vms = Get-VM
    }
}

if (-not $vms) {
    Write-Log "Нет ни одной ВМ для обработки." 'ERROR'
    exit 1
}

# ==============================================================
# 5. План и проверка места
# ==============================================================

$plan = foreach ($vm in $vms) {
    $diskGB = 0
    try {
        $diskGB = [math]::Round(
            (Get-VMHardDiskDrive -VM $vm |
                ForEach-Object { (Get-VHD -Path $_.Path -ErrorAction SilentlyContinue).FileSize } |
                Measure-Object -Sum).Sum / 1GB, 2
        )
    } catch { $diskGB = 0 }

    [PSCustomObject]@{
        VM       = $vm.Name
        State    = $vm.State
        CPU      = $vm.ProcessorCount
        MemoryGB = [math]::Round($vm.MemoryAssigned / 1GB, 2)
        DiskGB   = $diskGB
        Action   = if ($isTestMode) { 'ТЕСТ' } else { 'Экспорт' }
    }
}

if (-not $Silent) {
    Write-Host ""
    Write-Host "Планируемые действия:" -ForegroundColor Yellow
    $plan | Format-Table -AutoSize
}

$totalGB = [math]::Round(($plan | Measure-Object DiskGB -Sum).Sum, 2)
Write-Log "Суммарный объём дисков: ~$totalGB ГБ"

if ($RetainDays -gt 0) {
    $forecastGB = [math]::Round($totalGB * $RetainDays, 2)
    Write-Log "Прогноз: ~$totalGB ГБ за прогон x $RetainDays дн. = ~$forecastGB ГБ макс."
}
else {
    Write-Log "Срок хранения: бессрочно. Бэкапы не удаляются автоматически." 'WARN'
}

# --- Проверка диска ---
$destRoot = $null
if (Test-Path $Destination) {
    $destRoot = (Get-Item $Destination).PSDrive.Name
}
else {
    $qualifier = Split-Path -Qualifier $Destination -ErrorAction SilentlyContinue
    if ($qualifier) { $destRoot = $qualifier.TrimEnd(':') }
}

if ($destRoot) {
    try {
        $drive = Get-PSDrive -Name $destRoot -ErrorAction SilentlyContinue
        if ($drive) {
            $freeGB = [math]::Round($drive.Free / 1GB, 2)
            Write-Log "Свободно на ${destRoot}: $freeGB ГБ"

            $requiredGB = if ($RetainDays -gt 0) { $totalGB * $RetainDays * 1.1 } else { $totalGB * 1.1 }
            $requiredGB = [math]::Round($requiredGB, 2)

            if ($freeGB -lt $requiredGB) {
                Write-Log "ВНИМАНИЕ: места может не хватить (нужно ~$requiredGB ГБ)!" 'WARN'
            }
            else {
                Write-Log "Места достаточно (нужно ~$requiredGB ГБ)." 'OK'
            }
        }
    }
    catch {
        Write-Log "Не удалось определить свободное место: $_" 'WARN'
    }
}
else {
    if ($isTestMode) {
        Write-Log "Диск/шара '$Destination' недоступна (в тесте это не блокирует)." 'WARN'
    }
    else {
        Write-Log "Диск/шара '$Destination' недоступна. Пробуем создать папку..." 'WARN'
    }
}

# ==============================================================
# 6. Тест — выход
# ==============================================================

if ($isTestMode) {
    if (-not $Silent) {
        Write-Host ""
        Write-Host "Тест завершён. Ничего не скопировано." -ForegroundColor Magenta
        Write-Host "Для реального запуска:" -ForegroundColor Magenta
        Write-Host "  .\Backup-HyperV.ps1 -Execute         # по настройкам из конфига" -ForegroundColor White
        Write-Host "  .\Backup-HyperV.ps1 -All             # разово все ВМ" -ForegroundColor White
        Write-Host "  .\Backup-HyperV.ps1 -Name `"VM1`"    # разово одну ВМ" -ForegroundColor White
        Write-Host ""
        if ($configWasCreated) {
            Write-Host "Создан базовый конфиг. Проверьте и при необходимости настройте:" -ForegroundColor Yellow
            Write-Host "  .\Setup-VMBackup.ps1" -ForegroundColor White
        }
    }
    Write-Log "===== Конец (тест) ====="
    return
}

# ==============================================================
# 7. Экспорт
# ==============================================================

if (-not (Test-Path $Destination)) {
    try {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
        Write-Log "Создана папка: $Destination" 'OK'
    }
    catch {
        Write-Log "Не удалось создать папку $Destination : $_" 'ERROR'
        exit 1
    }
}

$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$runFolder = Join-Path $Destination $timestamp
New-Item -Path $runFolder -ItemType Directory -Force | Out-Null
Write-Log "Папка запуска: $runFolder"

$results = @()

foreach ($vm in $vms) {
    Write-Log "Экспорт ВМ: $($vm.Name) (состояние: $($vm.State))"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Export-VM -VM $vm -Path $runFolder -ErrorAction Stop
        $sw.Stop()
        $results += [PSCustomObject]@{
            VM = $vm.Name; Status = 'OK'
            Duration = $sw.Elapsed.ToString('hh\:mm\:ss'); Error = ''
        }
        Write-Log "  OK за $($sw.Elapsed.ToString('hh\:mm\:ss'))" 'OK'
    }
    catch {
        $sw.Stop()
        $results += [PSCustomObject]@{
            VM = $vm.Name; Status = 'ОШИБКА'
            Duration = $sw.Elapsed.ToString('hh\:mm\:ss'); Error = $_.Exception.Message
        }
        Write-Log "  Ошибка: $($_.Exception.Message)" 'ERROR'
    }
}

# ==============================================================
# 8. Итог и очистка
# ==============================================================

if (-not $Silent) {
    Write-Host ""
    Write-Host "=== Итог ===" -ForegroundColor Green
    $results | Format-Table -AutoSize
}

$ok  = ($results | Where-Object Status -eq 'OK').Count
$err = ($results | Where-Object Status -ne 'OK').Count
Write-Log "Успешно: $ok, Ошибок: $err"

if ($RetainDays -gt 0) {
    Write-Log "Очистка бэкапов старше $RetainDays дней"
    $cutoff = (Get-Date).AddDays(-$RetainDays)
    $old = Get-ChildItem -Path $Destination -Directory |
           Where-Object { $_.CreationTime -lt $cutoff }
    if ($old) {
        foreach ($f in $old) {
            try {
                Remove-Item -Path $f.FullName -Recurse -Force -ErrorAction Stop
                Write-Log "  Удалено: $($f.Name)" 'OK'
            }
            catch {
                Write-Log "  Не удалось удалить $($f.FullName): $_" 'WARN'
            }
        }
    }
    else {
        Write-Log "  Старых бэка