# greemon — терминальный монитор железа (GPU, CPU, RAM, диск) в стиле Overview из Strata.
# Фаза 1 (каркас): параметры команды и справка. Фаза 2: сбор данных о железе.
# Отрисовка и интерактивный цикл — следующие фазы (см. roadmap.md).
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

# ============================================================================
# Фаза 2. Сбор данных о железе (см. roadmap.md).
#
# Имена функций NVML, структуры и единицы — из hwmon\serve\telemetry.py
# (классы _Nvml, _CpuRamFallback, функция _disk). Единицы — те, что ждёт
# overview.build() (hwmon\strata_cli\overview.py):
#   VRAM — в байтах (build сам делит на GiB); мощность — в ваттах (NVML даёт
#   милливаты, делим на 1000); PCIe RX/TX — в МБ/с (NVML даёт КБ/с);
#   температура — °C; загрузка GPU/CPU — в %; диск — в МБ/с.
# Недоступное значение — $null, а не 0 (как None в референсе).
# ============================================================================

# Длина истории на серию — константа HISTORY в hwmon\serve\telemetry.py.
$HISTORY = 60

# Серии спарклайнов: набор из _loop референса без LLM-серий tok_s и
# prefill_tok_s_mean — они появятся с фазами LLM-панелей (фаза 6).
$HISTORY_SERIES = @(
    'gpu_util', 'gpu_mem_used', 'gpu_temp', 'gpu_power', 'gpu_pcie_rx_mb',
    'cpu', 'ram_used', 'disk_read_mb'
)

# Ключи показаний GPU (как ключи out в _Nvml.read) плюс name.
$GPU_EMPTY_KEYS = @('name', 'util', 'mem_used', 'mem_total', 'temp', 'power', 'power_limit',
    'pcie_gen', 'pcie_gen_max', 'pcie_width', 'pcie_width_max', 'pcie_rx_mb', 'pcie_tx_mb')

# --- 2.1/2.4/2.5: P/Invoke. Код только на C# 5 (ограничение roadmap). ---
if (-not ('GreemonNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// Объявления P/Invoke для greemon. Имена и поля — из hwmon/serve/telemetry.py
// (классы _Nvml и _CpuRamFallback). Только C# 5: без интерполяции и ?.
public static class GreemonNative
{
    // _Nvml.Util
    [StructLayout(LayoutKind.Sequential)]
    public struct NvmlUtilization
    {
        public uint gpu;
        public uint memory;
    }

    // _Nvml.Mem
    [StructLayout(LayoutKind.Sequential)]
    public struct NvmlMemory
    {
        public ulong total;
        public ulong free;
        public ulong used;
    }

    // MS из _CpuRamFallback.ram (ветка Windows)
    [StructLayout(LayoutKind.Sequential)]
    public struct MemoryStatusEx
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    // ---- kernel32 ----
    // _CpuRamFallback._times (ветка Windows)
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemTimes(out ulong idleTime, out ulong kernelTime, out ulong userTime);

    // _CpuRamFallback.ram (ветка Windows)
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx lpBuffer);

    // Предзагрузка nvml.dll по путям референса, чтобы не звать P/Invoke без
    // библиотеки (иначе DllNotFoundException при каждом вызове).
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryW(string lpFileName);

    // ---- nvml.dll: имена и порядок аргументов — из _Nvml ----
    [DllImport("nvml.dll")] public static extern int nvmlInit();
    [DllImport("nvml.dll")] public static extern int nvmlInit_v2();
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetCount(out uint count);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetCount_v2(out uint count);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetHandleByIndex(uint index, out IntPtr device);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetHandleByIndex_v2(uint index, out IntPtr device);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetName(IntPtr device, byte[] name, uint length);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetUtilizationRates(IntPtr device, out NvmlUtilization utilization);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetMemoryInfo(IntPtr device, out NvmlMemory memory);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetTemperature(IntPtr device, uint sensorType, out uint temp);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetPowerUsage(IntPtr device, out uint powerMilliWatts);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetEnforcedPowerLimit(IntPtr device, out uint limitMilliWatts);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetCurrPcieLinkGeneration(IntPtr device, out uint gen);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetMaxPcieLinkGeneration(IntPtr device, out uint gen);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetCurrPcieLinkWidth(IntPtr device, out uint width);
    // Нет в референсе; nvmlDeviceGetMaxPcieLinkWidth по документации NVML (нужно roadmap 2.2).
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetMaxPcieLinkWidth(IntPtr device, out uint width);
    [DllImport("nvml.dll")] public static extern int nvmlDeviceGetPcieThroughput(IntPtr device, uint counter, out uint valueKbPerSec);

    // ---- 3.1: режим консоли (включить ENABLE_VIRTUAL_TERMINAL_PROCESSING) ----
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleOutput, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleOutput, uint dwMode);
}
'@
}

# ============================================================================
# Фаза 3. Отрисовка Overview (см. roadmap.md).
#
# Макет, тексты и форматы — из hwmon\strata_cli\overview.py (build/render),
# вкладки — из nav.py, выбор глифов — из monitor.py (choose_glyphs), старая
# консоль — из consoleinfo.py. Ограничения roadmap: Windows PowerShell 5.1,
# ESC = [char]27, без тернарного оператора и ?..
# ============================================================================

$ESC = [char]27

# --- 3.1: ANSI/VT. Включить ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x0004) для
# stdout, если он в консоли и обработка VT ещё не включена; кодировку вывода
# поставить UTF-8 без BOM. Оба прежних значения восстановить при выходе. ---

$script:VtStdOut = [IntPtr]::Zero
$script:VtPrevMode = $null          # прежнее значение флага консоли (для восстановления)
$script:PrevOutputEncoding = $null  # прежняя [Console]::OutputEncoding

function Enable-GreemonConsole {
    # Возвращает $true, если VT-последовательности в stdout будут обрабатываться.
    try {
        $script:VtStdOut = [GreemonNative]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = [uint32]0
        # Не консоль (вывод перенаправлен) или GetConsoleMode недоступен → false;
        # при перенаправлении VT пишет escape-последовательности в поток как есть.
        if ($script:VtStdOut -eq [IntPtr]::Zero) { return $false }
        if (-not [GreemonNative]::GetConsoleMode($script:VtStdOut, [ref]$mode)) { return $false }
        $script:VtPrevMode = $mode
        if (($mode -band 0x0004) -eq 0) {
            return [GreemonNative]::SetConsoleMode($script:VtStdOut, ($mode -bor 0x0004))
        }
        return $true
    } catch { return $false }
}

function Restore-GreemonConsole {
    # 3.1: вернуть прежний режим консоли и прежнюю кодировку вывода.
    if ($null -ne $script:VtPrevMode) {
        try { $null = [GreemonNative]::SetConsoleMode($script:VtStdOut, $script:VtPrevMode) } catch { }
        $script:VtPrevMode = $null
    }
    if ($null -ne $script:PrevOutputEncoding) {
        try { [Console]::OutputEncoding = $script:PrevOutputEncoding } catch { }
        $script:PrevOutputEncoding = $null
    }
}

function Set-GreemonOutputEncoding {
    # UTF-8 без BOM — чтобы псевдографика дорисовывалась; прежнее значение помним.
    try {
        $script:PrevOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = (New-Object System.Text.UTF8Encoding($false))
        return $true
    } catch { return $false }   # вывод перенаправлен/без ручки — пишем как есть
}

# --- 3.2: цвета из overview.py truecolor-последовательностями; NO_COLOR — без
# цвета; в solid-режиме — 16 палитра conhost (SOLID_* в overview.py). ---

# ACCENT/BLUE/AMBER/RED/GREY из overview.py; акцент светлой темы #0c8a60 (render()).
# yellow — обычный SGR-33 (в rich «bold yellow» у маркера), не truecolor.
$GREEMON_RGB = @{
    accent  = '52;211;153'; blue = '90;169;255'; amber = '245;197;107'
    red     = '242;139;130'; grey = '89;99;107'
    accent_light = '12;138;96'
}
$GREEMON_SGR16 = @{
    accent = '92'; blue = '94'; amber = '33'; red = '31'; grey = '90'; track = '90'
}

function Get-GreemonSgr {
    # Стиль-токены ('bold dim accent' ...) → параметр SGR ('1;38;2;...') или ''.
    param([string]$Style)
    if (-not $Style) { return '' }
    $bold = $false
    $color = ''
    foreach ($tok in ($Style -split ' ')) {
        if ($tok -eq 'bold') { $bold = $true; continue }
        if ($script:ColorMode -eq 'none') { continue }
        if ($tok -eq 'yellow') { $color = '33'; continue }
        if ($tok -eq 'dim' -or $tok -eq 'grey' -or $tok -eq 'track') {
            if ($script:ColorMode -eq 'solid') { $color = $GREEMON_SGR16['grey'] }
            else { $color = ('38;2;' + $GREEMON_RGB['grey']) }
            continue
        }
        if ($script:ColorMode -eq 'solid') {
            if ($GREEMON_SGR16.ContainsKey($tok)) { $color = $GREEMON_SGR16[$tok] }
        } elseif ($tok -eq 'accent' -and $script:ThemeResolved -eq 'light') {
            $color = ('38;2;' + $GREEMON_RGB['accent_light'])
        } elseif ($GREEMON_RGB.ContainsKey($tok)) {
            $color = ('38;2;' + $GREEMON_RGB[$tok])
        }
    }
    $parts = @()
    if ($bold) { $parts += '1' }
    if ($color) { $parts += $color }
    return ($parts -join ';')
}

# --- 3.3: три набора глифов. Выбор — как choose_glyphs() из monitor.py;
# определение старой консоли — как legacy_console() из consoleinfo.py,
# упрощённо: без переключения шрифта на Cascadia Mono (см. NOTES.md), поэтому
# старая консоль всегда получает 'solid'. ---

function Test-GreemonLegacyConsole {
    param([string]$Forced)
    if ($Forced -eq 'ascii' -or $Forced -eq 'solid') { return $true }    # как forced в legacy_console()
    if ($Forced -eq 'unicode') { return $false }
    if ($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:ConEmuANSI -or $env:ANSICON) { return $false }
    if ($env:TERM -and $env:TERM -match '^(xterm|screen|tmux|vt)') { return $false }
    return $true    # conhost Windows PowerShell/cmd
}

function Initialize-GreemonRenderOptions {
    $legacy = Test-GreemonLegacyConsole -Forced $Glyphs
    $script:LegacyConsole = $legacy
    if ($Glyphs -ne 'auto') { $script:GlyphSet = $Glyphs }
    elseif ($legacy) { $script:GlyphSet = 'solid' }     # без Cascadia-проверки — solid (NOTES.md)
    else { $script:GlyphSet = 'unicode' }
    # NO_COLOR как в monitor.py: os.environ.get('NO_COLOR') is not None.
    $noColor = ($null -ne [Environment]::GetEnvironmentVariable('NO_COLOR'))
    if ($noColor) { $script:ColorMode = 'none' }
    elseif ($script:GlyphSet -eq 'solid') { $script:ColorMode = 'solid' }
    else { $script:ColorMode = 'truecolor' }
    # auto → terminal у референса; в ANSI без фона terminal рисуется как dark
    # (акцент остаётся ACCENT — в render() light меняет только его).
    if ($Theme -eq 'light') { $script:ThemeResolved = 'light' } else { $script:ThemeResolved = 'dark' }
}

# --- Стиль-сегменты: строка = массив @{t = текст; s = стиль}. Цвет подставляется
# только при выводе, ширина считается по plain-тексту (3.4: без широких
# символов и вне BMP — все глифы референса в BMP и одноширинные). ---

function New-GreemonSeg {
    param([string]$Text, [string]$Style = '')
    return @{ t = $Text; s = $Style }
}

function Get-GreemonPlain {
    param($Segs)
    if ($null -eq $Segs -or $Segs.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($g in $Segs) { $null = $sb.Append($g.t) }
    return $sb.ToString()
}

function Format-GreemonSegs {
    param($Segs)
    # Сегменты → строка с ANSI; без цвета (ColorMode none) — просто текст.
    $sb = New-Object System.Text.StringBuilder
    foreach ($g in $Segs) {
        $sgr = Get-GreemonSgr $g.s
        if ($sgr) {
            $null = $sb.Append($ESC).Append('[').Append($sgr).Append('m')
            $null = $sb.Append($g.t)
            $null = $sb.Append($ESC).Append('[0m')
        } else {
            $null = $sb.Append($g.t)
        }
    }
    return $sb.ToString()
}

function Cut-GreemonSegs {
    # Обрезка строки по ширине в ячейках (overflow="crop" в референсе).
    param($Segs, [int]$Width)
    $out = @()
    $left = $Width
    foreach ($g in $Segs) {
        if ($left -le 0) { break }
        if ($g.t.Length -le $left) { $out += $g } else { $out += (New-GreemonSeg $g.t.Substring(0, $left) $g.s) }
        $left -= $g.t.Length
    }
    return , $out
}

function Pad-GreemonSegs {
    # Дополнение строки пробелами до ширины в ячейках.
    param($Segs, [int]$Width)
    $len = (Get-GreemonPlain $Segs).Length
    if ($len -lt $Width) { return , ($Segs + (New-GreemonSeg (' ' * ($Width - $len)))) }
    return , $Segs
}

# --- 3.4: форматы чисел из overview.py (fmt / tokens / k). ---

function Format-GreemonNum {
    # fmt(): None → '--'; иначе f"{v:,.{digits}f}{unit}" (разделитель тысяч,
    # инвариантная культура — как f-строка в Python).
    param($V, [int]$Digits = 0, [string]$Unit = '')
    if ($null -eq $V) { return '--' }
    $fmt = '#,##0'
    if ($Digits -gt 0) { $fmt += '.' + ('0' * $Digits) }
    return ([double]$V).ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture) + $Unit
}

function Format-GreemonTokens {
    param($V)
    return Format-GreemonNum $V 0
}

function Format-GreemonK {
    # k(): None → '--'; >= 1024 → «NNNK», иначе целое.
    param($V)
    if ($null -eq $V) { return '--' }
    $v = [double]$V
    if ($v -ge 1024) { return ([math]::Round($v / 1024.0)).ToString('#,##0', [System.Globalization.CultureInfo]::InvariantCulture) + 'K' }
    return ([math]::Round($v)).ToString('#,##0', [System.Globalization.CultureInfo]::InvariantCulture)
}

# --- 3.4: спарклайн spark() из overview.py: один ряд блочных символов по
# последним Width значениям; $null-разрывы → пробел; solid-вид — ▄ (низкая
# четверть — тонкий track) / ▄ / █. Возвращает сегменты (в solid у ячеек свои
# стили: track — bright_black). ---

function Format-GreemonSpark {
    param([object[]]$Values, [int]$Width, [string]$Style = 'accent', $Lo = $null, $Hi = $null)
    $vals = @($Values)
    if ($vals.Count -gt $Width) { $vals = $vals[($vals.Count - $Width)..($vals.Count - 1)] }
    $present = @($vals | Where-Object { $null -ne $_ })
    $pad = ' ' * ($Width - $vals.Count)
    if ($present.Count -eq 0) { return , @(New-GreemonSeg (' ' * $Width)) }
    $low = if ($null -ne $Lo) { [double]$Lo } else { [double](($present | Measure-Object -Minimum).Minimum) }
    $high = if ($null -ne $Hi) { [double]$Hi } else { [double](($present | Measure-Object -Maximum).Maximum) }
    if ($high - $low -lt 1e-9) { $high = $low + 1.0 }
    $ramp = if ($script:GlyphSet -eq 'ascii') { '.:-=+*#@' } else { [string][char]0x2581 + [char]0x2582 + [char]0x2583 + [char]0x2584 + [char]0x2585 + [char]0x2586 + [char]0x2587 + [char]0x2588 }
    $segs = @()
    if ($pad) { $segs += New-GreemonSeg $pad }
    $buf = ''; $bufStyle = $null
    foreach ($v in $vals) {
        if ($null -eq $v) { $ch = ' '; $st = '' }
        elseif ($script:GlyphSet -eq 'solid') {
            # solid_spark(): f<0.25 → тонкий ▄ (track), f<0.6 → ▄, иначе █
            $f = ([double]$v - $low) / ($high - $low)
            if ($f -lt 0.25) { $ch = [string][char]0x2584; $st = 'track' }
            elseif ($f -lt 0.6) { $ch = [string][char]0x2584 }
            else { $ch = [string][char]0x2588 }
        } else {
            $i = [int][math]::Floor((([double]$v - $low) / ($high - $low)) * 7.999)
            if ($i -lt 0) { $i = 0 } elseif ($i -gt 7) { $i = 7 }
            $ch = $ramp[$i].ToString(); $st = ''
        }
        if ($null -eq $bufStyle) { $bufStyle = $st }
        elseif ($st -ne $bufStyle) { if ($buf -ne '') { $segs += New-GreemonSeg $buf $bufStyle }; $buf = ''; $bufStyle = $st }
        $buf += $ch
    }
    if ($buf -ne '') { $segs += New-GreemonSeg $buf $bufStyle }
    if ($script:GlyphSet -ne 'solid') {
        # у unicode/ascii спарклайн красится акцентом плитки целиком (в solid
        # свои стили ячеек уже расставлены; track остаётся track)
        $out = @()
        foreach ($g in $segs) { if (-not $g.s) { $out += (New-GreemonSeg $g.t $Style) } else { $out += $g } }
        return , $out
    }
    return , $segs
}

# --- 3.4: горизонтальная полоса bar() из overview.py. None → пустая дорожка
# (unicode: ░, ascii: '.', solid: ▄ track). ---

function Format-GreemonBar {
    param($Frac, [int]$Width, [string]$Style = 'accent')
    if ($script:GlyphSet -eq 'solid') {
        $n = 0
        if ($null -ne $Frac) {
            $f = [double]$Frac; if ($f -lt 0) { $f = 0 }; if ($f -gt 1) { $f = 1 }
            $n = [int][math]::Round($f * $Width)
        }
        $segs = @()
        if ($n -gt 0) { $segs += New-GreemonSeg (([string][char]0x2588) * $n) $Style }
        if ($Width - $n -gt 0) { $segs += New-GreemonSeg (([string][char]0x2584) * ($Width - $n)) 'track' }
        return , $segs
    }
    $full = '█'; $hollow = '░'
    if ($script:GlyphSet -eq 'ascii') { $full = '#'; $hollow = '.' }
    if ($null -eq $Frac) { return , @(New-GreemonSeg ($hollow * $Width) 'dim') }
    $f = [double]$Frac; if ($f -lt 0) { $f = 0 }; if ($f -gt 1) { $f = 1 }
    $n = [int][math]::Round($f * $Width)
    $segs = @()
    if ($n -gt 0) { $segs += New-GreemonSeg ([string]$full * $n) $Style }
    if ($Width - $n -gt 0) { $segs += New-GreemonSeg ([string]$hollow * ($Width - $n)) 'dim' }
    return , $segs
}

# --- 3.4: рамка плитки — Panel из _tile(): скруглённая для unicode
# (box.ROUNDED), квадратная для ascii/solid (box.SQUARE); заголовок слева
# внутри верхней границы, padding (0,1), строки: big (bold), sub (dim),
# спарклайн (акцент). ---

function New-GreemonTile {
    param([string]$Title, [string]$Big, [string]$Sub, [object[]]$Spark, [int]$Width, [string]$Accent = 'accent')
    $rounded = $script:GlyphSet -eq 'unicode'
    $tl = if ($rounded) { [char]0x256D } else { [char]0x250C }     # ╭ ┌
    $tr = if ($rounded) { [char]0x256E } else { [char]0x2510 }     # ╮ ┐
    $bl = if ($rounded) { [char]0x2570 } else { [char]0x2514 }     # ╰ └
    $br = if ($rounded) { [char]0x256F } else { [char]0x2518 }     # ╯ ┘
    $h = [string][char]0x2500                                     # ─
    $v = [string][char]0x2502                                     # │
    $inner = $Width - 4                                           # padding (0,1) + границы
    # верхняя граница с заголовком: ╭─ Title ─…─╮ (Panel title_align=left)
    $t = $Title
    if ($t.Length -gt $inner) { $t = $t.Substring(0, $inner) }
    $rest = $Width - 5 - $t.Length
    if ($rest -lt 1) { $rest = 1 }
    $top = @((New-GreemonSeg ([string]$tl) 'dim'), (New-GreemonSeg ($h + ' ' + $t + ' ') 'dim'), (New-GreemonSeg ($h * $rest) 'dim'), (New-GreemonSeg ([string]$tr) 'dim'))
    $bodyRow = {
        param($ContentSegs, [string]$FallbackStyle)
        $cs = @()
        foreach ($g in $ContentSegs) { if (-not $g.s) { $cs += (New-GreemonSeg $g.t $FallbackStyle) } else { $cs += $g } }
        $cs = Pad-GreemonSegs (Cut-GreemonSegs $cs $inner) $inner
        return , (@(New-GreemonSeg ([string]$v + ' ') 'dim') + $cs + @(New-GreemonSeg (' ' + [string]$v) 'dim'))
    }
    $rowBig = & $bodyRow @(New-GreemonSeg $Big 'bold') ''
    $rowSub = & $bodyRow @(New-GreemonSeg $Sub 'dim') ''
    $rowSpark = & $bodyRow $Spark $Accent
    $bottom = @((New-GreemonSeg ([string]$bl) 'dim'), (New-GreemonSeg ($h * ($Width - 2)) 'dim'), (New-GreemonSeg ([string]$br) 'dim'))
    $rows = @()
    $rows += , $top
    $rows += , $rowBig
    $rows += , $rowSub
    $rows += , $rowSpark
    $rows += , $bottom
    return , $rows
}

# --- 3.6: панель вкладок — nav.py (NAMES/SHORT, layout/plain/styled). ---

$GREEMON_TABS = @('Overview', 'Serving', 'Requests', 'Engine', 'Hardware', 'Logs')
$GREEMON_TABS_SHORT = @('Over', 'Serve', 'Reqs', 'Engine', 'GPU', 'Logs')

function Get-GreemonTabsLayout {
    # nav.layout(current, width, connect=False) для шести вкладок.
    param([int]$Current, [int]$Width)
    $n = $GREEMON_TABS.Count
    if ($Current -lt 0) { $Current = 0 } elseif ($Current -gt $n - 1) { $Current = $n - 1 }
    foreach ($pair in @(@($GREEMON_TABS, '  '), @($GREEMON_TABS_SHORT, ' '))) {
        $labels = $pair[0]; $sep = $pair[1]
        $items = @(); $w = 0
        for ($i = 0; $i -lt $n; $i++) {
            $numTxt = [string]($i + 1)
            $items += $(if ($i -eq $Current) { '[' + $numTxt + ' ' + $labels[$i] + ']' } else { $numTxt + ' ' + $labels[$i] })
            $w += $items[$i].Length
        }
        $w += $sep.Length * ($n - 1)
        if ($w -le $Width) {
            $pieces = @(); for ($i = 0; $i -lt $n; $i++) { $pieces += , @($items[$i], ($i -eq $Current)) }
            return @{ pieces = $pieces; sep = $sep; left = $false; right = $false }
        }
    }
    # не влезает даже список коротких — только вкладки вокруг выбранной (nav.layout)
    $items = @()
    for ($i = 0; $i -lt $n; $i++) { $numTxt = [string]($i + 1); $items += $(if ($i -eq $Current) { '[' + $numTxt + ' ' + $GREEMON_TABS_SHORT[$i] + ']' } else { $numTxt + ' ' + $GREEMON_TABS_SHORT[$i] }) }
    $lo = $Current; $hi = $Current
    while ($true) {
        $grew = $false
        foreach ($pair in @(@(($hi + 1), $true), @(($lo - 1), $false))) {
            $nxt = $pair[0]; $isHi = $pair[1]
            if ($nxt -lt 0 -or $nxt -gt $n - 1) { continue }
            $newLo = $lo; $newHi = $hi
            if ($isHi) { $newHi = $nxt } else { $newLo = $nxt }
            $w = 0
            for ($i = $newLo; $i -le $newHi; $i++) { $w += $items[$i].Length }
            $w += 1 * ($newHi - $newLo)                       # sep=' '
            if ($newLo -gt 0) { $w += 2 }
            if ($newHi -lt $n - 1) { $w += 2 }
            if ($w -le $Width) { $lo = $newLo; $hi = $newHi; $grew = $true }
        }
        if (-not $grew) { break }
    }
    $pieces = @(); for ($i = $lo; $i -le $hi; $i++) { $pieces += , @($items[$i], ($i -eq $Current)) }
    return @{ pieces = $pieces; sep = ' '; left = ($lo -gt 0); right = ($hi -lt $n - 1) }
}

function Format-GreemonTabsSegs {
    # nav.styled: выбранная вкладка — bold + акцент, стрелки — dim.
    param([int]$Current, [int]$Width)
    $tabs = Get-GreemonTabsLayout $Current $Width
    $segs = @()
    if ($tabs.left) { $segs += New-GreemonSeg '< ' 'dim' }
    for ($i = 0; $i -lt $tabs.pieces.Count; $i++) {
        if ($i) { $segs += New-GreemonSeg $tabs.sep }
        $sel = $tabs.pieces[$i][1]
        $style = if ($sel) { 'bold accent' } else { '' }
        $segs += New-GreemonSeg $tabs.pieces[$i][0] $style
    }
    if ($tabs.right) { $segs += New-GreemonSeg ' >' 'dim' }
    return , $segs
}

# --- 3.8: short_gpu() из overview.py — имя карты без префиксов производителя. ---

function Get-GreemonShortGpu {
    param($Name)
    if (-not $Name) { return 'graphics card' }
    foreach ($p in @('NVIDIA GeForce ', 'NVIDIA ', 'AMD Radeon ', 'AMD ', 'Intel(R) ', 'Intel ')) {
        if ($Name.StartsWith($p)) { $Name = $Name.Substring($p.Length) }
    }
    return $Name
}

# --- Модель отрисовки для автономного режима — порт build() из overview.py на
# локальных данных (hwmon.py feeds the same shapes from its fake /metrics:
# live.state=idle, engine.model=label, requests=[], totals={}). Скорость:
# run_average_speed по пустым totals → None → ветка «last request» (как в
# референсе автономного hwmon). LLM-числа — $null, плитки показывают '--'. ---

function New-GreemonRenderModel {
    $s = $script:LastSample
    $hist = $script:Hist
    $st = $script:Static
    $GIB = [math]::Pow(2, 30)
    $toGiB = { param($x) if ($null -eq $x) { $null } else { [double]$x / $GIB } }
    $histGiB = @(foreach ($x in @($hist['gpu_mem_used'].ToArray())) { if ($null -eq $x) { $null } else { [double]$x / $GIB } })
    return @{
        state        = 'Idle'                       # 3.7: в автономном режиме всегда Idle
        phase_text   = 'Waiting for a request'      # phase_text['Idle'] в build()
        queued       = 0
        progress     = @{ done = $null; total = $null }
        context      = @{ used = $null; max = $null }
        speed        = @{ value = $null; note = 'last request' }   # ветка Idle в build() при пустых totals/requests
        gpu = @{
            util       = $s['gpu_util'];   util_hist  = @($hist['gpu_util'].ToArray())
            vram_used  = & $toGiB $s['gpu_mem_used']; vram_total = & $toGiB $(if ($null -ne $s['gpu_mem_total']) { $s['gpu_mem_total'] } else { $st['gpu_vram_total'] })
            vram_hist  = $histGiB
            temp       = $s['gpu_temp'];   temp_hist  = @($hist['gpu_temp'].ToArray())
            power      = $s['gpu_power'];  power_limit = $s['gpu_power_limit']; power_hist = @($hist['gpu_power'].ToArray())
            pcie_rx    = $s['gpu_pcie_rx_mb']; pcie_hist = @($hist['gpu_pcie_rx_mb'].ToArray())
            pcie_gen   = $(if ($null -ne $s['gpu_pcie_gen']) { $s['gpu_pcie_gen'] } else { $s['gpu_pcie_gen_max'] })
            pcie_width = $s['gpu_pcie_width']
            name       = $st['gpu_name']; count = $st['gpu_count']; cards = @()
        }
        cpu  = @{ load = $s['cpu']; hist = @($hist['cpu'].ToArray()); cores = $st['cpu_cores']; threads = $st['cpu_threads']; sockets = $null }
        disk = @{ read = $s['disk_read_mb']; write = $s['disk_write_mb']; hist = @($hist['disk_read_mb'].ToArray()) }
        ram  = @{ used = (& $toGiB $s['ram_used']); total = (& $toGiB $s['ram_total']) }
        experts = @{ slots = $null; total = $null; gb = $null }        # 3.9: в автономном режиме '--'
        recent  = @()                                                  # 3.10: данных нет до фазы 6
        sampled_at = $(if ($null -ne $s['time']) { [double]$s['time'] } else { $null })
    }
}

# --- 3.10: таблица Recent requests — заголовки и строки, как в render():
# TIME STATUS PROMPT REUSED OUTPUT TOK/S DURATION; пусто → «No requests yet». ---

function Format-GreemonRequestsTableLines {
    param($Recent, [int]$ShowRows)
    $head = @((New-GreemonSeg 'TIME' 'dim'), (New-GreemonSeg '  '), (New-GreemonSeg 'STATUS' 'dim'), (New-GreemonSeg '  '),
        (New-GreemonSeg 'PROMPT' 'dim'), (New-GreemonSeg '  '), (New-GreemonSeg 'REUSED' 'dim'), (New-GreemonSeg '  '),
        (New-GreemonSeg 'OUTPUT' 'dim'), (New-GreemonSeg '  '), (New-GreemonSeg 'TOK/S' 'dim'), (New-GreemonSeg '  '),
        (New-GreemonSeg 'DURATION' 'dim'))
    $lines = @(, $head)
    if (@($Recent).Count -eq 0) {
        $lines += , @(New-GreemonSeg 'No requests yet')
        return , $lines
    }
    # данные запросов появятся с фазами LLM (фаза 6); форматы строк — как в render()
    foreach ($r in @($Recent | Select-Object -First $ShowRows)) {
        $stamp = if ($null -ne $r['time']) { [DateTimeOffset]::FromUnixTimeSeconds([long]$r['time']).LocalDateTime.ToString('HH:mm:ss') } else { '--' }
        $stStyle = switch ($r['state']) { 'Done' { 'accent' } 'Error' { 'red' } default { 'amber' } }
        $cells = @(
            (, @(New-GreemonSeg $stamp)),
            (, @(New-GreemonSeg $r['state'] $stStyle)),
            (, @(New-GreemonSeg (Format-GreemonTokens $r['prompt']))),
            (, @(New-GreemonSeg (Format-GreemonTokens $r['reused']))),
            (, @(New-GreemonSeg (Format-GreemonTokens $r['output']))),
            (, @(New-GreemonSeg (Format-GreemonNum $r['tps'] 1))),
            (, @(New-GreemonSeg (Format-GreemonNum $r['duration'] 1 ' s')))
        )
        $line = @()
        for ($i = 0; $i -lt $cells.Count; $i++) { if ($i) { $line += New-GreemonSeg '  ' }; $line += $cells[$i] }
        $lines += , $line
    }
    return , $lines
}

# --- 3.5–3.12: кадр. Возвращает массив строк-сегментов (каждая строка —
# массив @{t;s}) или одну строку-заглушку, если окно меньше минимума 78×23
# (условие size.width >= 78 and size.height >= 23 в monitor.py). ---

function Format-GreemonFrame {
    param($Model, [int]$WindowWidth, [int]$WindowHeight, [bool]$Frozen = $false, [int]$View = 0)

    # 3.12: минимум для Overview — 78×23, иначе одна строка.
    if ($WindowWidth -lt 78 -or $WindowHeight -lt 23) {
        return , @(, @(New-GreemonSeg 'окно слишком маленькое, нужно 78×23'))
    }
    # ширина контента — как в monitor.py: width - margin (3 в классической
    # консоли, иначе 2), далее в render() всё ограничено min(width, 110).
    $margin = 2
    if ($script:LegacyConsole) { $margin = 3 }
    $width = $WindowWidth - $margin
    if ($width -lt 30) { $width = 30 }
    if ($script:LegacyConsole -and $width -gt 100) { $width = 100 }
    $cw = $width
    if ($cw -gt 110) { $cw = 110 }

    $asciiMode = $script:GlyphSet -eq 'ascii'
    $dot = '-'; $bullet = '*'; $ruleCh = '-'                  # ascii-вид — чистый ASCII
    if (-not $asciiMode) {
        $dot = [string][char]0x00B7                            # ·
        $ruleCh = [string][char]0x2500                        # ─
        $bullet = if ($script:GlyphSet -eq 'solid') { [string][char]0x2022 } else { [string][char]0x25CF }   # • / ●
    }

    $state = $Model['state']
    # state_color из render(): Idle → без цвета (у нас 'dim' для правого текста)
    $stateColor = switch ($state) { 'Reading' { 'blue' } 'Generating' { 'accent' } 'Queued' { 'amber' } 'Error' { 'red' } default { '' } }

    # маркер [LIVE]/[STALE]/[FROZEN] (3.5): автономно — connected; LIVE → STALE,
    # если возраст замера больше 6 секунд (как в render()).
    $marker = 'LIVE'
    if ($Frozen) { $marker = 'FROZEN' }
    if ($null -ne $Model['sampled_at']) {
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 - $Model['sampled_at']
        if ($marker -eq 'LIVE' -and $age -gt 6) { $marker = 'STALE' }
    }

    # ---- 3.5: шапка. Вместо URL — greemon; на месте модели — -Label.
    $head = @((New-GreemonSeg 'STRATA  Overview   ' 'bold accent'), (New-GreemonSeg 'greemon   ' 'bold accent'), (New-GreemonSeg $Label 'bold'))
    $phaseTxt = $bullet + ' ' + $Model['phase_text']
    $done = $Model['progress']['done']; $total = $Model['progress']['total']
    $pct = $null
    if ($null -ne $done -and $total) { $pct = [int][math]::Round(100 * $done / $total) }
    if ($null -ne $pct -and ($state -eq 'Reading' -or $state -eq 'Generating')) { $phaseTxt += ' ' + $dot + ' ' + $pct + '%' }
    $right = @((New-GreemonSeg $phaseTxt 'dim'), (New-GreemonSeg '   '), (New-GreemonSeg ('[' + $marker + ']') 'bold accent'))
    if ($marker -ne 'LIVE') { $right = @((New-GreemonSeg $phaseTxt 'dim'), (New-GreemonSeg '   '), (New-GreemonSeg ('[' + $marker + ']') 'bold yellow')) }
    $headPlain = (Get-GreemonPlain $head); $rightPlain = (Get-GreemonPlain $right)
    $pad = $width - $headPlain.Length - $rightPlain.Length
    if ($pad -lt 2) { $pad = 2 }
    $headLine = $head + @(New-GreemonSeg (' ' * $pad)) + $right
    $headLine = Cut-GreemonSegs $headLine $width

    # ---- 3.6: вкладки и линейка
    $tabsLine = Cut-GreemonSegs (Format-GreemonTabsSegs $View $cw) $width
    $ruleLine = @(New-GreemonSeg ($ruleCh * $cw) 'dim')

    # ---- 3.11: строки клавиш и «Read only» (пункт b — без -Url убран)
    $hintLine = @(New-GreemonSeg ('1-6 views' + '   / filter   Space freeze   r refresh   t theme   ? help   q quit') 'dim')
    $msgLine = @(New-GreemonSeg 'Read only  |  q quits' 'dim')

    if ($View -ne 0) {
        # 3.6: в автономном режиме рабочая только вкладка 1
        $stub = @(New-GreemonSeg 'недоступно в автономном режиме')
        return , (@($headLine, $tabsLine, $ruleLine, @(), $stub, @()) + @($hintLine, $msgLine))
    }

    # ---- 3.7: полоса Model state — в автономном режиме всегда Idle
    $st = @(New-GreemonSeg 'Model state  ' 'bold accent')
    foreach ($n in @('Idle', 'Reading', 'Generating', 'Queued', 'Error')) {
        $txt = if ($n -eq $state) { '[' + $n + ']' } else { $n }
        $style = 'dim'
        if ($n -eq $state -and $state -ne 'Idle') { $style = $stateColor }
        elseif ($n -eq $state) { $style = 'bold' }
        $st += New-GreemonSeg ($txt + '  ') $style
    }
    $stPad = $cw - (Get-GreemonPlain $st).Length
    if ($stPad -lt 2) { $stPad = 2 }
    $stLine = Cut-GreemonSegs ($st + @(New-GreemonSeg (' ' * $stPad) 'dim')) $width
    $barW = $cw - 2
    if ($barW -lt 20) { $barW = 20 }
    $stateBarLine = Format-GreemonBar $null $barW 'accent'

    # ---- 3.8: восемь плиток 4 + 4 (тексты и форматы — из overview.py)
    $tileW = [int][math]::Floor(($cw - 3) / 4)
    if ($tileW -lt 18) { $tileW = 18 }
    $inner = $tileW - 4
    $g = $Model['gpu']; $c = $Model['cpu']; $d = $Model['disk']
    $spdStyle = 'accent'
    $spdBig = '-- tok/s'
    if ($null -ne $Model['speed']['value']) { $spdBig = (Format-GreemonNum $Model['speed']['value'] 1) + ' tok/s' }
    $loadBig = (Format-GreemonNum $g['util']) + ' %'
    $loadSub = Get-GreemonShortGpu $g['name']
    $vramBig = (Format-GreemonNum $g['vram_used'] 1) + ' / ' + (Format-GreemonNum $g['vram_total'] 0) + ' GB'
    $vramSub = 'graphics memory'
    $tempUnit = ' C'; if (-not $asciiMode) { $tempUnit = ' ' + [string][char]0x00B0 + 'C' }
    $tempBig = (Format-GreemonNum $g['temp']) + $tempUnit
    $genTxt = if ($g['pcie_gen']) { 'Gen' + [int]$g['pcie_gen'] } else { 'PCIe' }
    $link = if ($g['pcie_width']) { $genTxt + ' x' + [int]$g['pcie_width'] } else { $genTxt }
    $pcieSub = 'to GPU --'
    if ($null -ne $g['pcie_rx']) { $pcieSub = 'to GPU ' + (Format-GreemonNum $g['pcie_rx']) + ' MB/s' }
    $cpuSub = ''
    if ($c['cores'] -and $c['threads']) { $cpuSub = [string][int]$c['cores'] + ' cores ' + $dot + ' ' + [string][int]$c['threads'] + ' threads' }
    elseif ($c['threads']) { $cpuSub = [string][int]$c['threads'] + ' threads' }
    $powerBig = (Format-GreemonNum $g['power']) + ' W'
    $powerSub = if ($g['power_limit']) { 'of ' + (Format-GreemonNum $g['power_limit']) + ' W limit' } else { '' }
    $diskBig = (Format-GreemonNum $d['read'] 1) + ' MB/s'
    $diskSub = if ($null -ne $d['write']) { 'write ' + (Format-GreemonNum $d['write'] 1) + ' MB/s' } else { 'write --' }

    $t1 = @(
        (New-GreemonTile 'Speed' $spdBig $Model['speed']['note'] (Format-GreemonSpark @() $inner) $tileW),
        (New-GreemonTile 'GPU load' $loadBig $loadSub (Format-GreemonSpark $g['util_hist'] $inner 'accent' 0 100) $tileW),
        (New-GreemonTile 'VRAM' $vramBig $vramSub (Format-GreemonSpark $g['vram_hist'] $inner 'accent' 0 $g['vram_total']) $tileW),
        (New-GreemonTile 'GPU temp' $tempBig '' (Format-GreemonSpark $g['temp_hist'] $inner 'amber' 20 100) $tileW 'amber')
    )
    $t2 = @(
        (New-GreemonTile 'Power' $powerBig $powerSub (Format-GreemonSpark $g['power_hist'] $inner 'accent' 0 $null) $tileW),
        (New-GreemonTile 'PCIe' $link $pcieSub (Format-GreemonSpark $g['pcie_hist'] $inner 'accent' 0 $null) $tileW),
        (New-GreemonTile 'CPU' ((Format-GreemonNum $c['load']) + ' %') $cpuSub (Format-GreemonSpark $c['hist'] $inner 'accent' 0 100) $tileW),
        (New-GreemonTile 'Disk read' $diskBig $diskSub (Format-GreemonSpark $d['hist'] $inner 'accent' 0 $null) $tileW)
    )
    $tileLines = @()
    for ($r = 0; $r -lt 5; $r++) {
        $line = @()
        for ($i = 0; $i -lt 4; $i++) { if ($i) { $line += New-GreemonSeg '  ' }; $line += $t1[$i][$r] }
        $tileLines += , (Cut-GreemonSegs $line $cw)
    }
    for ($r = 0; $r -lt 5; $r++) {
        $line = @()
        for ($i = 0; $i -lt 4; $i++) { if ($i) { $line += New-GreemonSeg '  ' }; $line += $t2[$i][$r] }
        $tileLines += , (Cut-GreemonSegs $line $cw)
    }

    # ---- 3.9: полосы Context fill / Experts in VRAM / System RAM
    $leftW = [int][math]::Floor($cw * 2 / 5)
    if ($leftW -lt 24) { $leftW = 24 }
    $ctxU = $Model['context']['used']; $ctxM = $Model['context']['max']
    $usedFrac = $null
    if ($null -ne $ctxU -and $ctxM) { $usedFrac = $ctxU / $ctxM }
    $ctxTxt = (Format-GreemonK $ctxU) + ' / ' + (Format-GreemonK $ctxM)
    if ($null -ne $usedFrac) { $ctxTxt += '  ' + ([math]::Round($usedFrac * 100)).ToString('0', [System.Globalization.CultureInfo]::InvariantCulture) + '%' }
    $e = $Model['experts']
    $expTxt = Format-GreemonNum $e['slots']
    if ($null -ne $e['gb']) { $expTxt += ' ' + $dot + ' ' + ([double]$e['gb']).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + ' GB' }
    $ramUsed = $Model['ram']['used']; $ramTotal = $Model['ram']['total']
    $ramFrac = $null
    if ($null -ne $ramUsed -and $ramTotal) { $ramFrac = $ramUsed / $ramTotal }
    $ramTxt = (Format-GreemonNum $ramUsed 1) + ' / ' + (Format-GreemonNum $ramTotal 0) + ' GB'
    $ramBarStyle = 'accent'
    if ($null -ne $ramFrac -and $ramFrac -gt 0.9) { $ramBarStyle = 'red' }
    $leftLines = @(
        (, (@(New-GreemonSeg 'Context fill  ' 'bold accent') + @(New-GreemonSeg $ctxTxt))),
        (Format-GreemonBar $usedFrac $leftW 'accent'),
        (, (@(New-GreemonSeg 'Experts in VRAM   ') + @(New-GreemonSeg $expTxt 'dim'))),
        (Format-GreemonBar $null $leftW 'accent'),
        (, (@(New-GreemonSeg 'System RAM        ') + @(New-GreemonSeg $ramTxt 'dim'))),
        (Format-GreemonBar $ramFrac $leftW $ramBarStyle)
    )

    # ---- 3.10: Recent requests справа (show — как в render(): height - 20)
    $show = $WindowHeight - 20
    if ($show -gt 6) { $show = 6 }
    if ($show -lt 2) { $show = 2 }
    $rightLines = @()
    $rightLines += , @(New-GreemonSeg 'Recent requests' 'bold accent')
    $rightLines += (Format-GreemonRequestsTableLines $Model['recent'] $show)

    $bottomLines = @()
    $nRows = $leftLines.Count
    if ($rightLines.Count -gt $nRows) { $nRows = $rightLines.Count }
    for ($i = 0; $i -lt $nRows; $i++) {
        $l = @(); if ($i -lt $leftLines.Count) { $l = Pad-GreemonSegs $leftLines[$i] $leftW }
        $rseg = @(); if ($i -lt $rightLines.Count) { $rseg = $rightLines[$i] }
        $bottomLines += , (Cut-GreemonSegs ($l + @(New-GreemonSeg '      ') + $rseg) $width)   # padding (0,3) в grid
    }

    # ---- порядок частей — как parts в render(): head, tabs, rule, st,
    # state_bar, пусто, плитки, пусто нет (bottom сразу), bottom, пусто, hint;
    # строка сообщения — как #message у MonitorApp.
    $lines = @()
    $lines += , $headLine
    $lines += , $tabsLine
    $lines += , $ruleLine
    $lines += , $stLine
    $lines += , $stateBarLine
    $lines += , @()
    foreach ($l in $tileLines) { $lines += , $l }
    foreach ($l in $bottomLines) { $lines += , $l }
    $lines += , @()
    $lines += , $hintLine
    $lines += , $msgLine
    return , $lines
}

# Кадры в строки текста с ANSI.
function Format-GreemonFrameText {
    param($Lines)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ln in $Lines) {
        $null = $sb.Append((Format-GreemonSegs $ln))
        $null = $sb.Append("`r`n")
    }
    return $sb.ToString()
}





# --- 2.1: загрузка nvml.dll. Пути — из _Nvml: системный поиск (драйвер кладёт
# nvml.dll в System32) и ProgramFiles\NVIDIA Corporation\NVSMI\nvml.dll. ---
function Initialize-GreemonNvml {
    if ($script:NvmlLoaded) { return $true }
    $paths = @('nvml.dll')
    if ($env:ProgramFiles) {
        $paths += (Join-Path (Join-Path $env:ProgramFiles 'NVIDIA Corporation') 'NVSMI\nvml.dll')
    }
    foreach ($p in $paths) {
        try {
            if ([GreemonNative]::LoadLibraryW($p) -ne [IntPtr]::Zero) {
                $script:NvmlLoaded = $true
                return $true
            }
        } catch { }
    }
    return $false
}

# Вызов nvml-функции, возвращающей uint32 по ссылке (как _Nvml._uint):
# аргументы до [ref] — хэндл и, где нужно, номер счётчика/датчика.
# Ошибка, отсутствующая функция (старый драйвер) или ненулевой код — $null.
function Invoke-GreemonNvmlUint {
    param([string]$Name, [object[]]$CallArgs = @())
    if (-not $script:NvmlLoaded) { return $null }
    $method = [GreemonNative].GetMethod($Name)
    if ($null -eq $method) { return $null }
    $argv = @($CallArgs) + [uint32]0    # последний аргумент — выходной uint32 (byref: reflection обновит элемент массива)
    try {
        if ($method.Invoke($null, $argv) -eq 0) { return [uint32]$argv[$argv.Count - 1] }
    } catch { }
    return $null
}

function Read-GreemonNvmlName {
    param($Dev)
    try {
        $buf = New-Object byte[] 96
        if ([GreemonNative]::nvmlDeviceGetName($Dev, $buf, [uint32]96) -eq 0) {
            $s = [System.Text.Encoding]::ASCII.GetString($buf)
            $z = $s.IndexOf([char]0)
            if ($z -ge 0) { $s = $s.Substring(0, $z) }
            $s = $s.Trim()
            if ($s) { return $s }
        }
    } catch { }
    return $null
}

function New-GreemonGpuEmpty {
    $h = @{ }
    foreach ($k in $GPU_EMPTY_KEYS) { $h[$k] = $null }
    return $h
}

# --- 2.2: чтение по индексу -Gpu через NVML (как _Nvml.read) ---
function Read-GreemonGpuFromNvml {
    $o = New-GreemonGpuEmpty
    $dev = $script:NvmlDev
    try {
        $u = [GreemonNative+NvmlUtilization]::new()
        if ([GreemonNative]::nvmlDeviceGetUtilizationRates($dev, [ref]$u) -eq 0) { $o['util'] = [int]$u.gpu }
    } catch { }
    try {
        $m = [GreemonNative+NvmlMemory]::new()
        if ([GreemonNative]::nvmlDeviceGetMemoryInfo($dev, [ref]$m) -eq 0) {
            $o['mem_used'] = [long]$m.used        # байты — как ждёт build()
            $o['mem_total'] = [long]$m.total
        }
    } catch { }
    # NVML_TEMPERATURE_GPU = 0 — как в референсе
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetTemperature' @($dev, [uint32]0)
    if ($null -ne $v) { $o['temp'] = [int]$v }
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetPowerUsage' @($dev)
    if ($null -ne $v) { $o['power'] = [double]$v / 1000.0 }             # мВт → Вт
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetEnforcedPowerLimit' @($dev)
    if ($null -ne $v) { $o['power_limit'] = [double]$v / 1000.0 }       # мВт → Вт
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetCurrPcieLinkGeneration' @($dev)
    if ($null -ne $v) { $o['pcie_gen'] = [int]$v }
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetMaxPcieLinkGeneration' @($dev)
    if ($null -ne $v) { $o['pcie_gen_max'] = [int]$v }
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetCurrPcieLinkWidth' @($dev)
    if ($null -ne $v) { $o['pcie_width'] = [int]$v }
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetMaxPcieLinkWidth' @($dev)
    if ($null -ne $v) { $o['pcie_width_max'] = [int]$v }
    # NVML_PCIE_UTIL_RX_BYTES = 1, NVML_PCIE_UTIL_TX_BYTES = 0; КБ/с → МБ/с
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetPcieThroughput' @($dev, [uint32]1)
    if ($null -ne $v) { $o['pcie_rx_mb'] = [double]$v / 1024.0 }
    $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetPcieThroughput' @($dev, [uint32]0)
    if ($null -ne $v) { $o['pcie_tx_mb'] = [double]$v / 1024.0 }
    $o['name'] = Read-GreemonNvmlName $dev
    return $o
}

# --- 2.3: запасной путь — один вызов nvidia-smi --query-gpu за такт (roadmap;
# в референсе этого пути нет). PCIe RX через nvidia-smi не читается → $null. ---
$script:SmiQuery = 'name,memory.total,memory.used,utilization.gpu,temperature.gpu,power.draw,power.limit,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max'

function Read-GreemonSmiNumber {
    # '123', '12.5' → число; 'Not Supported', 'N/A', '-' и отрицательные
    # (nvidia-smi отвечает -1, когда значение недоступно) → $null.
    param([string]$Text)
    $t = "$Text".Trim()
    if ($t -match '^-?\d+(\.\d+)?$') {
        $n = [double]$t
        if ($n -lt 0) { return $null }
        return $n
    }
    return $null
}

function Read-GreemonGpuFromSmi {
    $o = New-GreemonGpuEmpty
    if (-not $script:SmiPath) { return $o }
    try {
        $lines = & $script:SmiPath "--query-gpu=$script:SmiQuery" '--format=csv,nounits' 2>$null
        if ($LASTEXITCODE -ne 0) { return $o }
        $rows = @($lines | Where-Object { $_ -and $_.Trim() } | Select-Object -Skip 1)   # первая строка — заголовок
        if ($script:GpuIndex -ge $rows.Count) { return $o }
        $f = @(($rows[$script:GpuIndex] -split ','))
        $name = "$($f[0])".Trim()
        if ($name) { $o['name'] = $name }
        $n = Read-GreemonSmiNumber $f[1]; if ($null -ne $n) { $o['mem_total'] = [long]($n * 1MB) }   # МиБ → байты
        $n = Read-GreemonSmiNumber $f[2]; if ($null -ne $n) { $o['mem_used'] = [long]($n * 1MB) }
        $n = Read-GreemonSmiNumber $f[3]; if ($null -ne $n) { $o['util'] = [int]$n }
        $n = Read-GreemonSmiNumber $f[4]; if ($null -ne $n) { $o['temp'] = [int]$n }
        $n = Read-GreemonSmiNumber $f[5]; if ($null -ne $n) { $o['power'] = $n }                     # уже в Вт
        $n = Read-GreemonSmiNumber $f[6]; if ($null -ne $n) { $o['power_limit'] = $n }
        $n = Read-GreemonSmiNumber $f[7]; if ($null -ne $n) { $o['pcie_gen'] = [int]$n }
        $n = Read-GreemonSmiNumber $f[8]; if ($null -ne $n) { $o['pcie_gen_max'] = [int]$n }
        $n = Read-GreemonSmiNumber $f[9]; if ($null -ne $n) { $o['pcie_width'] = [int]$n }
        $n = Read-GreemonSmiNumber $f[10]; if ($null -ne $n) { $o['pcie_width_max'] = [int]$n }
    } catch { }
    return $o
}

# --- 2.4: CPU % по дельте GetSystemTimes (как _CpuRamFallback в референсе). ---
function Read-GreemonCpuTimes {
    $idle = [uint64]0; $kern = [uint64]0; $user = [uint64]0
    try {
        if ([GreemonNative]::GetSystemTimes([ref]$idle, [ref]$kern, [ref]$user)) {
            # время ядра уже включает простой — как в референсе
            return @{ idle = $idle; total = ($kern + $user) }
        }
    } catch { }
    return $null
}

function Read-GreemonCpu {
    $cur = Read-GreemonCpuTimes
    $prev = $script:CpuPrev
    $script:CpuPrev = $cur
    if ($null -eq $cur -or $null -eq $prev) { return $null }
    $dTotal = [double]($cur.total - $prev.total)
    if ($dTotal -le 0) { return $null }
    $load = 100.0 * (1.0 - [double]($cur.idle - $prev.idle) / $dTotal)
    if ($load -lt 0) { $load = 0.0 }
    if ($load -gt 100) { $load = 100.0 }
    return $load
}

# --- 2.5: RAM used/total в байтах через GlobalMemoryStatusEx (как в референсе) ---
function Read-GreemonRam {
    try {
        $ms = [GreemonNative+MemoryStatusEx]::new()
        $ms.dwLength = [System.Runtime.InteropServices.Marshal]::SizeOf([type][GreemonNative+MemoryStatusEx])
        if ([GreemonNative]::GlobalMemoryStatusEx([ref]$ms)) {
            return @{ used = [long]($ms.ullTotalPhys - $ms.ullAvailPhys); total = [long]$ms.ullTotalPhys }
        }
    } catch { }
    return @{ used = $null; total = $null }
}

# --- 2.6: диск МБ/с, счётчик PhysicalDisk(_Total) (смысл — как _disk() в
# референсе: прирост байтов / время; PerformanceCounter считает дельту сам). ---
function Initialize-GreemonDisk {
    $script:DiskOk = $false
    $script:DiskRead = $null
    $script:DiskWrite = $null
    try {
        $r = New-Object System.Diagnostics.PerformanceCounter 'PhysicalDisk', 'Disk Read Bytes/sec', '_Total'
        $w = New-Object System.Diagnostics.PerformanceCounter 'PhysicalDisk', 'Disk Write Bytes/sec', '_Total'
        $null = $r.NextValue()      # первый снимок инициализирует счётчик, значение бессмысленно
        $null = $w.NextValue()
        $script:DiskRead = $r
        $script:DiskWrite = $w
        $script:DiskOk = $true
    } catch {
        # нет счётчиков производительности (отключены в реестре) — значения будут $null
        $script:DiskOk = $false
    }
}

function Read-GreemonDisk {
    if (-not $script:DiskOk) { return @{ read = $null; write = $null } }
    try {
        # байт/с → МБ/с
        return @{ read = [double]$script:DiskRead.NextValue() / 1MB; write = [double]$script:DiskWrite.NextValue() / 1MB }
    } catch {
        $script:DiskOk = $false
        return @{ read = $null; write = $null }
    }
}

# --- 2.7: статика, один раз при старте: ядра/потоки (CIM, один запрос),
# имя GPU, число GPU, VRAM total. ---
function Get-GreemonStaticInfo {
    $cores = $null; $threads = $null
    try {
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        if ($cpus.Count -gt 0) {
            $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
            $threads = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
            if ($cores -le 0) { $cores = $null }
            if ($threads -le 0) { $threads = $null }
        }
    } catch { }
    $gpuName = $null; $gpuCount = $null; $vramTotal = $null
    if ($script:GpuSource -eq 'nvml') {
        $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetCount_v2' @()
        if ($null -eq $v) { $v = Invoke-GreemonNvmlUint 'nvmlDeviceGetCount' @() }
        if ($null -ne $v) { $gpuCount = [int]$v }
        $g = Read-GreemonGpuFromNvml
        $gpuName = $g['name']; $vramTotal = $g['mem_total']
    } elseif ($script:GpuSource -eq 'smi') {
        $g = Read-GreemonGpuFromSmi
        $gpuName = $g['name']; $vramTotal = $g['mem_total']
        try {
            $lines = & $script:SmiPath '--query-gpu=name' '--format=csv,nounits' 2>$null
            if ($LASTEXITCODE -eq 0) { $gpuCount = @($lines | Where-Object { $_ -and $_.Trim() } | Select-Object -Skip 1).Count }
        } catch { }
    } elseif ($script:GpuSource -eq 'mock') {
        $gpuName = 'Mock GPU'; $gpuCount = 1; $vramTotal = [long](24GB)
        $cores = 14; $threads = 20
    }
    return @{
        cpu_cores     = $cores
        cpu_threads   = $threads
        gpu_name      = $gpuName
        gpu_count     = $gpuCount
        gpu_vram_total = $vramTotal
    }
}

# --- 2.9: режим -Mock: детерминированные синтетические данные. Всё (включая
# CPU/RAM/диск и статику) считается из номера такта — без железа и без
# случайности; два прогона дают одинаковые ряды. ---
function New-GreemonMockSample {
    $script:MockTick = $script:MockTick + 1
    $n = $script:MockTick
    $s = New-GreemonGpuEmpty
    $s['name'] = 'Mock GPU'
    $s['util'] = 45 + [int](40 * [Math]::Sin($n / 7.0))                       # 5..85 %
    $s['mem_used'] = [long](8GB + ($n % 100) * 32MB)                          # 8…11.1 GiB
    $s['mem_total'] = [long](24GB)
    $s['temp'] = 55 + ($n % 11)                                               # 55…65 °C
    $s['power'] = [double](120 + ($n % 37))                                   # 120…156 Вт
    $s['power_limit'] = 350.0
    $s['pcie_gen'] = 4; $s['pcie_gen_max'] = 4
    $s['pcie_width'] = 16; $s['pcie_width_max'] = 16
    $s['pcie_rx_mb'] = [Math]::Round(2.0 + ($n % 5) * 0.5, 2)
    $s['pcie_tx_mb'] = [Math]::Round(1.0 + ($n % 3) * 0.25, 2)
    $out = @{ }
    foreach ($k in $GPU_EMPTY_KEYS) { $out['gpu_' + $k] = $s[$k] }
    $out['cpu'] = [Math]::Round(20.0 + 35.0 * [Math]::Abs([Math]::Sin($n / 5.0)), 2)
    $out['ram_used'] = [long](10GB + ($n % 50) * 128MB)
    $out['ram_total'] = [long](64GB)
    $out['disk_read_mb'] = [Math]::Round(($n % 7) * 1.5, 2)
    $out['disk_write_mb'] = [Math]::Round(($n % 5) * 0.4, 2)
    $out['time'] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return $out
}

# --- Один сэмпл: показания GPU + CPU + RAM + диск, ключи как в telemetry.py. ---
function New-GreemonSample {
    if ($script:GpuSource -eq 'mock') { return New-GreemonMockSample }
    $g = switch ($script:GpuSource) {
        'nvml' { Read-GreemonGpuFromNvml }
        'smi'  { Read-GreemonGpuFromSmi }
        default { New-GreemonGpuEmpty }        # нет ни NVML, ни nvidia-smi: всё $null, программа не падает
    }
    $s = @{ }
    foreach ($k in $GPU_EMPTY_KEYS) { $s['gpu_' + $k] = $g[$k] }
    $s['cpu'] = Read-GreemonCpu
    $ram = Read-GreemonRam
    $s['ram_used'] = $ram['used']
    $s['ram_total'] = $ram['total']
    $d = Read-GreemonDisk
    $s['disk_read_mb'] = $d['read']
    $s['disk_write_mb'] = $d['write']
    $s['time'] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return $s
}

# --- 2.8: история по $HISTORY значений на серию; недоступное — $null, не 0;
# дробные округляем до 2 знаков — как в _loop референса. ---
function Add-GreemonSampleToHistory {
    param($Sample)
    foreach ($k in $HISTORY_SERIES) {
        $q = $script:Hist[$k]
        $v = $Sample[$k]
        if ($v -is [double]) { $v = [Math]::Round($v, 2) }
        $q.Enqueue($v)
        while ($q.Count -gt $HISTORY) { $null = $q.Dequeue() }
    }
}

# --- 2.8: цикл сэмплера раз в -Interval секунд. Iterations>0 — сделать N
# тактов и вернуть историю (для проверок); 0 — крутиться, пока не погасят
# (полный интерактивный цикл — фаза 4). ---
function Invoke-GreemonSampler {
    param([double]$IntervalSec = 1, [int]$Iterations = 0)
    $i = 0
    $script:StopSampling = $false
    while (-not $script:StopSampling) {
        $sample = New-GreemonSample
        $script:LastSample = $sample          # последние значения для модели отрисовки (фаза 3)
        Add-GreemonSampleToHistory $sample
        $i = $i + 1
        if ($Iterations -gt 0 -and $i -ge $Iterations) { break }
        Start-Sleep -Seconds $IntervalSec
    }
    return $script:Hist
}

# Инициализация слоя данных: источник GPU, статика, счётчики диска, CPU-база.
function Initialize-GreemonData {
    param([switch]$MockForce)
    $script:Hist = @{ }
    foreach ($k in $HISTORY_SERIES) { $script:Hist[$k] = New-Object 'System.Collections.Generic.Queue[object]' }
    $script:MockTick = 0
    $script:StopSampling = $false
    $script:LastSample = $null
    if ($MockForce -or $Mock) {
        $script:GpuSource = 'mock'
    } else {
        $script:GpuIndex = $Gpu
        $script:GpuSource = 'none'
        $script:NvmlDev = [IntPtr]::Zero
        if (Initialize-GreemonNvml) {
            try {
                $rc = -1
                try { $rc = [GreemonNative]::nvmlInit_v2() } catch { $rc = [GreemonNative]::nvmlInit() }
                if ($rc -eq 0) {
                    $dev = [IntPtr]::Zero
                    try { $rc = [GreemonNative]::nvmlDeviceGetHandleByIndex_v2([uint32]$Gpu, [ref]$dev) }
                    catch { $rc = [GreemonNative]::nvmlDeviceGetHandleByIndex([uint32]$Gpu, [ref]$dev) }
                    if ($rc -eq 0 -and $dev -ne [IntPtr]::Zero) {
                        $script:NvmlDev = $dev
                        $script:GpuSource = 'nvml'
                    }
                }
            } catch { }
        }
        if ($script:GpuSource -eq 'none') {
            $smi = Get-Command 'nvidia-smi' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($smi) {
                $script:SmiPath = $smi.Source
                $script:GpuSource = 'smi'
            }
        }
        Initialize-GreemonDisk
    }
    $script:CpuPrev = Read-GreemonCpuTimes    # база для первой дельты — как __init__ в _CpuRamFallback
    $script:Static = Get-GreemonStaticInfo
    return $script:Static
}

# ============================================================================
# Точка входа. При точечном подключении (. greemon.ps1) определения функций
# доступны, а запуск не выполняется — так работают проверочные скрипты.
# ============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    # Фаза 3: слой данных + отрисовка Overview. Один кадр на каждый запуск;
    # интерактивный цикл (альт. экран, клавиши, -Once как режим) — фаза 4.
    $null = Initialize-GreemonData
    $null = Invoke-GreemonSampler -IntervalSec $Interval -Iterations 2   # два снимка: CPU % по дельте
    Initialize-GreemonRenderOptions
    $model = New-GreemonRenderModel
    # 3.12: размер окна читается на каждом кадре; при перенаправлении вывода
    # консольного размера нет — берём типовые 112×32.
    $winW = 112; $winH = 32
    try { $winW = [Console]::WindowWidth } catch { }
    try { $winH = [Console]::WindowHeight } catch { }
    $lines = Format-GreemonFrame -Model $model -WindowWidth $winW -WindowHeight $winH
    $null = Enable-GreemonConsole          # 3.1: VT в консоли, если ещё не включён
    $null = Set-GreemonOutputEncoding      # 3.1: UTF-8 без BOM, прежнее значение помним
    try {
        [Console]::Out.Write((Format-GreemonFrameText $lines))
    } finally {
        Restore-GreemonConsole             # 3.1: восстановить режим консоли и кодировку
    }
    exit 0
}
