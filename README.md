# greemon

Терминальный монитор железа (GPU, CPU, RAM, диск) в стиле Overview из Strata. Чистый PowerShell: без Python, без прав администратора, без внешних зависимостей. Работает в Windows PowerShell 5.1 и PowerShell 7+.

## Установка

```powershell
git clone <url-репозитория>
cd greemon
powershell -File install.ps1
```

Установщик копирует файлы в `%LOCALAPPDATA%\greemon` и добавляет её в пользовательский `PATH`. Откройте новое окно терминала — команда `greemon` будет доступна из любой папки в cmd, Windows PowerShell и pwsh.

## Запуск

```
greemon
```

Полезные варианты:

```
greemon -Help     справка по параметрам и клавишам
greemon -Mock     синтетические данные (без GPU)
greemon -Once     один кадр в поток вывода
```

Клавиши: `q` — выход, `Space` — пауза, `r` — обновить, `t` — тема, `1-6` — вкладки.

## Удаление

```powershell
powershell -File uninstall.ps1
```

## Ограничения

- Показывается только вкладка Overview; LLM-панели (Model state, Recent requests) пусты без параметра `-Url`.
- Без NVIDIA-карты плитки GPU показывают `--`, программа продолжает работать.

## Лицензия и источник

Портировано с утилиты `hwmon` (Strata), код которой распространяется по лицензии MIT.
