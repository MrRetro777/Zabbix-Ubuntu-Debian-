# Установка и настройка Zabbix Agent 2 на Windows
# PowerShell скрипт

# Требует запуска от администратора

# Параметры
$ZabbixServer = "192.168.1.100"  # Адрес Zabbix сервера
$HostName = $env:COMPUTERNAME     # Имя компьютера
$InstallDir = "C:\Program Files\Zabbix Agent 2"
$Version = "6.4"
$LogFile = "C:\Windows\Temp\zabbix-agent-install.log"

# Функция логирования
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogFile -Value $logMessage
}

# Проверка прав администратора
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Запустите скрипт от имени администратора!" -ForegroundColor Red
    exit 1
}

Write-Log "Начало установки Zabbix Agent 2 на Windows"

# Создание временного каталога
$TempDir = "C:\Temp\ZabbixInstall"
if (!(Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

# Скачивание Zabbix Agent
Write-Log "Скачивание Zabbix Agent..."
$DownloadUrl = "https://cdn.zabbix.com/zabbix/binaries/stable/$Version/$Version.0/zabbix_agent2-$Version.0-windows-amd64-openssl.msi"
$InstallerPath = "$TempDir\zabbix_agent2.msi"

try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath -UseBasicParsing
    Write-Log "Zabbix Agent скачан успешно"
}
catch {
    Write-Log "Ошибка скачивания: $_" "ERROR"
    exit 1
}

# Запрос параметров у пользователя
Write-Host "`n=== Настройка Zabbix Agent ===" -ForegroundColor Green
$ZabbixServer = Read-Host "Введите адрес Zabbix сервера [$ZabbixServer]"
$ZabbixServer = if ($ZabbixServer) { $ZabbixServer } else { "192.168.1.100" }

$HostName = Read-Host "Введите имя хоста для мониторинга [$HostName]"
$HostName = if ($HostName) { $HostName } else { $env:COMPUTERNAME }

$HostMetadata = Read-Host "Введите метаданные хоста (например: windows,server,prod)"
$HostMetadata = if ($HostMetadata) { $HostMetadata } else { "windows" }

# Установка Zabbix Agent
Write-Log "Установка Zabbix Agent..."
$InstallArgs = @(
    "/i", "`"$InstallerPath`"",
    "/qn",
    "/norestart",
    "LOGTYPE=file",
    "LOGFILE=`"C:\Program Files\Zabbix Agent 2\zabbix_agent2.log`"",
    "SERVER=$ZabbixServer",
    "SERVERACTIVE=$ZabbixServer",
    "HOSTNAME=$HostName",
    "HOSTMETADATA=$HostMetadata",
    "INSTALLFOLDER=`"$InstallDir`"",
    "ENABLEPATH=1"
)

Start-Process msiexec.exe -ArgumentList $InstallArgs -Wait -NoNewWindow
Write-Log "Zabbix Agent установлен"

# Генерация PSK ключа
Write-Log "Генерация PSK ключа..."
$PSKKey = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 64 | ForEach-Object {[char]$_})
$PSKFile = "$InstallDir\zabbix_agent2.psk"
$PSKKey | Out-File -FilePath $PSKFile -Encoding ASCII

# Настройка конфигурации
Write-Log "Настройка конфигурации..."
$ConfigPath = "$InstallDir\zabbix_agent2.conf"

# Создание резервной копии конфигурации
Copy-Item $ConfigPath "$ConfigPath.backup" -Force

# Обновление конфигурации
$ConfigContent = @"
# Основные настройки
LogType=file
LogFile=$InstallDir\zabbix_agent2.log
LogFileSize=50
DebugLevel=3

# Настройки сервера
Server=$ZabbixServer
ServerActive=$ZabbixServer
Hostname=$HostName
HostMetadata=$HostMetadata

# Безопасность
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=PSK_$HostName
TLSPSKFile=$PSKFile

# Настройки производительности
Timeout=30
BufferSize=100
StartAgents=10

# Пользовательские параметры
Include=$InstallDir\zabbix_agent2.d\*.conf

# Плагины
Plugins.Windows.PerfMon.Enabled=true
Plugins.Windows.Wmi.Enabled=true
Plugins.Windows.Services.Enabled=true
Plugins.Windows.Proc.Enabled=true
"@

$ConfigContent | Out-File -FilePath $ConfigPath -Encoding UTF8

# Создание каталога для пользовательских параметров
$UserParamsDir = "$InstallDir\zabbix_agent2.d"
if (!(Test-Path $UserParamsDir)) {
    New-Item -ItemType Directory -Path $UserParamsDir -Force | Out-Null
}

# Создание пользовательских параметров для Windows
Write-Log "Создание пользовательских параметров..."
$UserParams = @"
# Мониторинг служб Windows
UserParameter=service.state[*],powershell -Command "`$service = Get-Service -Name `$args[0] -ErrorAction SilentlyContinue; if (`$service) { if (`$service.Status -eq 'Running') { 1 } else { 0 } } else { 2 }" `$1

# Мониторинг занятости диска
UserParameter=vfs.fs.size[*],powershell -Command "`$drive = Get-PSDrive -Name `$args[0] -ErrorAction SilentlyContinue; if (`$drive) { `$drive.Free / 1GB } else { 0 }" `$1

# Мониторинг процессов
UserParameter=proc.num[*],powershell -Command "(Get-Process `$args[0] -ErrorAction SilentlyContinue).Count"

# Мониторинг событий Windows
UserParameter=eventlog.count[*],powershell -Command "Get-EventLog -LogName `$args[0] -EntryType `$args[1] -After (Get-Date).AddHours(-1) | Measure-Object | Select-Object -ExpandProperty Count"

# Мониторинг свободной памяти
UserParameter=memory.free, powershell -Command "[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024, 2)"

# Мониторинг CPU
UserParameter=cpu.load, powershell -Command "(Get-CimInstance Win32_Processor).LoadPercentage"

# Мониторинг времени работы
UserParameter=system.uptime, powershell -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime"

# Мониторинг IIS (если установлен)
UserParameter=iis.requests.total, powershell -Command "try { (Get-WebRequest | Measure-Object).Count } catch { 0 }"

# Мониторинг SQL Server (если установлен)
UserParameter=sql.connections, powershell -Command "try { (Get-SqlConnection -ConnectionString 'Server=localhost;Database=master;Trusted_Connection=True;').Count } catch { 0 }"
"@

$UserParams | Out-File -FilePath "$UserParamsDir\userparams.conf" -Encoding UTF8

# Создание скриптов для мониторинга
Write-Log "Создание скриптов мониторинга..."
$ScriptsDir = "$InstallDir\scripts"
if (!(Test-Path $ScriptsDir)) {
    New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
}

# Скрипт для мониторинга служб
$ServiceScript = @'
param([string]$ServiceName)
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -eq 'Running') { 
        Write-Output "1" 
    } else { 
        Write-Output "0" 
    }
} else {
    Write-Output "2"  # Служба не найдена
}
'@
$ServiceScript | Out-File -FilePath "$ScriptsDir\check_service.ps1" -Encoding UTF8

# Скрипт для мониторинга дисков
$DiskScript = @'
$disks = Get-PSDrive -PSProvider FileSystem | Where-Object {$_.Used -gt 0}
foreach ($disk in $disks) {
    $freePercent = ($disk.Free / $disk.Used) * 100
    Write-Output "$($disk.Name):$([math]::Round($freePercent, 2))"
}
'@
$DiskScript | Out-File -FilePath "$ScriptsDir\check_disks.ps1" -Encoding UTF8

# Скрипт для мониторинга событий
$EventScript = @'
param([string]$LogName, [string]$EventType, [int]$LastHours = 1)
$time = (Get-Date).AddHours(-$LastHours)
try {
    $count = (Get-EventLog -LogName $LogName -EntryType $EventType -After $time | Measure-Object).Count
    Write-Output $count
} catch {
    Write-Output "0"
}
'@
$EventScript | Out-File -FilePath "$ScriptsDir\check_events.ps1" -Encoding UTF8

# Настройка политики выполнения PowerShell
Write-Log "Настройка политики выполнения PowerShell..."
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

# Настройка брандмауэра Windows
Write-Log "Настройка брандмауэра..."
New-NetFirewallRule -DisplayName "Zabbix Agent" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 10050 `
    -RemoteAddress $ZabbixServer `
    -Action Allow `
    -Enabled True | Out-Null

# Создание задачи в планировщике для автоматического перезапуска агента
Write-Log "Создание задачи в планировщике..."
$ScheduledTaskAction = New-ScheduledTaskAction -Execute "$InstallDir\zabbix_agent2.exe" `
    -Argument "-c `"$ConfigPath`""

$ScheduledTaskTrigger = New-ScheduledTaskTrigger -AtStartup
$ScheduledTaskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$ScheduledTaskSettings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName "Zabbix Agent 2" `
    -Action $ScheduledTaskAction `
    -Trigger $ScheduledTaskTrigger `
    -Principal $ScheduledTaskPrincipal `
    -Settings $ScheduledTaskSettings | Out-Null

# Перезапуск службы Zabbix Agent
Write-Log "Перезапуск службы Zabbix Agent..."
Restart-Service "Zabbix Agent 2" -Force

# Проверка статуса службы
Start-Sleep -Seconds 5
$ServiceStatus = Get-Service "Zabbix Agent 2" -ErrorAction SilentlyContinue

if ($ServiceStatus -and $ServiceStatus.Status -eq 'Running') {
    Write-Log "Zabbix Agent 2 успешно запущен" "SUCCESS"
} else {
    Write-Log "Ошибка запуска Zabbix Agent 2" "ERROR"
}

# Создание информационного файла
$InfoFile = "C:\Zabbix_Agent_Info.txt"
$InfoContent = @"
===============================================
     ZABBIX AGENT 2 УСТАНОВЛЕН НА WINDOWS
===============================================

Хост: $HostName
Zabbix Server: $ZabbixServer
Метаданные: $HostMetadata

PSK Identity: PSK_$HostName
PSK Key: $PSKKey

Каталоги:
Установка: $InstallDir
Конфигурация: $ConfigPath
Скрипты: $ScriptsDir
Логи: $InstallDir\zabbix_agent2.log

Команды управления:
Get-Service "Zabbix Agent 2"
Restart-Service "Zabbix Agent 2"
Get-Content "$InstallDir\zabbix_agent2.log" -Tail 50

Пользовательские параметры:
Службы: service.state[имя_службы]
Диски: vfs.fs.size[буква_диска]
Процессы: proc.num[имя_процесса]
События: eventlog.count[лог,тип]
Память: memory.free
CPU: cpu.load
Аптайм: system.uptime

===============================================
Для добавления на сервер используйте PSK ключ:
$PSKKey
===============================================
"@

$InfoContent | Out-File -FilePath $InfoFile -Encoding UTF8

# Вывод итоговой информации
Write-Host "`n" -NoNewline
Write-Host "="*50 -ForegroundColor Green
Write-Host "     УСТАНОВКА ZABBIX AGENT 2 ЗАВЕРШЕНА     " -ForegroundColor Green
Write-Host "="*50 -ForegroundColor Green
Write-Host ""
Write-Host "Информация:" -ForegroundColor Yellow
Write-Host "Имя хоста: $HostName" -ForegroundColor Green
Write-Host "Zabbix Server: $ZabbixServer" -ForegroundColor Green
Write-Host "PSK Identity: PSK_$HostName" -ForegroundColor Green
Write-Host "PSK Key: $PSKKey" -ForegroundColor Green
Write-Host ""
Write-Host "Статус службы:" -ForegroundColor Yellow
Get-Service "Zabbix Agent 2" | Select-Object Name, Status, StartType | Format-Table -AutoSize
Write-Host ""
Write-Host "Информация сохранена в: $InfoFile" -ForegroundColor Yellow
Write-Host "Лог установки: $LogFile" -ForegroundColor Yellow
Write-Host ""
Write-Host "Следующие шаги:" -ForegroundColor Yellow
Write-Host "1. Добавьте хост на Zabbix сервере" -ForegroundColor White
Write-Host "2. Используйте PSK ключ для аутентификации" -ForegroundColor White
Write-Host "3. Назначьте шаблоны мониторинга" -ForegroundColor White
Write-Host "4. Проверьте получение данных" -ForegroundColor White

Write-Log "Установка завершена"
