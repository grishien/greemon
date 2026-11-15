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
  t       тема / theme             b     браузер, нужен -Url / browser, needs -Url
  ?       справка / help           q     выход / quit
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
    $m = @{
        state        = 'Idle'                       # 3.7: в автономном режиме всегда Idle
        phase_text   = 'Waiting for a request'      # phase_text['Idle'] в build()
        queued       = 0
        progress     = @{ done = $null; total = $null }
        context      = @{ used = $null; max = $null }
        speed        = @{ value = $null; note = 'last request'; hist = @() }   # ветка Idle в build() при пустых totals/requests
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
        recent  = @()                                                  # 3.10: пусто без сервера
        sampled_at = $(if ($null -ne $s['time']) { [double]$s['time'] } else { $null })
    }
    # 6.1–6.4: с -Url LLM-поля (состояние, прогресс, скорость, контекст,
    # experts, запросы, возраст замера) берутся из /metrics; аппаратные поля
    # gpu/cpu/disk/ram остаются локальными (6.4).
    if ($Url -and $null -ne $script:SrvModel) {
        $sv = $script:SrvModel
        $m['state'] = $sv['state']
        $m['phase_text'] = $sv['phase_text']
        $m['queued'] = $sv['queued']
        $m['progress'] = $sv['progress']
        $m['context'] = $sv['context']
        $m['speed'] = $sv['speed']
        $m['experts'] = $sv['experts']
        $m['recent'] = $sv['recent']
        $m['sampled_at'] = $sv['sampled_at']
    }
    return $m
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
    param($Model, [int]$WindowWidth, [int]$WindowHeight, [bool]$Frozen = $false, [int]$View = 0, [object[]]$HelpLines = @(),
          [string]$ConnState = 'connected', [bool]$BrowserKey = $false, [string]$Notice = '')

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

    # маркер [LIVE]/[STALE]/[FROZEN] (3.5, 6.3): FROZEN > AUTH REQUIRED >
    # CONNECTING > STALE > LIVE (map connection_state в render()); LIVE →
    # STALE, если возраст замера больше 6 секунд (как в render()).
    $marker = 'LIVE'
    if ($Frozen) { $marker = 'FROZEN' }
    elseif ($ConnState -eq 'auth_required') { $marker = 'AUTH REQUIRED' }
    elseif ($ConnState -eq 'connecting') { $marker = 'CONNECTING' }
    elseif ($ConnState -ne 'connected') { $marker = 'STALE' }
    if ($marker -eq 'LIVE' -and $null -ne $Model['sampled_at']) {
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 - $Model['sampled_at']
        if ($age -gt 6) { $marker = 'STALE' }
    }

    # ---- 3.5: шапка. Вместо URL — greemon; на месте модели — -Label; с -Url
    # рядом с меткой — контекст k(max_context) (label = model + k(ctx_max) в render()).
    $labelTxt = $Label
    $ctxMaxHead = $Model['context']['max']
    if ($ctxMaxHead) { $labelTxt += ' ' + (Format-GreemonK $ctxMaxHead) }
    $head = @((New-GreemonSeg 'STRATA  Overview   ' 'bold accent'), (New-GreemonSeg 'greemon   ' 'bold accent'), (New-GreemonSeg $labelTxt 'bold'))
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

    # ---- 3.11/6.5: строки клавиш и «Read only». Пункт `b open in browser`
    # — только с сервером (-Url); без него строка как в фазе 3.
    # 4.3: «?» ставит справку поверх строки сообщения (help_lines в _paint);
    # notice (например, «Opened … in your browser») — между справкой и «Read only».
    $hintTxt = '1-6 views' + '   / filter   Space freeze   r refresh   t theme'
    if ($BrowserKey) { $hintTxt += '   b open in browser' }
    $hintTxt += '   ? help   q quit'
    $hintLine = @(New-GreemonSeg $hintTxt 'dim')
    $msgLines = @()
    if (@($HelpLines).Count -gt 0) {
        foreach ($hl in @($HelpLines)) { $msgLines += , @(New-GreemonSeg ([string]$hl) 'dim') }
    } elseif ($Notice) {
        $msgLines += , @(New-GreemonSeg $Notice 'dim')
    } else {
        $msgLines += , @(New-GreemonSeg 'Read only  |  q quits' 'dim')
    }

    if ($View -ne 0) {
        # 3.6: в автономном режиме рабочая только вкладка 1
        $stub = @(New-GreemonSeg 'недоступно в автономном режиме')
        return , (@($headLine, $tabsLine, $ruleLine, @(), $stub, @(), $hintLine) + $msgLines)
    }

    # ---- 3.7/6.2: полоса Model state — автономно всегда Idle; с -Url —
    # состояние из /metrics; справа — прогресс «N / M tokens · P%» или «N queued»
    # (render(): right_txt), полоса — доля прогресса цветом состояния.
    $st = @(New-GreemonSeg 'Model state  ' 'bold accent')
    foreach ($n in @('Idle', 'Reading', 'Generating', 'Queued', 'Error')) {
        $txt = if ($n -eq $state) { '[' + $n + ']' } else { $n }
        $style = 'dim'
        if ($n -eq $state -and $state -ne 'Idle') { $style = $stateColor }
        elseif ($n -eq $state) { $style = 'bold' }
        $st += New-GreemonSeg ($txt + '  ') $style
    }
    $stRight = ''
    if ($null -ne $done -and $total) {
        $stRight = (Format-GreemonTokens $done) + ' / ' + (Format-GreemonTokens $total) + ' tokens ' + $dot + ' ' + [string]$pct + '%'
    } elseif ($Model['queued']) {
        $stRight = [string][int]$Model['queued'] + ' queued'
    }
    $stPad = $cw - (Get-GreemonPlain $st).Length - $stRight.Length
    if ($stPad -lt 2) { $stPad = 2 }
    $stLine = Cut-GreemonSegs ($st + @(New-GreemonSeg ((' ' * $stPad) + $stRight) 'dim')) $width
    $barW = $cw - 2
    if ($barW -lt 20) { $barW = 20 }
    $stateFrac = $null
    if ($null -ne $done -and $total) { $stateFrac = $done / $total }
    $stateBarStyle = 'accent'
    if ($state -ne 'Idle') { $stateBarStyle = $stateColor }
    $stateBarLine = Format-GreemonBar $stateFrac $barW $stateBarStyle

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
    if ($null -ne $Model['experts']['slots']) { $vramSub = (Format-GreemonNum $Model['experts']['slots'] 0) + ' experts cached' }
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
        (New-GreemonTile 'Speed' $spdBig $Model['speed']['note'] (Format-GreemonSpark $Model['speed']['hist'] $inner) $tileW),
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
    # 6.2: Experts in VRAM — доля слотов (e['slots'] / e['total'] в render())
    $eFrac = $null
    if ($null -ne $e['slots'] -and $e['total']) { $eFrac = $e['slots'] / $e['total'] }
    $leftLines = @(
        (, (@(New-GreemonSeg 'Context fill  ' 'bold accent') + @(New-GreemonSeg $ctxTxt))),
        (Format-GreemonBar $usedFrac $leftW 'accent'),
        (, (@(New-GreemonSeg 'Experts in VRAM   ') + @(New-GreemonSeg $expTxt 'dim'))),
        (Format-GreemonBar $eFrac $leftW 'accent'),
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
    foreach ($l in $msgLines) { $lines += , $l }
    return , $lines
}

# Кадры в строки текста с ANSI. Без Pad-* (-Once, 4.5): как в фазе 3 — каждая
# строка с завершающим переводом. С Pad-* (интерактив, 4.2): каждая строка
# дополняется пробелами до ширины окна, кадр дополняется пустыми строками до
# высоты окна (не больше, чтобы не прокручивать альтернативный экран),
# завершающего перевода у последней строки нет. Благодаря этому кадр после
# ESC[H перекрывает весь прежний без очистки экрана — мерцания нет.
function Format-GreemonFrameText {
    param($Lines, [int]$PadWidth = 0, [int]$PadHeight = 0)
    $arr = @($Lines)
    $n = $arr.Count
    $padded = ($PadWidth -gt 0 -or $PadHeight -gt 0)
    if ($padded) {
        if ($PadHeight -gt 0 -and $PadHeight -lt $n) { $n = $PadHeight }   # хвост за экраном всё равно ушёл бы в прокрутку
        if ($PadHeight -gt $n) { $n = $PadHeight }
    }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $n; $i++) {
        if ($i) { $null = $sb.Append("`r`n") }
        $segs = if ($i -lt $arr.Count) { @($arr[$i]) } else { @() }
        $null = $sb.Append((Format-GreemonSegs $segs))
        if ($PadWidth -gt 0) {
            $len = (Get-GreemonPlain $segs).Length
            if ($len -lt $PadWidth) { $null = $sb.Append(' ' * ($PadWidth - $len)) }
        }
        if (-not $padded -and $i -eq $n - 1) { $null = $sb.Append("`r`n") }
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
# Фаза 4. Цикл и управление (см. roadmap.md).
# 4.1 — альтернативный экран и скрытый курсор при старте, восстановление
# (курсор, основной экран, режим консоли, кодировка) в finally при любом
# выходе, включая ошибку и Ctrl+C; 4.2 — кадр одним [Console]::Out.Write()
# после ESC[H без очистки экрана; 4.3 — опрос клавиш без блокировки;
# 4.4 — точный сон по абсолютному расписанию без дрейфа (диапазона -Interval
# в референсе нет — см. NOTES.md, клампа нет; ноль/отрицательное — ошибка).
# ============================================================================

# HELP_SECONDS и список клавиш — из monitor.py (_help_line/action_help).
# Состав клавиш — набор автономной версии (3.11), без Tab/Enter/стрелок.
$HELP_SECONDS = 15.0
$GREEMON_HELP_LINE = '1-6 views  / filter  Space freeze  r refresh  t theme  ? help  q quit'

# Опрос клавиш — отдельными тонкими обёртками над [Console], чтобы тесты
# фазы могли подменить источник клавиш (реальный путь — консоль).
function Test-GreemonKeyAvailable { return [Console]::KeyAvailable }
function Read-GreemonKey { return [Console]::ReadKey($true) }

# 4.3: клавиша → действие и новые состояния интерфейса. Ключи $Ui: frozen,
# view, helpOpen, helpUntil ($null или DateTime UTC), theme.
# Возвращает: 'quit' | 'refresh' | 'redraw' | '' (клавиша не из набора).
# Порядок и смысл — BINDINGS/action_* из monitor.py; тема циклом auto→dark→
# light→auto (action_theme_cycle: terminal→dark→light→terminal).
function Handle-GreemonUiKey {
    param($K, $Ui)
    if ($K.Key -eq [ConsoleKey]::Escape) { $Ui['helpOpen'] = $false; $Ui['helpUntil'] = $null; return '' }
    $ch = $K.KeyChar
    if ($ch -eq 'q') { return 'quit' }
    if ($ch -eq ' ') {
        $Ui['frozen'] = -not [bool]$Ui['frozen']
        # как action_freeze: при снятии заморозки сразу показать свежий кадр
        if (-not [bool]$Ui['frozen']) { return 'refresh' }
        return 'redraw'
    }
    if ($ch -eq 'r') { return 'refresh' }
    if ($ch -eq 't') {
        $Ui['theme'] = switch ([string]$Ui['theme']) {
            'auto' { 'dark' }
            'dark' { 'light' }
            default { 'auto' }
        }
        $script:ThemeResolved = if ($Ui['theme'] -eq 'light') { 'light' } else { 'dark' }
        return 'redraw'
    }
    if ($ch -eq '?') {
        # action_help: повторное «?» закрывает; иначе справка на HELP_SECONDS
        if ([bool]$Ui['helpOpen']) { $Ui['helpOpen'] = $false; $Ui['helpUntil'] = $null }
        else { $Ui['helpOpen'] = $true; $Ui['helpUntil'] = [DateTime]::UtcNow.AddSeconds($HELP_SECONDS) }
        return 'redraw'
    }
    if ($ch -ge '1' -and $ch -le '6') {
        # action_view_N; как _set_view: смена вида закрывает справку
        $Ui['view'] = [int][string]$ch - 1
        $Ui['helpOpen'] = $false
        $Ui['helpUntil'] = $null
        return 'redraw'
    }
    if ($ch -eq 'b') {
        # 6.5: «b open in browser» живёт только с -Url (action_browser в референсе)
        if ($Url) { return 'browser' }
        return ''
    }
    return ''
}

# 4.3: список клавиш для справки — перенос по разделителям «между клавишами»
# (два пробела), никогда внутри клавиши; _help_wrapped() из monitor.py
# (room = max(20, width - 2)).
function Format-GreemonHelpLines {
    param([string]$Line, [int]$Width)
    $room = $Width - 2
    if ($room -lt 20) { $room = 20 }
    $lines = @()
    foreach ($item in ($Line -split '  ')) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Length + 2 + $item.Length -le $room) {
            $lines[$lines.Count - 1] += '  ' + $item
        } else {
            $lines += $item
        }
    }
    return , $lines
}

# 4.4: абсолютное расписание кадров: следующее время — от *планового* времени
# предыдущего кадра, поэтому задержки кадра не накапливаются; если отстали,
# пропущенные кадры пропускаются без «догона» очередью (как set_interval).
function Get-GreemonNextFrameAt {
    param([DateTime]$Now, $Prev, [double]$IntervalSec)
    if ($null -eq $Prev) { return $Now.AddSeconds($IntervalSec) }
    $t = $Prev
    while ($t -le $Now) { $t = $t.AddSeconds($IntervalSec) }
    return $t
}

# Интерактивный цикл. $Out — поток вывода кадров ([Console]::Out; тесты
# подают StringWriter). Выход: 'q' (код 0), Ctrl+C (остановка конвейера),
# ошибка — исключение наружу; восстановление терминала в finally в любом из
# этих случаев (4.1).
function Start-GreemonInteractiveLoop {
    param($Out = $null)

    $null = Initialize-GreemonData
    Initialize-GreemonRenderOptions
    $null = Enable-GreemonConsole        # 3.1: VT в консоли
    $null = Set-GreemonOutputEncoding    # 3.1: UTF-8 без BOM, прежнее помним
    if ($null -eq $Out) { $Out = [Console]::Out }

    # 6.1/6.3: состояние соединения с сервером на новый запуск
    $script:SrvModel = $null
    $script:SrvFailures = 0
    $script:SrvNextPollAt = $null
    $script:SrvNotice = ''
    if ($Url) { $script:ConnState = 'connecting' } else { $script:ConnState = 'connected' }

    $ui = @{
        frozen   = $false
        view     = 0
        helpOpen = $false
        helpUntil = $null
        theme    = $Theme
    }
    $model = $null
    $nextAt = $null
    $forceSample = $true     # первый кадр снимает данные сразу
    $dirty = $true           # перерисовать вне планового тика (клавиша/размер)

    try {
        # 4.1: альтернативный экран и скрытый курсор
        $Out.Write($ESC + '[?1049h')
        $Out.Write($ESC + '[?25l')
        while ($true) {
            # 4.3: клавиши без блокировки
            while (Test-GreemonKeyAvailable) {
                $action = Handle-GreemonUiKey (Read-GreemonKey) $ui
                if ($action -eq 'quit') { return }
                if ($action -eq 'refresh') { $forceSample = $true; $dirty = $true }
                elseif ($action -eq 'redraw') { $dirty = $true }
                elseif ($action -eq 'browser') {
                    # 6.5: открыть сервер в браузере (action_browser в референсе)
                    try {
                        Start-Process $Url
                        $script:SrvNotice = 'Opened ' + $Url + ' in your browser'
                    } catch {
                        $script:SrvNotice = 'Open ' + $Url + ' in a browser (none could be started here)'
                    }
                    $dirty = $true
                }
            }

            $now = [DateTime]::UtcNow
            if ($ui['helpOpen'] -and $now -ge $ui['helpUntil']) {
                $ui['helpOpen'] = $false; $ui['helpUntil'] = $null; $dirty = $true
            }
            $due = $forceSample -or ($null -eq $nextAt) -or ($now -ge $nextAt)
            if ($due) {
                # 6.1/6.3: опрос /metrics (с нарастающей паузой после ошибок); в
                # референсе опрос идёт и во время заморозки, кадр при этом статичен
                if ($Url) { Update-GreemonServerModel }
                # «Frozen display» как в референсе: во время заморозки кадр не
                # обновляется (action_freeze показывает последний снимок)
                if (-not [bool]$ui['frozen']) {
                    $sample = New-GreemonSample
                    $script:LastSample = $sample      # последние значения для модели отрисовки
                    Add-GreemonSampleToHistory $sample
                    $model = New-GreemonRenderModel
                }
                $winW = 112; $winH = 32    # 3.12: размер окна читается на каждом кадре
                try { $winW = [Console]::WindowWidth; $winH = [Console]::WindowHeight } catch { }
                $helpLines = @()
                if ($ui['helpOpen']) { $helpLines = Format-GreemonHelpLines $GREEMON_HELP_LINE $winW }
                $lines = Format-GreemonFrame -Model $model -WindowWidth $winW -WindowHeight $winH `
                    -Frozen ([bool]$ui['frozen']) -View ([int]$ui['view']) -HelpLines $helpLines `
                    -ConnState $script:ConnState -BrowserKey ([bool]$Url) -Notice $script:SrvNotice
                # 4.2: возврат курсора и весь кадр — одной записью, без очистки
                $Out.Write($ESC + '[H' + (Format-GreemonFrameText $lines $winW $winH))
                $nextAt = Get-GreemonNextFrameAt $now $nextAt $Interval
                $forceSample = $false
                $dirty = $false
            }
            elseif ($dirty -and $null -ne $model) {
                # перерисовка по клавише/справке без нового замера (расписание не сдвигается)
                $winW = 112; $winH = 32
                try { $winW = [Console]::WindowWidth; $winH = [Console]::WindowHeight } catch { }
                $helpLines = @()
                if ($ui['helpOpen']) { $helpLines = Format-GreemonHelpLines $GREEMON_HELP_LINE $winW }
                $lines = Format-GreemonFrame -Model $model -WindowWidth $winW -WindowHeight $winH `
                    -Frozen ([bool]$ui['frozen']) -View ([int]$ui['view']) -HelpLines $helpLines `
                    -ConnState $script:ConnState -BrowserKey ([bool]$Url) -Notice $script:SrvNotice
                $Out.Write($ESC + '[H' + (Format-GreemonFrameText $lines $winW $winH))
                $dirty = $false
            }

            # сон до следующего кадра; короткие срезы, чтобы клавиши
            # отзывались быстрее интервала
            $napMs = 25.0
            if ($null -ne $nextAt) {
                $rem = ($nextAt - [DateTime]::UtcNow).TotalMilliseconds
                if ($rem -lt 1) { $rem = 1 } elseif ($rem -gt $napMs) { $rem = $napMs }
                $napMs = $rem
            }
            [System.Threading.Thread]::Sleep([int]$napMs)
        }
    } finally {
        # 4.1: курсор виден, основной экран, прежний режим консоли и кодировка —
        # при любом выходе: q, ошибка, Ctrl+C (остановка конвейера выполняет finally).
        try { $Out.Write($ESC + '[?25h') } catch { }
        try { $Out.Write($ESC + '[?1049l') } catch { }
        Restore-GreemonConsole
    }
}

# ============================================================================
# Фаза 6. Панели LLM через сервер Strata (см. roadmap.md). Работает только
# при -Url; без него программа остаётся чисто аппаратной. Аппаратные плитки
# по-прежнему берутся локально, а не из /metrics (6.4).
# ============================================================================

# 6.1: таймаут запроса — 3 с, как Endpoint.timeout по умолчанию в client.py.
$METRICS_TIMEOUT_SEC = 3.0

# Ключ API: из -ApiKey, иначе из переменной окружения STRATA_API_KEY (6.1).
# Ключ попадает только в заголовок Authorization; не печатается и не логируется.
$script:StrataApiKey = $ApiKey
if (-not $script:StrataApiKey -and $null -ne [Environment]::GetEnvironmentVariable('STRATA_API_KEY')) {
    $script:StrataApiKey = [Environment]::GetEnvironmentVariable('STRATA_API_KEY')
}

# Состояние соединения с сервером (маркер шапки — 6.3):
# connected | connecting | stale | auth_required.
$script:ConnState = 'connected'
$script:SrvModel = $null          # LLM-часть модели отрисовки из /metrics (6.2)
$script:SrvFailures = 0
$script:SrvNextPollAt = $null     # раньше этого времени не опрашиваем (пауза 6.3)
$script:SrvNotice = ''            # сообщение строки сообщения (например, после «b»)
$script:GreemonRand = New-Object System.Random

# JSON-значение → double или $null (_num() из overview.py: bool, строка,
# структуры, NaN и ±∞ → $null). PS 5.1 отдаёт нецелые числа из JSON как Decimal,
# поэтому принимаем любой IConvertible-числовой тип (int/long/double/decimal/...).
function Get-GreemonJNum {
    param($V)
    if ($null -eq $V) { return $null }
    if ($V -is [bool] -or $V -is [string] -or $V -is [char]) { return $null }
    if ($V -isnot [System.IConvertible]) { return $null }
    try { $d = [double]$V } catch { return $null }
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
    return $d
}

# Свойство PSCustomObject (JSON-объекта) по имени; нет объекта/свойства → $null.
# Одноэлементный JSON-массив возвращаем через запятую: иначе return «разворачивает»
# массив из одного элемента в сам элемент и проверки -is [Object[]] врут.
function Get-GreemonJProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    $v = $p.Value
    if ($v -is [System.Array]) { return ,$v }
    return $v
}

# JSON-объект (не массив/строка/число)? — аналог isinstance(x, dict).
function Test-GreemonJObj {
    param($V)
    return ($V -is [System.Management.Automation.PSCustomObject])
}

# request_speed() из overview.py: decode_tok_s, иначе output/decode_ms при
# output >= 2 и decode_ms > 0 (1 токен не даёт интервала декодирования).
function Get-GreemonRequestSpeed {
    param($R)
    $dts = Get-GreemonJNum (Get-GreemonJProp $R 'decode_tok_s')
    if ($null -ne $dts) { return $dts }
    $out = Get-GreemonJNum (Get-GreemonJProp $R 'output_tokens')
    $ms = Get-GreemonJNum (Get-GreemonJProp $R 'decode_ms')
    if ($null -ne $out -and $out -ge 2 -and $null -ne $ms -and $ms -gt 0) {
        return [math]::Round($out / ($ms / 1000.0), 1)
    }
    return $null
}

# 6.3: пауза перед повтором — формула _poll из monitor.py:
# min(30, 2^min(failures,5) * uniform(0.8, 1.2)).
function Get-GreemonPollDelay {
    param([int]$Failures)
    $jitter = 0.8 + 0.4 * $script:GreemonRand.NextDouble()
    $d = [math]::Pow(2, [math]::Min($Failures, 5)) * $jitter
    if ($d -gt 30) { $d = 30 }
    return $d
}

# 6.1: GET <Url>/metrics через Invoke-RestMethod; Bearer из ключа, если задан.
# Возвращает @{ ok; auth; data }. Ошибку не печатаем (6.3 — только маркер
# шапки); 401/403 помечаем auth. Ключ в сообщение об ошибке не попадает.
function Fetch-GreemonMetrics {
    param([string]$BaseUrl)
    $out = @{ ok = $false; auth = $false; data = $null }
    $uri = "$BaseUrl".TrimEnd('/') + '/metrics'
    $headers = @{ Accept = 'application/json' }
    if ($script:StrataApiKey) { $headers['Authorization'] = 'Bearer ' + $script:StrataApiKey }
    try {
        $data = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec $METRICS_TIMEOUT_SEC -UseBasicParsing
    } catch {
        $status = 0
        try {
            $ex = $_.Exception
            while ($null -ne $ex -and $status -eq 0) {
                $prop = $ex.GetType().GetProperty('Response')
                if ($null -ne $prop) {
                    $resp = $prop.GetValue($ex, $null)
                    if ($null -ne $resp) {
                        $sc = $resp.GetType().GetProperty('StatusCode')
                        if ($null -ne $sc) { $status = [int]$sc.GetValue($resp, $null) }
                    }
                }
                $ex = $ex.InnerException
            }
        } catch { }
        $out['auth'] = ($status -eq 401 -or $status -eq 403)
        return $out
    }
    # не-JSON/скаляр/массив на верхнем уровне — ответ не годится (как «не dict» в client.py)
    if (-not (Test-GreemonJObj $data)) { return $out }
    $out['ok'] = $true
    $out['data'] = $data
    return $out
}

# 6.2: порт LLM-части build() из hwmon\strata_cli\overview.py: state, прогресс,
# скорость и подпись, контекст, Experts in VRAM, последние запросы (до 6),
# ряд tok_s для спарклайна Speed, возраст замера. Аппаратная часть build()
# (hardware/history железа) не разбирается: плитки берутся локально (6.4).
# Нет «live»-объекта — $null (build() тоже возвращает None).
function ConvertTo-GreemonServerModel {
    param($Metrics)
    $live = Get-GreemonJProp $Metrics 'live'
    if (-not (Test-GreemonJObj $live)) { return $null }
    $engine = Get-GreemonJProp $Metrics 'engine'
    if (-not (Test-GreemonJObj $engine)) { $engine = $null }
    # ВАЖНО: имена локалов не должны различаться от $HISTORY только регистром
    # (PS не различает регистр): history → histObj.
    $histObj = Get-GreemonJProp $Metrics 'history'
    if (-not (Test-GreemonJObj $histObj)) { $histObj = $null }
    $totals = Get-GreemonJProp $Metrics 'totals'
    if (-not (Test-GreemonJObj $totals)) { $totals = $null }

    # requests: только списки объектов (как isinstance(..., list) + isinstance(r, dict) в build())
    $recentIn = @()
    $recentRaw = Get-GreemonJProp $Metrics 'requests'
    if ($recentRaw -is [System.Object[]]) {
        foreach ($x in $recentRaw) { if (Test-GreemonJObj $x) { $recentIn += $x } }
    }
    $last = if ($recentIn.Count -gt 0) { $recentIn[0] } else { $null }

    $stateRawV = Get-GreemonJProp $live 'state'
    $stateRaw = if ($stateRawV -is [string] -and $stateRawV) { $stateRawV } else { 'idle' }
    $queued = Get-GreemonJNum (Get-GreemonJProp $live 'queued')
    if ($null -eq $queued) { $queued = 0 }
    $isErr = $false
    if (Get-GreemonJProp $engine 'error') { $isErr = $true }        # bool(engine.get("error"))
    if ($stateRaw -eq 'error') { $isErr = $true }
    $state = 'Idle'
    if ($isErr) { $state = 'Error' }
    elseif ($stateRaw -eq 'reading') { $state = 'Reading' }
    elseif ($stateRaw -eq 'generating') { $state = 'Generating' }
    elseif ($queued -gt 0 -and $stateRaw -ne 'reading' -and $stateRaw -ne 'generating') { $state = 'Queued' }
    $active = ($state -eq 'Reading' -or $state -eq 'Generating')
    $phaseText = @{ Idle = 'Waiting for a request'; Reading = 'Reading prompt'; Generating = 'Generating a reply';
                    Queued = 'Requests are queued'; Error = 'Model unavailable' }[$state]

    # прогресс: reading — prompt_read/prompt_total; generating — generated/max_tokens
    $promptRead = Get-GreemonJNum (Get-GreemonJProp $live 'prompt_read')
    $promptTotal = Get-GreemonJNum (Get-GreemonJProp $live 'prompt_total')
    $generated = Get-GreemonJNum (Get-GreemonJProp $live 'generated')
    $maxTokens = Get-GreemonJNum (Get-GreemonJProp $live 'max_tokens')
    $done = $null; $total = $null
    if ($state -eq 'Reading' -and $promptTotal) { $done = $(if ($null -ne $promptRead) { $promptRead } else { 0.0 }); $total = $promptTotal }
    elseif ($state -eq 'Generating' -and $maxTokens) { $done = $(if ($null -ne $generated) { $generated } else { 0.0 }); $total = $maxTokens }

    # контекст: во время запроса — prompt_tokens + generated, иначе последнего запроса
    $maxCtx = Get-GreemonJNum (Get-GreemonJProp $engine 'max_context')
    $ctxUsed = $null
    $promptTokens = Get-GreemonJNum (Get-GreemonJProp $live 'prompt_tokens')
    if ($active -and $null -ne $promptTokens -and $null -ne $generated) { $ctxUsed = $promptTokens + $generated }
    elseif ($null -ne $last) {
        $lp = Get-GreemonJNum (Get-GreemonJProp $last 'prompt_tokens')
        $lo = Get-GreemonJNum (Get-GreemonJProp $last 'output_tokens')
        if ($null -ne $lp -and $null -ne $lo) { $ctxUsed = $lp + $lo }
    }

    # скорость и подпись (ветки build()); спарклайн Speed — ряд history.tok_s
    $speedVal = $null; $speedNote = ''
    if ($state -eq 'Generating') {
        $t = Get-GreemonJNum (Get-GreemonJProp $live 'tok_s')
        if ($null -ne $t) { $speedVal = $t; $speedNote = 'now' }
    }
    if ($speedNote -eq '' -and $state -eq 'Reading') {
        $p = Get-GreemonJNum (Get-GreemonJProp $live 'prefill_tok_s_mean')
        if ($null -ne $p) { $speedVal = $p; $speedNote = 'reading the prompt' }
    }
    if ($speedNote -eq '') {
        # Idle (и генерация без tok_s): среднее по totals, иначе последнего запроса
        $tout = Get-GreemonJNum (Get-GreemonJProp $totals 'output_tokens')
        $mst = Get-GreemonJNum (Get-GreemonJProp $totals 'decode_ms')
        if ($null -ne $tout -and $tout -ge 2 -and $null -ne $mst -and $mst -gt 0) {
            $speedVal = [math]::Round($tout / ($mst / 1000.0), 1); $speedNote = 'average of the run'
        } else {
            $speedVal = $(if ($null -ne $last) { Get-GreemonRequestSpeed $last } else { $null })
            $speedNote = 'last request'
        }
    }
    $tokHist = @()
    $hv = Get-GreemonJProp $histObj 'tok_s'
    if ($hv -is [System.Object[]]) {
        $vals = @($hv)
        if ($vals.Count -gt $HISTORY) { $vals = $vals[($vals.Count - $HISTORY)..($vals.Count - 1)] }
        $tokHist = @(foreach ($x in $vals) { Get-GreemonJNum $x })
    }

    # Experts in VRAM: слоты, всего, кэш ГиБ (cache_mib / 1024)
    $slots = Get-GreemonJNum (Get-GreemonJProp $engine 'expert_slots')
    $totalSlots = Get-GreemonJNum (Get-GreemonJProp $engine 'experts')
    $cacheMib = Get-GreemonJNum (Get-GreemonJProp $engine 'expert_cache_mib')
    $expGb = $(if ($null -ne $cacheMib) { $cacheMib / 1024.0 } else { $null })

    # последние запросы (до 6): статус, токены, скорость, длительность
    $recent = @()
    foreach ($r in $recentIn) {
        if ($recent.Count -ge 6) { break }
        $fr = Get-GreemonJProp $r 'finish_reason'
        if ($null -eq $fr -or ($fr -is [string] -and $fr -eq '')) { $fr = Get-GreemonJProp $r 'finish' }
        $rState = 'Done'
        if (Get-GreemonJProp $r 'error') { $rState = 'Error' }
        elseif ($fr -is [string] -and @('cancelled', 'error', 'abort') -contains $fr) { $rState = 'Stopped' }
        $recent += , @{
            time     = Get-GreemonJNum (Get-GreemonJProp $r 'time')
            state    = $rState
            prompt   = Get-GreemonJNum (Get-GreemonJProp $r 'prompt_tokens')
            reused   = Get-GreemonJNum (Get-GreemonJProp $r 'reused')
            output   = Get-GreemonJNum (Get-GreemonJProp $r 'output_tokens')
            tps      = Get-GreemonRequestSpeed $r
            duration = Get-GreemonJNum (Get-GreemonJProp $r 'duration_s')
        }
    }

    return @{
        state      = $state
        phase_text = $phaseText
        queued     = [int]$queued
        progress   = @{ done = $done; total = $total }
        context    = @{ used = $ctxUsed; max = $maxCtx }
        speed      = @{ value = $speedVal; note = $speedNote; hist = $tokHist }
        experts    = @{ slots = $slots; total = $totalSlots; gb = $expGb }
        recent     = $recent
        sampled_at = Get-GreemonJNum (Get-GreemonJProp $Metrics 'time')
    }
}

# 6.1/6.3: один опрос /metrics с паузой после ошибок. При успехе обновляет
# модель и снимает паузу; при ошибке — растущая пауза и состояние stale /
# auth_required (программа не падает). В справочном monitor.py на 401/403
# опрос прекращается совсем; roadmap 6.3 требует повтор с нарастающей паузой
# и для них (NOTES.md).
function Update-GreemonServerModel {
    if (-not $Url) { return }
    $now = [DateTime]::UtcNow
    if ($null -ne $script:SrvNextPollAt -and $now -lt $script:SrvNextPollAt) { return }
    $r = Fetch-GreemonMetrics $Url
    if ($r['ok']) {
        $m = ConvertTo-GreemonServerModel $r['data']
        if ($null -ne $m) {
            $script:SrvModel = $m
            $script:ConnState = 'connected'
            $script:SrvFailures = 0
            $script:SrvNextPollAt = $null
            $script:SrvNotice = ''      # сообщение (как error=None в _poll) больше не нужно
            return
        }
        # ответ без «live» (старый/чужой сервер) — как ошибка сети: [STALE] (NOTES.md)
        $auth = $false
    } else {
        $auth = [bool]$r['auth']
    }
    $script:SrvFailures = $script:SrvFailures + 1
    if ($auth) { $script:ConnState = 'auth_required' } else { $script:ConnState = 'stale' }
    # Пауза считается от момента после неудачи (как sleep() в _poll после запроса),
    # иначе долгий таймаут «съедает» паузу и шлюз не держит повтор.
    $script:SrvNextPollAt = [DateTime]::UtcNow.AddSeconds((Get-GreemonPollDelay $script:SrvFailures))
}

# ============================================================================
# Точка входа. При точечном подключении (. greemon.ps1) определения функций
# доступны, а запуск не выполняется — так работают проверочные скрипты.
# ============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if ($Once) {
        # 4.5: -Once — один кадр в текущий поток вывода, без альтернативного
        # экрана и без клавиш, код 0 (для тестов).
        $null = Initialize-GreemonData
        if ($Url) { Update-GreemonServerModel }        # 6.1: один запрос /metrics
        $null = Invoke-GreemonSampler -IntervalSec $Interval -Iterations 2   # два снимка: CPU % по дельте
        Initialize-GreemonRenderOptions
        $model = New-GreemonRenderModel
        # 3.12: размер окна читается на каждом кадре; при перенаправлении вывода
        # консольного размера нет — берём типовые 112×32.
        $winW = 112; $winH = 32
        try { $winW = [Console]::WindowWidth } catch { }
        try { $winH = [Console]::WindowHeight } catch { }
        $lines = Format-GreemonFrame -Model $model -WindowWidth $winW -WindowHeight $winH `
            -ConnState $script:ConnState -BrowserKey ([bool]$Url)
        $null = Enable-GreemonConsole          # 3.1: VT в консоли, если ещё не включён
        $null = Set-GreemonOutputEncoding      # 3.1: UTF-8 без BOM, прежнее значение помним
        try {
            [Console]::Out.Write((Format-GreemonFrameText $lines))
        } finally {
            Restore-GreemonConsole             # 3.1: восстановить режим консоли и кодировку
        }
        exit 0
    }

    # 4.6: нет интерактивного терминала (вывод или ввод перенаправлен) —
    # в интерактивный режим не входим, сообщение в stderr, ненулевой код.
    if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) {
        [Console]::Error.WriteLine('greemon: интерактивный режим требует терминала (вывод или ввод перенаправлен). ' +
            'Запустите в терминале или используйте -Once. / greemon: interactive mode needs a terminal ' +
            '(output or input is redirected). Run in a terminal or use -Once.')
        exit 2
    }

    # 4.4: диапазона -Interval в референсе нет (NOTES.md); неотрицательное — ошибка
    if ($Interval -le 0) {
        [Console]::Error.WriteLine('greemon: -Interval должен быть больше 0. / greemon: -Interval must be greater than 0.')
        exit 2
    }

    Start-GreemonInteractiveLoop
    exit 0
}
