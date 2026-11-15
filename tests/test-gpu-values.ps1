# Проверка roadmap 7.3: значения greemon на реальной NVIDIA-карте сверяются с
# nvidia-smi (допуск на момент замера).
#
# greemon читается напрямую через точечное подключение src\greemon.ps1
# (Initialize-GreemonData + Read-GreemonGpuFromNvml / ...FromSmi), затем сразу
# же выполняется nvidia-smi с тем же набором полей. Поле «сверено», если оба
# источника отдали число в допуске либо оба не отдали значение (драйвер GT 710
# отвечает «Not Supported» на загрузку/мощность — greemon в этом случае хранит
# $null, см. NOTES.md фазы 2).
#
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-gpu-values.ps1 [-Gpu 0]
param([int]$GpuIndex = 0)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\greemon.ps1')
# точечное подключение присваивает параметры greemon'а значениями по умолчанию
# в этой же области видимости — задаём индекс после подключения
$Gpu = $GpuIndex

$failures = @()
function Step { param([bool]$Cond, [string]$Name)
    if ($Cond) { Write-Output ('PASS: ' + $Name) }
    else { Write-Output ('FAIL: ' + $Name); $script:failures += $Name }
}

$null = Initialize-GreemonData
Write-Output ('gpu source: ' + $script:GpuSource)
Step ($script:GpuSource -ne 'none') 'источник GPU найден (NVML или nvidia-smi)'
if ($script:GpuSource -eq 'none') { exit 1 }

$g = if ($script:GpuSource -eq 'nvml') { Read-GreemonGpuFromNvml } else { Read-GreemonGpuFromSmi }

# снимок nvidia-smi сразу после чтения greemon (тот же индекс)
$smiOut = & nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw `
    --format=csv,noheader,nounits --id=$Gpu 2>$null
if ($LASTEXITCODE -ne 0 -or -not $smiOut) {
    Write-Output 'FAIL: nvidia-smi не ответил'
    exit 1
}
$fields = ($smiOut | Select-Object -First 1) -split ','
function ToNum { param($s)
    $t = $s.Trim()
    $v = 0.0
    if ([double]::TryParse($t, [ref]$v)) { return $v }
    return $null    # «Not Supported», «N/A» и т. п.
}
$smi = @{ util = ToNum $fields[0]; mem_used_mib = ToNum $fields[1]; mem_total_mib = ToNum $fields[2];
          temp = ToNum $fields[3]; power = ToNum $fields[4] }

# --- сверка по полям; допуски: VRAM 16 МиБ (момент замера), температура 3 °C,
# загрузка 15 п.п. (между двумя обращениями GPU успевает перемаргнуть) ---
function Compare-Field { param($Name, $G, $S, [double]$Tol)
    if ($null -eq $G -and $null -eq $S) { Step $true ($Name + ': оба источника без значения (Not Supported)'); return }
    if ($null -eq $G -or $null -eq $S) { Step $false ($Name + ': одно значение есть, другое нет (greemon=' + $G + ', smi=' + $S + ')'); return }
    Step ([Math]::Abs($G - $S) -le $Tol) ($Name + ': greemon=' + $G + ', nvidia-smi=' + $S + ', допуск ' + $Tol)
}
Compare-Field 'utilization.gpu %' $g['util'] $smi['util'] 15
$smiUsedBytes = if ($null -ne $smi['mem_used_mib']) { $smi['mem_used_mib'] * 1MB } else { $null }
Compare-Field 'VRAM used' $g['mem_used'] $smiUsedBytes (16 * 1MB)
$smiTotBytes = if ($null -ne $smi['mem_total_mib']) { $smi['mem_total_mib'] * 1MB } else { $null }
Compare-Field 'VRAM total' $g['mem_total'] $smiTotBytes (16 * 1MB)
Compare-Field 'temperature °C' $g['temp'] $smi['temp'] 3
Compare-Field 'power W' $g['power'] $smi['power'] 10

if ($failures.Count -gt 0) {
    Write-Output ('ИТОГО: провалено ' + $failures.Count)
    exit 1
}
Write-Output 'ИТОГО: все проверки 7.3 пройдены'
exit 0
