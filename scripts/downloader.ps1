# YouTube Downloader (zapret + DoH) — TUI версия
# Интерактивное терминальное меню, не закрывается после скачивания.
# Размещено: scripts/downloader.ps1

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.1.0'

# ------------------------- настройки -------------------------
$ProjectRoot   = Split-Path -Parent $PSScriptRoot
$YtDlp         = Join-Path $ProjectRoot 'tools\yt-dlp.exe'
$ProxyScript   = Join-Path $ProjectRoot 'proxy\doh_proxy.py'
# Папка Загрузки/Downloads текущего пользователя (работает на любом языке Windows)
$shell         = New-Object -ComObject Shell.Application
$DownloadDir   = $shell.Namespace('shell:Downloads').Self.Path

# FFmpeg: сначала ищем в системном пути, затем в папке проекта
if (Test-Path 'C:\ffmpeg\bin\ffmpeg.exe') {
    $FfmpegDir = 'C:\ffmpeg\bin'
} elseif (Test-Path (Join-Path $ProjectRoot 'tools\ffmpeg\ffmpeg.exe')) {
    $FfmpegDir = Join-Path $ProjectRoot 'tools\ffmpeg'
} else {
    $FfmpegDir = $null
}
$ZapretBat     = Join-Path $ProjectRoot 'zapret\general (ALT11).bat'
# ------------------------------------------------------------

function Clear-Screen {
    [console]::Clear()
}

function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host ('═' * 58) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('═' * 58) -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-MenuItem {
    param([int]$Num, [string]$Text, [string]$Desc = '')
    Write-Host ("  {0}) {1}" -f $Num, $Text) -ForegroundColor White
    if ($Desc) {
        Write-Host ("      {0}" -f $Desc) -ForegroundColor DarkGray
    }
}

function Show-MainMenu {
    Clear-Screen
    Write-Header "YouTube Downloader v$script:AppVersion (zapret + DoH)"
    Write-Host "  Текущая папка загрузки: $DownloadDir" -ForegroundColor DarkGray
    Write-Host "  FFmpeg: $FfmpegDir" -ForegroundColor DarkGray
    Write-Host ""
    Write-MenuItem 1 "Скачать видео" "Вставьте ссылку и выберите качество"
    Write-MenuItem 2 "Установить зависимости" "yt-dlp.exe и ffmpeg"
    Write-MenuItem 3 "Версия программы" "Показать версию и информацию"
    Write-MenuItem 0 "Выход" "Закрыть программу"
    Write-Host ''
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
        $raw = Read-Host '  Вставьте ссылку на видео (youtube.com или youtu.be)'
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host '  Ссылка пустая, попробуйте ещё раз.' -ForegroundColor Yellow
            continue
        }
        $url = $raw.Trim()
        if ($url -notmatch '^https?://') { $url = 'https://' + $url }
        if ($url -match '^https?://(www\.|m\.|music\.)?(youtube\.com/(watch\?|shorts/|live/|embed/)|youtu\.be/)[\w\-]+') {
            return $url
        }
        Write-Host '  Это не похоже на ссылку YouTube. Примеры:' -ForegroundColor Yellow
        Write-Host '    https://www.youtube.com/watch?v=uvCxZ-Kv1q4' -ForegroundColor DarkGray
        Write-Host '    https://youtu.be/uvCxZ-Kv1q4' -ForegroundColor DarkGray
    }
}

function Get-FormatChoice {
    while ($true) {
        Clear-Screen
        Write-Header "Выберите формат"
        Write-MenuItem 1 "144p" "Низкое качество, быстрое скачивание"
        Write-MenuItem 2 "360p" "Среднее качество"
        Write-MenuItem 3 "720p" "HD качество (рекомендуется)"
        Write-MenuItem 4 "1080p" "Full HD качество"
        Write-MenuItem 5 "Только аудио (mp3)" "Без видео, только звук"
        Write-MenuItem 0 "Назад" "Вернуться в главное меню"
        Write-Host ''
        $choice = Read-Host '  Ваш выбор [0-5]'
        switch ($choice.Trim().ToLower()) {
            { $_ -in '1', '144', '144p' }                { return @{ Kind = 'video'; Height = 144 } }
            { $_ -in '2', '360', '360p' }                { return @{ Kind = 'video'; Height = 360 } }
            { $_ -in '3', '720', '720p' }                { return @{ Kind = 'video'; Height = 720 } }
            { $_ -in '4', '1080', '1080p' }              { return @{ Kind = 'video'; Height = 1080 } }
            { $_ -in '5', 'audio', 'аудио', 'mp3' }      { return @{ Kind = 'audio'; Height = 0 } }
            { $_ -in '0', 'назад', 'back' }              { return $null }
            default { Write-Host '  Введите 0, 1, 2, 3, 4 или 5.' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
        }
    }
}

function Test-ZapretRunning {
    $proc = Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue
    return $null -ne $proc
}

function Start-Zapret {
    if (-not (Test-Path $ZapretBat)) {
        throw "Не найден файл запуска zapret: $ZapretBat`nПоложите папку zapret рядом со скриптом."
    }
    Write-Host "  Запускаю zapret ..." -ForegroundColor Cyan
    Start-Process -FilePath $ZapretBat -WindowStyle Hidden -ErrorAction Stop | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-ZapretRunning) {
            Write-Host '  zapret запущен (winws.exe активен).' -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 1
    }
    throw 'Не удалось дождаться запуска winws.exe (zapret).'
}

function Download-Video {
    Write-Host ''
    $url = Get-VideoUrl
    $format = Get-FormatChoice
    if ($null -eq $format) {
        Write-Host '  Возврат в главное меню...' -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
        return
    }

    # Проверка файлов
    foreach ($p in @($YtDlp, $ProxyScript, $ZapretBat)) {
        if (-not (Test-Path $p)) {
            Write-Host "  ОШИБКА: Не найден файл: $p" -ForegroundColor Red
            Write-Host '  Положите yt-dlp.exe в tools/, а папку zapret рядом со скриптом.' -ForegroundColor Yellow
            Write-Host ''
            Read-Host '  Нажмите Enter для возврата в меню'
            return
        }
    }
    if (-not $FfmpegDir -or -not (Test-Path (Join-Path $FfmpegDir 'ffmpeg.exe'))) {
        Write-Host '  ОШИБКА: Не найден ffmpeg.' -ForegroundColor Red
        Write-Host '  Положите ffmpeg.exe в C:\ffmpeg\bin\ или в tools\ffmpeg\.' -ForegroundColor Yellow
        Write-Host ''
        Read-Host '  Нажмите Enter для возврата в меню'
        return
    }
    if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir | Out-Null }

    # --- проверка/запуск zapret ---
    $zapretStartedByUs = $false
    $zapretProc = $null
    if (-not (Test-ZapretRunning)) {
        Write-Host "  Запускаю zapret из $ZapretBat ..." -ForegroundColor Cyan
        Start-Process -FilePath $ZapretBat -WindowStyle Hidden -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            $proc = Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue
            if ($proc) {
                $zapretProc = $proc
                $zapretStartedByUs = $true
                Write-Host '  zapret запущен.' -ForegroundColor Green
                break
            }
            Start-Sleep -Seconds 1
        }
        if (-not $zapretStartedByUs) {
            Write-Host '  ОШИБКА: Не удалось запустить zapret.' -ForegroundColor Red
            Write-Host ''
            Read-Host '  Нажмите Enter для возврата в меню'
            return
        }
    } else {
        Write-Host '  zapret уже запущен.' -ForegroundColor DarkGray
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
            Write-Host '  ОШИБКА: Не удалось запустить DoH-прокси.' -ForegroundColor Red
            if (Test-Path $proxyLog) { Get-Content $proxyLog -Tail 10 }
            Write-Host ''
            Read-Host '  Нажмите Enter для возврата в меню'
            return
        }
        Write-Host "  Прокси запущен на 127.0.0.1:$port" -ForegroundColor DarkGray

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
            Write-Host "  Скачиваю только аудио (mp3)..." -ForegroundColor Green
        } else {
            $h = $format.Height
            $selector = "bv*[height<=$h][ext=mp4][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=$h]+ba/b[height<=$h]"
            $argsList += @('-f', $selector, '--merge-output-format', 'mp4')
            Write-Host "  Скачиваю видео до ${h}p (mp4)..." -ForegroundColor Green
        }

        $argsList += $url
        $started = Get-Date

        & $YtDlp @argsList
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Host "  yt-dlp завершился с ошибкой (код $exitCode)." -ForegroundColor Red
            Write-Host '  Проверьте, что zapret запущен и интернет работает.' -ForegroundColor Yellow
        } else {
            $newFiles = Get-ChildItem $DownloadDir -File |
                Where-Object { $_.LastWriteTime -ge $started -and $_.Extension -match '\.(mp4|mkv|webm|mp3|m4a)$' } |
                Sort-Object LastWriteTime
            Write-Host ''
            Write-Host '════════════════════════════════════════════' -ForegroundColor Green
            Write-Host '  ГОТОВО!' -ForegroundColor Green
            Write-Host '════════════════════════════════════════════' -ForegroundColor Green
            if ($newFiles) {
                foreach ($f in $newFiles) {
                    Write-Host ("  {0}" -f $f.FullName) -ForegroundColor Green
                    Write-Host ("  {0:N1} МБ" -f ($f.Length / 1MB)) -ForegroundColor DarkGray
                }
            } else {
                Write-Host '  Файл уже был скачан ранее.' -ForegroundColor Yellow
            }
        }
    }
    finally {
        if ($proxyProc -and -not $proxyProc.HasExited) {
            Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue
            Write-Host '  Прокси остановлен.' -ForegroundColor DarkGray
        }
        if ($zapretStartedByUs -and $zapretProc) {
            try {
                Stop-Process -Id $zapretProc.ProcessId -Force -ErrorAction SilentlyContinue
                Write-Host '  zapret остановлен.' -ForegroundColor DarkGray
            } catch {
                Write-Host '  Не удалось остановить zapret автоматически.' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  zapret оставлен запущенным.' -ForegroundColor DarkGray
        }
        Remove-Item $proxyLog, ($proxyLog + '.out') -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Read-Host '  Нажмите Enter для возврата в главное меню'
}

function Install-Dependencies {
    Clear-Screen
    Write-Header "Установка зависимостей"
    Write-Host ''
    Write-Host '  1) Скачать yt-dlp.exe -> tools\yt-dlp.exe' -ForegroundColor White
    Write-Host '     Источник: https://github.com/yt-dlp/yt-dlp/releases' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  2) Скачать ffmpeg -> tools\ffmpeg\ (ffmpeg.exe, ffplay.exe, ffprobe.exe)' -ForegroundColor White
    Write-Host '     Альтернатива: установить в C:\ffmpeg\bin\ - скрипт найдёт автоматически' -ForegroundColor DarkGray
    Write-Host '     Источник: https://www.ffmpeg.org/download.html' -ForegroundColor DarkGray
    Write-Host ''
    Write-MenuItem 0 "Назад" "Вернуться в главное меню"
    Write-Host ''
    $choice = Read-Host '  Ваш выбор [0-2]'
    if ($choice -in '1') {
        Write-Host ''
        Write-Host '  Откройте в браузере: https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' -ForegroundColor Cyan
        Write-Host '  Положите файл в: tools\yt-dlp.exe' -ForegroundColor Cyan
    } elseif ($choice -in '2') {
        Write-Host ''
        Write-Host '  Откройте в браузере: https://www.ffmpeg.org/download.html' -ForegroundColor Cyan
        Write-Host '  Положите файлы в: tools\ffmpeg\  или установите в C:\ffmpeg\bin\' -ForegroundColor Cyan
    }
    Write-Host ''
    Read-Host '  Нажмите Enter для возврата в меню'
}

function Show-Version {
    Clear-Screen
    Write-Header "Версия программы"
    Write-Host ''
    Write-Host "  Версия: $script:AppVersion" -ForegroundColor White
    Write-Host "  yt-dlp: $(Join-Path $ProjectRoot 'tools\yt-dlp.exe')" -ForegroundColor DarkGray
    Write-Host "  FFmpeg: $FfmpegDir" -ForegroundColor DarkGray
    Write-Host "  Zapret: $ZapretBat" -ForegroundColor DarkGray
    Write-Host "  Загрузки: $DownloadDir" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  Используемые проекты с открытым кодом:" -ForegroundColor DarkGray
    Write-Host "    yt-dlp:   https://github.com/yt-dlp/yt-dlp" -ForegroundColor DarkGray
    Write-Host "    zapret:   https://github.com/Flowseal/zapret-discord-youtube/" -ForegroundColor DarkGray
    Write-Host "    FFmpeg:   https://www.ffmpeg.org/" -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  Нажмите Enter для возврата в меню'
}

# --------------------------- главный цикл ---------------------------
while ($true) {
    Show-MainMenu
    $choice = Read-Host '  Ваш выбор [0-3]'
    switch ($choice.Trim()) {
        '1' { Download-Video }
        '2' { Install-Dependencies }
        '3' { Show-Version }
        '0' {
            Write-Host ''
            Write-Host '  До свидания!' -ForegroundColor Cyan
            break
        }
        default {
            Write-Host '  Неверный выбор, попробуйте ещё раз.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
    if ($choice -eq '0') { break }
}
