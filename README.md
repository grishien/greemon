# greemon

Терминальный монитор железа (GPU, CPU, RAM, диск) в стиле вкладки Overview из Strata.
Чистый PowerShell: без Python, без внешних зависимостей, без прав администратора.

Целевая оболочка — **Windows PowerShell 5.1** (`powershell.exe`), идущая в Windows.
Данные GPU читаются напрямую через NVML (`nvml.dll` из драйвера NVIDIA), с запасным
путём через `nvidia-smi`; CPU/RAM/диск — Win32 API и счётчики производительности.

## Установка

```powershell
git clone <url-репозитория>
cd greemon
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

Установщик копирует `bin\` и `src\` в `%LOCALAPPDATA%\greemon` и добавляет
`%LOCALAPPDATA%\greemon\bin` в пользовательский `PATH` (идемпототентно, реестр не
ломает, `%VAR%`-токены в PATH сохраняет). Откройте новое окно терминала — команда
`greemon` доступна из любой папки в cmd, Windows PowerShell и pwsh. В уже открытых
терминалах нужен перезапуск.

## Удаление

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

Удаляет `%LOCALAPPDATA%\greemon` и убирает её из пользовательского `PATH`.

## Запуск

```
greemon
```

Интерактивный режим требует настоящего терминала (перенаправленный ввод/вывод —
отказ с кодом 2, используйте `-Once`). `q` или Ctrl+C корректно восстанавливают
терминал: курсор, основной экран, кодовую страницу и режим консоли.

### Параметры

| Параметр | Значение |
|---|---|
| `-Gpu <index>` | индекс NVIDIA-карты в нумерации NVML/`nvidia-smi` (по умолчанию 0) |
| `-Interval <sec>` | период обновления, с (по умолчанию 1) |
| `-Label <text>` | текст на месте имени модели в шапке (по умолчанию `hardware monitor`) |
| `-Theme auto\|dark\|light` | тема (по умолчанию auto → dark) |
| `-Glyphs auto\|unicode\|solid\|ascii` | набор глифов; auto подбирает по консоли |
| `-Url <url>` | сервер Strata (`/metrics`) для LLM-панелей; без него панели пустые |
| `-ApiKey <key>` | ключ API сервера; иначе берётся `STRATA_API_KEY` |
| `-Once` | один кадр в поток вывода и выход (для скриптов/перенаправления) |
| `-Mock` | синтетические детерминированные данные без железа |
| `-Help` | справка по параметрам и клавишам |

Также поддерживается переменная окружения `NO_COLOR` (отключает цвет, как в референсе).

### Клавиши

| Клавиша | Действие |
|---|---|
| `1`–`6` | переключение вкладок (работает только Overview, остальные — заглушка) |
| `/` | фильтр (в автономном режиме клавиша отображается, как в референсе, но ничего не меняет) |
| `Space` | заморозить/разморозить кадр |
| `r` | немедленное обновление |
| `t` | цикл темы (auto → dark → light) |
| `b` | открыть сервер в браузере (нужен `-Url`) |
| `?` | краткая справка поверх строки сообщения |
| `q` | выход |

## Ограничения

- Показывается только вкладка **Overview**: вкладки 2–6 в автономном режиме —
  заглушка «недоступно в автономном режиме» (порт справочной утилиты, см. roadmap).
- LLM-панели (Model state, Recent requests, Context fill, Experts in VRAM) пусты
  без `-Url`: они берутся из `/metrics` сервера Strata; без него greemon — чистый
  аппаратный монитор.
- Минимальный размер окна для кадра — 78×23, иначе greemon показывает сообщение.
- Отдельные карты/драйверы не отдают часть значений NVML (например, загрузку и
  мощность GPU на GT 710) — вместо них `--`, программа работает.
- Без NVIDIA-карты GPU-плитки показывают `--`; без счётчиков производительности
  диск показывает `--`.
- Память процесса: рабочий набор ~110 МиБ — это прежде всего базовая планка рантайма
  CLR/PowerShell 5.1 (пустой `powershell.exe` занимает ~70 МиБ); CPU в спокойном
  режиме ~5 % одного ядра. Измерения — в `NOTES.md` (фаза 7).

## Проверки

В `tests\` — самомодержательные проверки (каждая возвращает 0 при успехе):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-frame-render.ps1    # 7.1: кадр на 110×32 и 80×24
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-gpu-values.ps1      # 7.3: значения против nvidia-smi
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-resource-usage.ps1  # 7.4: CPU/память за 60 с
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-exit-cleanup.ps1    # 7.5: состояние терминала после q
```

## Лицензия и источник

Портировано на PowerShell с утилиты `hwmon` из Strata — её Python-исходники лежат в
`hwmon\` и распространяются по лицензии MIT (текст лицензии: `hwmon/LICENSE-Strata-MIT`).
