# YouTube Downloader (zapret + DoH)

Портабельный скрипт для скачивания видео с YouTube в РФ с обходом блокировок ТСПУ/DPI через [Flowseal/zapret](https://github.com/Flowseal/zapret-discord-youtube).

## Что внутри репозитория

| Папка / файл | Назначение |
|---|---|
| `scripts/downloader.ps1` | Основной скрипт на PowerShell |
| `scripts/launch.cmd` | Запуск двойным кликом (вызывает PowerShell) |
| `proxy/doh_proxy.py` | Локальный DoH-прокси (обходит отравленный DNS) |
| `tools/` | Сюда кладете `yt-dlp.exe` отдельно (не входит в репозиторий из-за размера) |
| `tools/ffmpeg/` | Сюда кладете `ffmpeg.exe`, `ffplay.exe`, `ffprobe.exe` отдельно |
| `zapret/` | Рабочая конфигурация zapret (стратегия ALT11) |

## Быстрый старт

1. **Склонируйте репозиторий** или скачайте ZIP и распакуйте в любую папку.
2. **Скачайте недостающие утилиты** (они слишком велики для GitHub):
   - [yt-dlp.exe](https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe) → положите в `tools\`
   - [FFmpeg](https://www.ffmpeg.org/download.html) → положите `ffmpeg.exe`, `ffplay.exe`, `ffprobe.exe` в `tools\ffmpeg\`
3. Дважды кликните по `scripts\launch.cmd`.
4. Вставьте ссылку на видео (`youtube.com/watch?v=...` или `youtu.be/...`).
5. Выберите качество: 144p / 360p / 720p / 1080p / только аудио (mp3).
6. Видео появится в папке **Загрузки / Downloads текущего пользователя**.

## Как это работает

- **zapret** обходит DPI-блокировку трафика к YouTube.
- Обычный DNS в РФ отравлен ТСПУ, поэтому скрипт временно поднимает локальный **DoH-прокси** (`proxy\doh_proxy.py`), который разрешает домены через DNS-over-HTTPS. yt-dlp ходит через этот прокси, и обход zapret остаётся сквозным.
- После скачивания скрипт **останавливает свой DoH-прокси** и **закрывает zapret**, если запустил его сам. Если zapret был запущен Вами до скрипта — он останется работать.

## Требования

- Windows 10 или 11
- **Права администратора** — нужны для запуска zapret (он использует WinDivert для фильтрации сетевого трафика)
- yt-dlp.exe и ffmpeg нужно скачать отдельно (ссылки в разделе «Быстрый старт»)

## Если что-то не работает

- Убедитесь, что antivirus не блокирует `winws.exe` и `yt-dlp.exe`.
- Если скрипт пишет, что не найден `ffmpeg.exe` — положите `ffmpeg.exe`, `ffplay.exe`, `ffprobe.exe` в папку `tools\ffmpeg\`.
- Если youtube не открывается — проверьте, что в папке `zapret/` лежит `general (ALT11).bat` и все файлы из `bin/` и `lists/`.

## Используемые проекты

Этот скрипт использует сторонние инструменты с открытым исходным кодом:

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — скачивание видео с YouTube и многих других сайтов.
- [zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube/) — обход блокировок ТСПУ/DPI для YouTube и Discord в РФ.
- [FFmpeg](https://www.ffmpeg.org/) — склейка видео и аудио дорожек в один файл.

Все три проекта — открытое программное обеспечение. Ссылки ведут на их официальные репозитории.
