# YouTube Downloader с обходом блокировок через zapret + DoH-прокси.
# Просит ссылку и качество, сам поднимает/останавливает локальный прокси.
# Размещено: scripts/downloader.ps1

$ErrorActionPreference = 'Stop'

# ------------------------- настройки -------------------------
$ProjectRoot   = Split-Path -Parent $PSScriptRoot
$YtDlp         = Join-Path $ProjectRoot 'tools\yt-dlp.exe'
$ProxyScript   = Join-Path $ProjectRoot 'proxy\doh_proxy.py'
# Папка Загрузки/Downloads текущего пользователя (работает на любом языке Windows)
$shell         = New-Object -ComObject Shell.Application
$DownloadDir   = $shell.Namespace('shell:Downloads').Self.Path
$FfmpegDir     = Join-Path $ProjectRoot 'tools\ffmpeg'
$ZapretBat     = Join-Path $ProjectRoot 'zapret\general (ALT11).bat'
# ------------------------------------------------------------

function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}

function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

function Wait-Port {
    param([int]$Port, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            if ($client.ConnectAsync('127.0.0.1', $Port).Wait(300)) { return $true }
        } catch { }
        finally { $client.Dispose() }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Get-VideoUrl {
    while ($true) {
        $raw = Read-Host 'Вставьте ссылку на видео (youtube.com или youtu.be)'
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host 'Ссылка пустая, попробуйте ещё раз.' -ForegroundColor Yellow
            continue
        }
        $url = $raw.Trim()
        if ($url -notmatch '^https?://') { $url = 'https://' + $url }
        if ($url -match '^https?://(www\.|m\.|music\.)?(youtube\.com/(watch\?|shorts/|live/|embed/)|youtu\.be/)[\w\-]+') {
            return $url
        }
        Write-Host 'Это не похоже на ссылку YouTube. Примеры:' -ForegroundColor Yellow
        Write-Host '  https://www.youtube.com/watch?v=uvCxZ-Kv1q4'
        Write-Host '  https://youtu.be/uvCxZ-Kv1q4'
    }
}

function Get-FormatChoice {
    while ($true) {
        Write-Header 'Выберите формат'
        Write-Host '  1) 144p'
        Write-Host '  2) 360p'
        Write-Host '  3) 720p'
        Write-Host '  4) 1080p'
        Write-Host '  5) только аудио (mp3)'
        $choice = Read-Host 'Ваш выбор [1-5]'
        switch ($choice.Trim().ToLower()) {
            { $_ -in '1', '144', '144p' }                { return @{ Kind = 'video'; Height = 144 } }
            { $_ -in '2', '360', '360p' }                { return @{ Kind = 'video'; Height = 360 } }
            { $_ -in '3', '720', '720p' }                { return @{ Kind = 'video'; Height = 720 } }
            { $_ -in '4', '1080', '1080p' }              { return @{ Kind = 'video'; Height = 1080 } }
            { $_ -in '5', 'audio', 'аудио', 'mp3' }      { return @{ Kind = 'audio'; Height = 0 } }
            default { Write-Host 'Введите 1, 2, 3, 4 или 5.' -ForegroundColor Yellow }
        }
    }
}

function Test-ZapretRunning {
    $proc = Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue
    return $null -ne $proc
}

function Start-Zapret {
    if (-not (Test-Path $ZapretBat)) {
        throw "Не найден файл запуска zapret: $ZapretBat`nПоложите папку zapret рядом со скриптом или укажите верный путь."
    }
    Write-Host "Запускаю zapret из $ZapretBat ..." -ForegroundColor Cyan
    Start-Process -FilePath $ZapretBat -WindowStyle Hidden -ErrorAction Stop | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-ZapretRunning) {
            Write-Host 'zapret запущен (winws.exe активен).' -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 1
    }
    throw 'Не удалось дождаться запуска winws.exe (zapret).'
}

# --------------------------- старт ---------------------------
Write-Header 'YouTube Downloader (zapret + DoH)'

$script:zapretStartedByUs = $false
$script:zapretProc        = $null

foreach ($p in @($YtDlp, $ProxyScript, $ZapretBat)) {
    if (-not (Test-Path $p)) { throw "Не найден файл: $p`nПоложите yt-dlp.exe в tools/, а папку zapret рядом со скриптом." }
}
if (-not (Test-Path (Join-Path $FfmpegDir 'ffmpeg.exe'))) {
    throw "Не найден ffmpeg: $FfmpegDir\ffmpeg.exe`nПоложите ffmpeg.exe, ffplay.exe, ffprobe.exe в tools\ffmpeg\"
}
if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir | Out-Null }

$url    = Get-VideoUrl
$format = Get-FormatChoice

# --- проверка/запуск zapret ---
if (-not (Test-ZapretRunning)) {
    Write-Host "Запускаю zapret из $ZapretBat ..." -ForegroundColor Cyan
    Start-Process -FilePath $ZapretBat -WindowStyle Hidden -ErrorAction Stop | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue
        if ($proc) {
            $script:zapretProc = $proc
            $script:zapretStartedByUs = $true
            Write-Host 'zapret запущен (winws.exe активен).' -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $script:zapretStartedByUs) {
        throw 'Не удалось дождаться запуска winws.exe (zapret).'
    }
} else {
    Write-Host 'zapret уже запущен (winws.exe активен).' -ForegroundColor DarkGray
}

# --- запуск локального DoH-прокси ---
$port = Get-FreePort
$proxyLog = Join-Path $env:TEMP "ytdlp_doh_proxy_$port.log"
$py = (Get-Command py -ErrorAction SilentlyContinue)
if ($py) {
    $proxyProc = Start-Process -FilePath $py.Source `
        -ArgumentList @('-3', $ProxyScript, "$port") `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardError $proxyLog -RedirectStandardOutput ($proxyLog + '.out')
} else {
    $proxyProc = Start-Process -FilePath 'python' `
        -ArgumentList @($ProxyScript, "$port") `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardError $proxyLog -RedirectStandardOutput ($proxyLog + '.out')
}

try {
    if (-not (Wait-Port -Port $port -TimeoutSec 20)) {
        Write-Host 'Не удалось запустить DoH-прокси. Лог:' -ForegroundColor Red
        if (Test-Path $proxyLog) { Get-Content $proxyLog -Tail 20 }
        throw 'Прокси не запустился.'
    }
    Write-Host "Прокси запущен на 127.0.0.1:$port" -ForegroundColor DarkGray

    $argsList = @(
        '--proxy', "http://127.0.0.1:$port",
        '--socket-timeout', '30',
        '--retries', '5',
        '--fragment-retries', '10',
        '--concurrent-fragments', '4',
        '--no-playlist',
        '--no-mtime',
        '--newline',
        '--windows-filenames',
        '-o', (Join-Path $DownloadDir '%(title)s [%(id)s].%(ext)s')
    )
    if ($FfmpegDir -and (Test-Path $FfmpegDir)) {
        $argsList += @('--ffmpeg-location', $FfmpegDir)
    }

    if ($format.Kind -eq 'audio') {
        $argsList += @('-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '0')
        Write-Host "Скачиваю только аудио (mp3)..." -ForegroundColor Green
    } else {
        $h = $format.Height
        $selector = "bv*[height<=$h][ext=mp4][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=$h]+ba/b[height<=$h]"
        $argsList += @('-f', $selector, '--merge-output-format', 'mp4')
        Write-Host "Скачиваю видео до ${h}p (mp4)..." -ForegroundColor Green
    }

    $argsList += $url
    $started = Get-Date

    & $YtDlp @argsList
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Host "yt-dlp завершился с ошибкой (код $exitCode)." -ForegroundColor Red
        Write-Host 'Если проблема с сетью — проверьте, что zapret запущен (ALT11).' -ForegroundColor Yellow
        exit $exitCode
    }

    $newFiles = Get-ChildItem $DownloadDir -File |
        Where-Object { $_.LastWriteTime -ge $started -and $_.Extension -match '\.(mp4|mkv|webm|mp3|m4a)$' } |
        Sort-Object LastWriteTime

    Write-Header 'Готово'
    if ($newFiles) {
        foreach ($f in $newFiles) {
            Write-Host ("  {0}" -f $f.FullName) -ForegroundColor Green
            Write-Host ("  {0:N1} МБ" -f ($f.Length / 1MB)) -ForegroundColor DarkGray
        }
    } else {
        Write-Host "Файл уже был скачан ранее: $DownloadDir" -ForegroundColor Yellow
    }
}
finally {
    if ($proxyProc -and -not $proxyProc.HasExited) {
        Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue
        Write-Host 'Прокси остановлен, порт освобождён.' -ForegroundColor DarkGray
    }
    if ($script:zapretStartedByUs -and $script:zapretProc) {
        try {
            Stop-Process -Id $script:zapretProc.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host 'zapret остановлен.' -ForegroundColor DarkGray
        } catch {
            Write-Host 'Не удалось остановить zapret автоматически.' -ForegroundColor Yellow
        }
    } else {
        Write-Host 'zapret оставлен запущенным (был запущен до скрипта).' -ForegroundColor DarkGray
    }
    Remove-Item $proxyLog, ($proxyLog + '.out') -ErrorAction SilentlyContinue
}
