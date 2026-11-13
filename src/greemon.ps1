# greemon — терминальный монитор железа (GPU, CPU, RAM, диск) в стиле Overview из Strata.
# Фаза 1 (каркас): параметры команды и справка. Сбор данных и отрисовка — следующие фазы (см. roadmap.md).
# Целевая оболочка: Windows PowerShell 5.1.

param(
    # Индекс карты в нумерации NVML (как нумерует nvidia-smi) / NVML index of the card (as nvidia-smi numbers them)
    [int]$Gpu = 0,

    # Период обновления, секунды / Refresh interval, seconds
    [double]$Interval = 1,

    # Текст на месте имени модели / Text shown where the model name is
    [string]$Label = 'hardware monitor',

    # Тема / Theme
    [ValidateSet('auto', 'dark', 'light')]
    [string]$Theme = 'auto',

    # Набор глифов / Glyph set
    [ValidateSet('auto', 'unicode', 'solid', 'ascii')]
    [string]$Glyphs = 'auto',

    # URL сервера Strata для LLM-панелей (необязателен) / Strata server URL for the LLM panels (optional)
    [string]$Url,

    # Ключ API (иначе переменная окружения STRATA_API_KEY) / API key (otherwise STRATA_API_KEY)
    [string]$ApiKey,

    # Один кадр в поток вывода и выход / Print one frame to stdout and exit
    [switch]$Once,

    # Синтетические данные без железа / Synthetic data without hardware
    [switch]$Mock,

    # Эта справка / This help
    [switch]$Help
)

function Show-Help {
    $help = @'

greemon — терминальный монитор железа (GPU, CPU, RAM, диск) в стиле Overview из Strata.
greemon — terminal hardware monitor (GPU, CPU, RAM, disk), Strata Overview style.

Использование / Usage:
  greemon [-Gpu <index>] [-Interval <sec>] [-Label <text>] [-Theme auto|dark|light]
          [-Glyphs auto|unicode|solid|ascii] [-Url <url>] [-ApiKey <key>] [-Once] [-Mock] [-Help]

Параметры / Parameters:
  -Gpu <index>   Индекс карты NVML (нумерация nvidia-smi); по умолчанию 0. / NVML card index (as nvidia-smi numbers them); default 0.
  -Interval <s>  Период обновления, с; по умолчанию 1. / Refresh interval, seconds; default 1.
  -Label <text>  Текст на месте имени модели; по умолчанию 'hardware monitor'. / Text shown as the model name; default 'hardware monitor'.
  -Theme         Тема: auto, dark, light. / Theme: auto, dark, light.
  -Glyphs        Глифы: auto, unicode, solid, ascii. / Glyphs: auto, unicode, solid, ascii.
  -Url <url>     Сервер Strata для LLM-панелей (необязателен). / Strata server for the LLM panels (optional).
  -ApiKey <key>  Ключ API; иначе переменная STRATA_API_KEY. / API key; otherwise STRATA_API_KEY.
  -Once          Один кадр в поток вывода и выход. / Print one frame to stdout and exit.
  -Mock          Синтетические данные без железа. / Synthetic data without hardware.
  -Help          Эта справка. / This help.

Клавиши / Keys:
  1-6     вкладки / views          /     фильтр / filter
  Space   заморозка / freeze       r     обновить / refresh
  t       тема / theme             ?     справка / help
  q       выход / quit
'@
    Write-Output $help
}

if ($Help) {
    Show-Help
    exit 0
}

# Фаза 1: каркас. Интерактивный монитор будет реализован в следующих фазах.
Write-Output 'greemon: каркас фазы 1 — сбор данных и отрисовка появятся в следующих фазах (см. roadmap.md). Справка: greemon -Help'
exit 0
