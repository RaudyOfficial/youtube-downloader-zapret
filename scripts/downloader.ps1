# YouTube Downloader (zapret + DoH) — v1.2.0
# Тёмный терминальный интерфейс по референсу ref_design.png
# scripts/downloader.ps1

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.2.0'

# ------------------------- настройки -------------------------
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$YtDlp       = Join-Path $ProjectRoot 'tools\yt-dlp.exe'
$ProxyScript = Join-Path $ProjectRoot 'proxy\doh_proxy.py'
$shell       = New-Object -ComObject Shell.Application
$DownloadDir = $shell.Namespace('shell:Downloads').Self.Path

if (Test-Path 'C:\ffmpeg\bin\ffmpeg.exe') {
    $FfmpegDir = 'C:\ffmpeg\bin'
} elseif (Test-Path (Join-Path $ProjectRoot 'tools\ffmpeg\ffmpeg.exe')) {
    $FfmpegDir = Join-Path $ProjectRoot 'tools\ffmpeg'
} else {
    $FfmpegDir = $null
}
$ZapretBat = Join-Path $ProjectRoot 'zapret\general (ALT11).bat'
# ------------------------------------------------------------

# ---------------- UTF-8 + VT (ANSI) ----------------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try {
    if (-not ('ConsoleVT' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleVT {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    public static void Enable() {
        IntPtr h = GetStdHandle(-11);
        uint mode;
        if (GetConsoleMode(h, out mode)) SetConsoleMode(h, mode | 0x0004);
    }
}
'@
        [ConsoleVT]::Enable()
    }
} catch { }

# ---------------- палитра ----------------
$script:ESC = [char]27
function Esc([string]$seq) { return "$($script:ESC)[$seq" }
function Fg([string]$rgb)  { return "$($script:ESC)[38;2;${rgb}m" }
function Bg([string]$rgb)  { return "$($script:ESC)[48;2;${rgb}m" }
$script:RESET = "$($script:ESC)[0m"

$script:P = @{
    bg      = '11;11;12'
    panel   = '26;26;26'
    blue    = '59;130;246'
    white   = '245;245;245'
    light   = '208;208;212'
    gray    = '150;150;156'
    dim     = '108;108;114'
    faint   = '70;70;76'
    red     = '229;72;77'
    track   = '33;33;36'
    logoRed = '226;45;38'
    logoGray= '118;118;124'
}

# ---------------- состояние ----------------
$script:qualities = @(
    @{ Label = '144';  Kind = 'video'; Height = 144  },
    @{ Label = '360';  Kind = 'video'; Height = 360  },
    @{ Label = '720';  Kind = 'video'; Height = 720  },
    @{ Label = '1080'; Kind = 'video'; Height = 1080 },
    @{ Label = 'MP3';  Kind = 'audio'; Height = 0    }
)
$script:url           = ''
$script:qIdx          = 3
$script:state         = 'input'
$script:focus         = 'url'
$script:progress      = 0.0
$script:logs          = New-Object System.Collections.ArrayList
$script:progressLogId = $null
$script:lastSize      = ''

function New-Pad([int]$n) { if ($n -le 0) { return '' } return (' ' * $n) }

function Add-Log {
    param([string]$Text, [string]$Tag = 'info')
    [void]$script:logs.Add([pscustomobject]@{
        Time = (Get-Date -Format 'HH:mm:ss')
        Tag  = $Tag
        Text = $Text
        Id   = [guid]::NewGuid().ToString('N')
    })
    while ($script:logs.Count -gt 300) { $script:logs.RemoveAt(0) }
}

function Update-ProgressLog([string]$Text) {
    if (-not $script:progressLogId) { return }
    for ($i = 0; $i -lt $script:logs.Count; $i++) {
        if ($script:logs[$i].Id -eq $script:progressLogId) { $script:logs[$i].Text = $Text; return }
    }
    [void]$script:logs.Add([pscustomobject]@{
        Time = (Get-Date -Format 'HH:mm:ss')
        Tag  = 'download'
        Text = $Text
        Id   = $script:progressLogId
    })
}

function Fmt1([double]$v) {
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', $v)
}

# ---------------- рендер ----------------
function Render-Ui {
    try {
        $W = [Console]::WindowWidth
        $H = [Console]::WindowHeight
    } catch { return }
    if ($W -le 0 -or $H -le 0) { return }
    $script:lastSize = "$W x $H"

    $P = $script:P
    $out = New-Object System.Text.StringBuilder
    [void]$out.Append((Esc 'H'))
    [void]$out.Append((Bg $P.bg))
    [void]$out.Append((Esc '2J'))

    if ($W -lt 50 -or $H -lt 16) {
        $msg = 'Увеличьте окно терминала'
        $pad = New-Pad ([Math]::Max(0, [int](($W - $msg.Length) / 2)))
        [void]$out.Append('')
        [void]$out.Append($pad + (Fg $P.faint) + $msg + $script:RESET)
        [Console]::Write($out.ToString())
        return
    }

    $rows = New-Object System.Collections.Generic.List[string]
    $margin = 2
    $logW = [Math]::Max(20, $W - 2 * $margin)
    $logLines = [Math]::Max(3, [Math]::Min(10, $H - 18))
    $compact = $W -lt 78

    # --- логотип ---
    if ($compact) {
        $logoText = '► yt-dlp'
        $pad = New-Pad ([Math]::Max(0, [int](($W - $logoText.Length) / 2)))
        $rows.Add($pad + (Fg $P.logoRed) + '►' + $script:RESET + ' ' + (Fg $P.white) + 'yt-dlp' + $script:RESET)
    } else {
        $glyphs = @{
            'y' = @('██  ██','██  ██',' ████ ','  ██  ','  ██  ')
            't' = @('██████','  ██  ','  ██  ','  ██  ','  ██  ')
            '-' = @('      ','      ','██████','      ','      ')
            'd' = @('█████ ','██  ██','██  ██','██  ██','█████ ')
            'l' = @('██    ','██    ','██    ','██    ','██████')
            'p' = @('█████ ','██  ██','█████ ','██    ','██    ')
        }
        $order = @('y','t','-','d','l','p')
        $colr  = @($P.logoGray, $P.logoGray, $P.white, $P.white, $P.white, $P.white)
        for ($r = 0; $r -lt 5; $r++) {
            $s = New-Pad ([Math]::Max(0, [int](($W - 52) / 2)))
            switch ($r) {
                0 { $s += (Fg $P.logoRed) + ' ███ ' + $script:RESET }
                1 { $s += (Fg $P.logoRed) + '█████' + $script:RESET }
                2 { $s += (Fg $P.logoRed) + '██' + (Bg $P.logoRed) + (Fg $P.white) + '►' + $script:RESET + (Fg $P.logoRed) + '██' + $script:RESET }
                3 { $s += (Fg $P.logoRed) + '█████' + $script:RESET }
                4 { $s += (Fg $P.logoRed) + ' ███ ' + $script:RESET }
            }
            $s += ' '
            for ($g = 0; $g -lt $order.Count; $g++) {
                $s += (Fg $colr[$g]) + $glyphs[$order[$g]][$r] + $script:RESET
                if ($g -lt $order.Count - 1) { $s += '  ' }
            }
            $rows.Add($s)
        }
    }

    $rows.Add('')

    # --- поле ввода ---
    $inputW = [Math]::Max(30, [Math]::Min([int]($W * 0.68), 96))
    $inputW = [Math]::Min($inputW, $W - 2)
    $inner = $inputW - 2
    $padL = New-Pad ([Math]::Max(0, [int](($W - $inputW) / 2)))
    $urlFocus = ($script:state -eq 'input' -and $script:focus -eq 'url')
    if ([string]::IsNullOrEmpty($script:url)) {
        $shown = 'Вставьте ссылку на видео с YouTube...'
        $textColor = $P.dim
    } else {
        $shown = $script:url
        if ($urlFocus) { $shown += '▏' }
        $textColor = $P.light
        if ($shown.Length -gt $inner) { $shown = '…' + $shown.Substring($shown.Length - $inner + 1) }
    }
    if ($shown.Length -gt $inner) { $shown = $shown.Substring(0, [Math]::Max(0, $inner - 1)) + '…' }
    $fill = [Math]::Max(0, $inner - $shown.Length)
    $barColor = $P.track
    if ($urlFocus) { $barColor = $P.blue }
    $rows.Add($padL + (Bg $P.panel) + (Fg $barColor) + '▌' + (Fg $textColor) + ' ' + $shown + (' ' * $fill) + $script:RESET)

    $rows.Add('')

    # --- качество ---
    $sep = '  '
    if ($W -lt 50) { $sep = '' }
    $btnPlain = (($script:qualities | ForEach-Object { '[ ' + $_.Label + ' ]' }) -join $sep)
    $btnPad = New-Pad ([Math]::Max(0, [int](($W - $btnPlain.Length) / 2)))
    $btnStr = ''
    $qualityFocus = ($script:state -eq 'input' -and $script:focus -eq 'quality')
    for ($i = 0; $i -lt $script:qualities.Count; $i++) {
        $b = '[ ' + $script:qualities[$i].Label + ' ]'
        if ($i -eq $script:qIdx) {
            if ($qualityFocus) {
                $btnStr += (Bg $P.white) + (Fg '11;11;12') + $b + $script:RESET
            } else {
                $btnStr += (Bg '58;58;62') + (Fg $P.white) + $b + $script:RESET
            }
        } else {
            $btnStr += (Fg $P.gray) + $b + $script:RESET
        }
        if ($i -lt $script:qualities.Count - 1) { $btnStr += $sep }
    }
    $rows.Add($btnPad + $btnStr)

    $rows.Add('')

    # --- логи ---
    $visible = @()
    if ($script:logs.Count -gt 0) {
        $start = [Math]::Max(0, $script:logs.Count - $logLines)
        for ($i = $start; $i -lt $script:logs.Count; $i++) { $visible += $script:logs[$i] }
    }
    $logPadL = New-Pad $margin
    for ($i = 0; $i -lt $logLines; $i++) {
        if ($i -lt $visible.Count) {
            $l = $visible[$i]
            $timeStr = '[' + $l.Time + ']'
            $tagStr  = '[' + $l.Tag + ']'
            $tagColor = $P.gray
            if ($l.Tag -eq 'download') { $tagColor = $P.blue }
            elseif ($l.Tag -eq 'error') { $tagColor = $P.red }
            $msgColor = $P.light
            if ($l.Tag -eq 'download') { $msgColor = $P.white }
            elseif ($l.Tag -eq 'error') { $msgColor = $P.red }
            $avail = $logW - ($timeStr.Length + 1 + $tagStr.Length + 1)
            $msg = [string]$l.Text
            if ($msg.Length -gt $avail) { $msg = $msg.Substring(0, [Math]::Max(0, $avail - 1)) + '…' }
            $rows.Add($logPadL + (Fg $P.dim) + $timeStr + $script:RESET + ' ' +
                      (Fg $tagColor) + $tagStr + $script:RESET + ' ' +
                      (Fg $msgColor) + $msg + $script:RESET)
        } else {
            $rows.Add('')
        }
    }

    $rows.Add('')

    # --- прогресс ---
    $pctStr = (Fmt1 ([double]$script:progress)) + '%'
    $pctW = 8
    $barW = [Math]::Max(10, $W - 2 * $margin - $pctW)
    $fillW = [int][Math]::Round($barW * [double]$script:progress / 100.0)
    if ($fillW -lt 0) { $fillW = 0 }
    if ($fillW -gt $barW) { $fillW = $barW }
    $bar = (Fg $P.blue) + ('█' * $fillW) + $script:RESET + (Fg $P.track) + ('█' * ($barW - $fillW)) + $script:RESET
    $pctPad = New-Pad ([Math]::Max(0, $pctW - $pctStr.Length))
    $rows.Add((New-Pad $margin) + $bar + $pctPad + (Fg $P.white) + $pctStr + $script:RESET)

    $rows.Add('')

    # --- подсказка ---
    if ($script:state -eq 'downloading') {
        $hint = 'Скачивание...  не закрывайте окно'
    } elseif ($script:state -eq 'done') {
        $hint = 'Enter — новое видео     Esc — выход'
    } elseif ($W -lt 78) {
        if ($script:focus -eq 'quality') { $hint = '← → качество   Tab — ссылка   Enter — скачать   Esc — выход' }
        else { $hint = 'Tab — качество   Enter — скачать   Esc — выход' }
    } elseif ($script:focus -eq 'quality') {
        $hint = '← → качество     Tab — к ссылке     Enter — скачать     Esc — выход'
    } else {
        $hint = 'Tab — к выбору качества     Enter — скачать     Ctrl+V — вставить     Esc — выход'
    }
    if ($hint.Length -gt $W - 2) { $hint = $hint.Substring(0, [Math]::Max(0, $W - 3)) + '…' }
    $rows.Add((New-Pad ([Math]::Max(0, [int](($W - $hint.Length) / 2)))) + (Fg $P.faint) + $hint + $script:RESET)

    # --- вывод ---
    $contentH = $rows.Count
    $topPad = [Math]::Max(0, [int][Math]::Floor(($H - $contentH) / 2))
    $sb = $out
    [void]$sb.Append("`n" * $topPad)
    for ($i = 0; $i -lt $rows.Count; $i++) {
        [void]$sb.Append($rows[$i])
        [void]$sb.Append((Bg $P.bg))
        [void]$sb.Append((Esc 'K'))
        if ($i -lt $rows.Count - 1) { [void]$sb.Append("`n") }
    }
    [void]$sb.Append((Bg $P.bg))
    [void]$sb.Append((Esc 'J'))
    [void]$sb.Append($script:RESET)
    [Console]::Write($sb.ToString())
}

# ---------------- сеть / процесс ----------------
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

function Test-ZapretRunning {
    $proc = Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue
    return $null -ne $proc
}

function ConvertTo-ArgString([string]$a) {
    if ($null -eq $a) { return '""' }
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

function Handle-YtDlpLine([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return }

    if ($line -match '^\[download\]\s+([\d.]+)%\s+of\s+~?\s*([\d.]+)([KMGT]?i?B)(.*)$') {
        $pct  = [double]$Matches[1]
        $size = [double]$Matches[2]
        $unit = $Matches[3]
        $rest = $Matches[4]
        $script:progress = $pct
        $down = $size * $pct / 100.0
        $speed = ''
        if ($rest -match 'at\s+([\d.]+)\s*([KMGT]?i?B/s)') {
            $speed = ' at ' + (Fmt1 ([double]$Matches[1])) + ' ' + $Matches[2]
        }
        $text = (Fmt1 $down) + ' ' + $unit + ' / ' + (Fmt1 $size) + ' ' + $unit + ' (' + (Fmt1 $pct) + '%)' + $speed
        Update-ProgressLog $text
        return
    }

    if ($line -match '^\[download\]\s+Destination:\s*(.+)$') {
        Add-Log ('Saving to: "' + (Split-Path -Leaf $Matches[1].Trim()) + '"') 'info'
        return
    }

    if ($line -match '^\[([\w-]+)\]\s*(.*)$') {
        $tag = $Matches[1]
        $msg = $Matches[2].Trim()
        if ($tag -eq 'download') { Add-Log $msg 'download'; return }
        if ($tag -in @('youtube', 'generic', 'extractor', 'webpage')) { $tag = 'info' }
        Add-Log $msg $tag
        return
    }

    if ($line -match '^ERROR:\s*(.*)$')   { Add-Log $Matches[1] 'error'; return }
    if ($line -match '^WARNING:\s*(.*)$') { Add-Log $Matches[1] 'warn';  return }
    Add-Log $line 'info'
}

function Read-OutputFile([string]$Path, [int]$From) {
    if (-not (Test-Path -LiteralPath $Path)) { return $From }
    try {
        $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop)
    } catch { return $From }
    for ($i = $From; $i -lt $lines.Count; $i++) { Handle-YtDlpLine $lines[$i] }
    return $lines.Count
}

# ---------------- скачивание ----------------
function Start-Download {
    $u = $script:url.Trim()
    if ([string]::IsNullOrWhiteSpace($u)) {
        Add-Log 'Введите ссылку на видео' 'error'
        return
    }
    if ($u -notmatch '^https?://') { $u = 'https://' + $u }
    if ($u -notmatch '^https?://(www\.|m\.|music\.)?(youtube\.com/(watch\?|shorts/|live/|embed/)|youtu\.be/)[\w\-]+') {
        Add-Log 'Это не похоже на ссылку YouTube' 'error'
        return
    }
    $script:url = $u

    foreach ($p in @($YtDlp, $ProxyScript, $ZapretBat)) {
        if (-not (Test-Path -LiteralPath $p)) {
            Add-Log ('Не найден файл: ' + $p) 'error'
            return
        }
    }
    if (-not $FfmpegDir -or -not (Test-Path (Join-Path $FfmpegDir 'ffmpeg.exe'))) {
        Add-Log 'Не найден ffmpeg.exe (C:\ffmpeg\bin или tools\ffmpeg)' 'error'
        return
    }
    if (-not (Test-Path -LiteralPath $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
    }

    $fmt = $script:qualities[$script:qIdx]
    $script:state = 'downloading'
    $script:progress = 0.0
    $script:progressLogId = [guid]::NewGuid().ToString('N')
    Add-Log ('Качество: ' + $fmt.Label) 'info'
    Render-Ui

    $ok = $false
    $zapretStartedByUs = $false
    $zapretProc = $null
    $proxyProc  = $null
    $outFile = $null; $errFile = $null; $proxyOut = $null; $proxyErr = $null

    try {
        if (-not (Test-ZapretRunning)) {
            Add-Log 'Запуск zapret...' 'info'
            Render-Ui
            Start-Process -FilePath $ZapretBat -WindowStyle Hidden -ErrorAction Stop | Out-Null
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                $proc = Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue
                if ($proc) { $zapretProc = $proc; $zapretStartedByUs = $true; break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $zapretStartedByUs) { Add-Log 'Не удалось запустить zapret' 'error'; return }
            Add-Log 'zapret запущен' 'info'
        } else {
            Add-Log 'zapret уже запущен' 'info'
        }

        $port = Get-FreePort
        if (Get-Command py -ErrorAction SilentlyContinue) {
            $pyExe = 'py'; $pyArgs = @('-3', $ProxyScript, "$port")
        } elseif (Get-Command python -ErrorAction SilentlyContinue) {
            $pyExe = 'python'; $pyArgs = @($ProxyScript, "$port")
        } else {
            Add-Log 'Не найден Python (py / python)' 'error'; return
        }
        $proxyOut = Join-Path ([IO.Path]::GetTempPath()) ("ytdlp_proxy_$port.out")
        $proxyErr = Join-Path ([IO.Path]::GetTempPath()) ("ytdlp_proxy_$port.err")
        $pyArgStr = (($pyArgs | ForEach-Object { ConvertTo-ArgString $_ }) -join ' ')
        $proxyProc = Start-Process -FilePath $pyExe -ArgumentList $pyArgStr -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $proxyOut -RedirectStandardError $proxyErr
        Add-Log "DoH-прокси: 127.0.0.1:$port" 'info'
        Render-Ui
        if (-not (Wait-Port -Port $port -TimeoutSec 20)) {
            Add-Log 'Не удалось запустить DoH-прокси' 'error'; return
        }

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
        if ($FfmpegDir -and (Test-Path $FfmpegDir)) { $argsList += @('--ffmpeg-location', $FfmpegDir) }
        if ($fmt.Kind -eq 'audio') {
            $argsList += @('-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '0')
        } else {
            $h = $fmt.Height
            $selector = "bv*[height<=$h][ext=mp4][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=$h]+ba/b[height<=$h]"
            $argsList += @('-f', $selector, '--merge-output-format', 'mp4')
        }
        $argsList += $u

        $outFile = Join-Path ([IO.Path]::GetTempPath()) ("ytdlp_" + [guid]::NewGuid().ToString('N') + ".out")
        $errFile = $outFile + '.err'
        $argStr = (($argsList | ForEach-Object { ConvertTo-ArgString $_ }) -join ' ')

        $started = Get-Date
        $yt = Start-Process -FilePath $YtDlp -ArgumentList $argStr -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $readOut = 0; $readErr = 0
        $lastRender = Get-Date
        while (-not $yt.HasExited) {
            $readOut = Read-OutputFile $outFile $readOut
            $readErr = Read-OutputFile $errFile $readErr
            $now = Get-Date
            if (($now - $lastRender).TotalMilliseconds -ge 120) { Render-Ui; $lastRender = $now }
            Start-Sleep -Milliseconds 80
        }
        $readOut = Read-OutputFile $outFile $readOut
        $readErr = Read-OutputFile $errFile $readErr

        if ($yt.ExitCode -eq 0) {
            $script:progress = 100.0
            Add-Log 'Скачивание завершено' 'info'
            $newFiles = @(Get-ChildItem -LiteralPath $DownloadDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $started -and $_.Extension -match '\.(mp4|mkv|webm|mp3|m4a)$' } |
                Sort-Object LastWriteTime)
            foreach ($f in $newFiles) {
                Add-Log ('Сохранено: ' + $f.Name + ' (' + (Fmt1 ($f.Length / 1MB)) + ' МБ)') 'info'
            }
            $ok = $true
        } else {
            Add-Log ('yt-dlp завершился с ошибкой (код ' + $yt.ExitCode + ')') 'error'
        }
    }
    catch {
        Add-Log ('Ошибка: ' + $_.Exception.Message) 'error'
    }
    finally {
        if ($proxyProc -and -not $proxyProc.HasExited) {
            try { Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        if ($zapretStartedByUs -and $zapretProc) {
            try { Stop-Process -Id $zapretProc.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            Add-Log 'zapret остановлен' 'info'
        } elseif ($zapretProc -or (Test-ZapretRunning)) {
            Add-Log 'zapret оставлен запущенным' 'info'
        }
        foreach ($f in @($outFile, $errFile, $proxyOut, $proxyErr)) {
            if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
        if ($ok) { $script:state = 'done' } else { $script:state = 'input' }
        Render-Ui
    }
}

# ---------------- запуск ----------------
Add-Log 'Проверка зависимостей' 'info'
if (Test-Path -LiteralPath $YtDlp) { Add-Log 'yt-dlp найден' 'info' } else { Add-Log 'yt-dlp.exe не найден в tools\' 'error' }
if ($FfmpegDir) { Add-Log ('ffmpeg: ' + $FfmpegDir) 'info' } else { Add-Log 'ffmpeg не найден' 'error' }
if (Test-Path -LiteralPath $ZapretBat) { Add-Log 'zapret готов' 'info' } else { Add-Log 'zapret не найден' 'error' }
Add-Log 'Вставьте ссылку · Tab — качество · Enter — скачать' 'info'

try {
    try { [Console]::CursorVisible = $false } catch { }
    try { [Console]::TreatControlCAsInput = $true } catch { }
    try { [Console]::Title = 'YouTube Downloader' } catch { }
    [Console]::Write((Esc '?1049h') + (Esc '?25l'))

    Render-Ui

    while ($true) {
        $curSize = "$([Console]::WindowWidth) x $([Console]::WindowHeight)"
        if ($curSize -ne $script:lastSize) { Render-Ui }

        if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 60; continue }

        $key = [Console]::ReadKey($true)
        $k = $key.Key
        $ctrl = ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
        $changed = $false

        if ($k -eq [ConsoleKey]::Escape -or ($ctrl -and $k -eq [ConsoleKey]::C)) { break }

        if ($script:state -eq 'done') {
            if ($k -eq [ConsoleKey]::Enter) {
                $script:url = ''
                $script:progress = 0.0
                $script:progressLogId = $null
                $script:state = 'input'
                $script:focus = 'url'
                $changed = $true
            }
        }
        elseif ($script:state -eq 'input') {
            if ($k -eq [ConsoleKey]::Tab) {
                if ($script:focus -eq 'url') { $script:focus = 'quality' } else { $script:focus = 'url' }
                $changed = $true
            }
            elseif ($k -eq [ConsoleKey]::Enter) {
                Start-Download
                $changed = $true
            }
            elseif ($script:focus -eq 'url') {
                if ($k -eq [ConsoleKey]::Backspace) {
                    if ($script:url.Length -gt 0) {
                        $script:url = $script:url.Substring(0, $script:url.Length - 1)
                        $changed = $true
                    }
                }
                elseif ($ctrl -and $k -eq [ConsoleKey]::V) {
                    try { $clip = Get-Clipboard -Raw -ErrorAction Stop } catch { $clip = '' }
                    if ($clip) {
                        $script:url += (($clip -replace '[\r\n]+', ' ').Trim())
                        $changed = $true
                    }
                }
                elseif ($key.KeyChar -and [int]$key.KeyChar -ge 32 -and [int]$key.KeyChar -ne 127) {
                    if ($script:url.Length -lt 600) {
                        $script:url += $key.KeyChar
                        $changed = $true
                    }
                }
            }
            else {
                if ($k -eq [ConsoleKey]::LeftArrow) {
                    if ($script:qIdx -gt 0) { $script:qIdx--; $changed = $true }
                }
                elseif ($k -eq [ConsoleKey]::RightArrow) {
                    if ($script:qIdx -lt $script:qualities.Count - 1) { $script:qIdx++; $changed = $true }
                }
                elseif ($k -eq [ConsoleKey]::Home) {
                    $script:qIdx = 0; $changed = $true
                }
                elseif ($k -eq [ConsoleKey]::End) {
                    $script:qIdx = $script:qualities.Count - 1; $changed = $true
                }
            }
        }

        if ($changed) { Render-Ui }
    }
}
finally {
    [Console]::Write($script:RESET + (Esc '?25h') + (Esc '?1049l'))
    try { [Console]::TreatControlCAsInput = $false } catch { }
    try { [Console]::CursorVisible = $true } catch { }
    Write-Host ''
    Write-Host '  До свидания!' -ForegroundColor DarkGray
    Write-Host ''
}
