# Проверка roadmap 7.4: steady-state CPU и рабочий набор не хуже Python-версии
# в её тестовом замере (ориентиры: <=9 % одного ядра, <=48 МиБ рабочего набора;
# самим greemon Python не замерялся — берём цифры из его теста по roadmap).
#
# greemon запускается отдельным скрытым powershell.exe (реальные данные,
# -Interval 2 с), прогревается $Warmup с (старт процесса и
# компиляция Add-Type — переходящий пик, не steady), затем $Seconds с каждые
# 1 с читаются Process.TotalProcessorTime (доля одного ядра = прирост
# процессорного времени / прошедшее время, как psutil cpu_percent per-core)
# и WorkingSet64. По итогам — среднее/макс и вердикт по ориентирам.
#
# ВАЖНО (NOTES.md, фаза 7): ориентир 48 МиБ по памяти физически недостижим для
# PowerShell 5.1 — пустой powershell.exe с той же скрытой conhost занимает ~70 МиБ
# (замер в NOTES). Тест честно сравнивает с целевой цифрой roadmap; для вердикта
# «не хуже Python» сравнивайте вклад greemon над базой рантайма (~40 МиБ).
# Пороги можно задать своими: -MaxCpuPercentOfOneCore / -MaxWorkingSetMiB.
#
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-resource-usage.ps1 [-Seconds 60] [-Warmup 15] [-Mock]
param(
    [int]$Seconds = 60,
    [int]$Warmup = 15,
    [switch]$Mock,
    [int]$Interval = 2,
    # ориентиры Python-версии из roadmap
    [double]$MaxCpuPercentOfOneCore = 9.0,
    [double]$MaxWorkingSetMiB = 48.0
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src\greemon.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $src, '-Interval', $Interval)
if ($Mock) { $argl += '-Mock' }

$p = Start-Process $ps -ArgumentList $argl -WindowStyle Hidden -PassThru
try {
    Write-Output ('pid=' + $p.Id + ', прогрев ' + $Warmup + ' с...')
    Start-Sleep -Seconds $Warmup
    if ($p.HasExited) { throw ('greemon завершился до замера, exit=' + $p.ExitCode) }

    $proc = Get-Process -Id $p.Id
    $cpu0 = $proc.TotalProcessorTime
    $t0 = Get-Date
    $wsMax = [long]0
    $wsSum = [double]0
    $n = 0
    $end = $t0.AddSeconds($Seconds)
    while ((Get-Date) -lt $end -and -not $p.HasExited) {
        Start-Sleep -Seconds 1
        if ($p.HasExited) { break }
        $proc.Refresh()
        $ws = $proc.WorkingSet64
        if ($ws -gt $wsMax) { $wsMax = $ws }
        $wsSum += $ws
        $n += 1
        $sk = ((Get-Date) - $t0).TotalSeconds
        $cpuNow = 100.0 * ($proc.TotalProcessorTime - $cpu0).TotalSeconds / $sk
        Write-Output ('  T+' + ('{0,3:d1}' -f [int]$sk) + 's  CPU=' + ('{0,5}' -f ([Math]::Round($cpuNow, 1))) + ' % yadra  WS=' + ('{0,6}' -f ([Math]::Round($ws / 1MB, 1))) + ' MiB')
    }
    if ($p.HasExited) { throw ('greemon завершился во время замера, exit=' + $p.ExitCode) }
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    $proc.Refresh()
    $cpuDelta = ($proc.TotalProcessorTime - $cpu0).TotalSeconds
} finally {
    if ($null -ne $p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
}

$cpuPct = 100.0 * $cpuDelta / $elapsed
$wsMaxMiB = $wsMax / 1MB
$wsAvgMiB = $wsSum / $n / 1MB
Write-Output ''
Write-Output ('Замер: ' + [Math]::Round($elapsed, 1) + ' с интерактива (' + $(if ($Mock) { 'mock' } else { 'реальные данные' }) + ', прогрев ' + $Warmup + ' с не учитывался)')
Write-Output ('CPU: sred ' + [Math]::Round($cpuPct, 2) + ' % одного ядра (процессорного времени ' + [Math]::Round($cpuDelta, 2) + ' с), цель <= ' + $MaxCpuPercentOfOneCore + ' %')
Write-Output ('WorkingSet: max ' + [Math]::Round($wsMaxMiB, 1) + ' МиБ, sred ' + [Math]::Round($wsAvgMiB, 1) + ' МиБ, цель <= ' + $MaxWorkingSetMiB + ' МиБ (max)')

$fail = 0
if ($cpuPct -gt $MaxCpuPercentOfOneCore) { Write-Output ('FAIL: CPU ' + [Math]::Round($cpuPct, 2) + ' > ' + $MaxCpuPercentOfOneCore); $fail = 1 }
if ($wsMaxMiB -gt $MaxWorkingSetMiB) { Write-Output ('FAIL: WorkingSet max ' + [Math]::Round($wsMaxMiB, 1) + ' > ' + $MaxWorkingSetMiB); $fail = 1 }
if ($fail -eq 0) { Write-Output 'PASS: ориентиры 7.4 не превышены' }
exit $fail
