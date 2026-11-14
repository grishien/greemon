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
}
'@
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
        Add-GreemonSampleToHistory (New-GreemonSample)
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
    # Фаза 2: слой данных готов; отрисовка — фаза 3, интерактивный цикл — фаза 4.
    Write-Output 'greemon: сбор данных готов (фаза 2), отрисовка и интерактивный цикл появятся в фазах 3–4. Справка: greemon -Help'
    exit 0
}
