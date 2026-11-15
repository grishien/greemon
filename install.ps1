# greemon: установщик (фаза 5, roadmap.md).
#   5.1: копирует bin\ и src\ в $env:LOCALAPPDATA\greemon\, добавляет
#        $env:LOCALAPPDATA\greemon\bin в пользовательский PATH через
#        [Environment]::SetEnvironmentVariable(..., 'User'); без прав
#        администратора; идемпотентно (повторный запуск не дублирует
#        запись и обновляет файлы).
#   5.2: обновляет $env:Path текущего процесса и печатает, что в уже
#        открытых терминалах нужен перезапуск.
# Целевая оболочка: Windows PowerShell 5.1.
#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# Читаем пользовательский PATH из HKCU\Environment БЕЗ разворачивания %VAR%
# и пишем обратно с сохранением типа значения.
# Уточнение (согласовано с пользователем 2026-11-15, см. NOTES.md): roadmap
# предписывает [Environment]::SetEnvironmentVariable(..., 'User'), но этот API
# при чтении разворачивает %VAR%-токены (грозит их потерей), а при записи
# меняет REG_EXPAND_SZ на REG_SZ. Если в PATH есть %токены — пишем реестром
# с исходным типом; иначе — SetEnvironmentVariable, как требует roadmap.
function Get-GreemonUserPath {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -eq $k) { return @{ Raw = ''; Kind = $null } }
    try {
        $raw = $k.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $null
        if ($null -ne $raw) { $kind = $k.GetValueKind('Path') }
    } finally { $k.Close() }
    if ($null -eq $raw) { $raw = '' }
    return @{ Raw = [string]$raw; Kind = $kind }
}

function Set-GreemonUserPath($Raw, $Kind) {
    if ($Raw -eq '') {
        [Environment]::SetEnvironmentVariable('Path', $null, 'User')
        return
    }
    if ($Raw.Contains('%')) {
        # %токены есть — пишем реестром с исходным типом, чтобы
        # SetEnvironmentVariable не потерял токены и не сменил тип значения.
        # Для нового значения (типа ещё нет) берём ExpandString.
        $writeKind = $Kind
        if ($null -eq $writeKind) { $writeKind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
        try { $k.SetValue('Path', $Raw, $writeKind) } finally { $k.Close() }
        return
    }
    # %токенов нет — путь roadmap: SetEnvironmentVariable(..., 'User').
    [Environment]::SetEnvironmentVariable('Path', $Raw, 'User')
}

# При прямой записи в реестр WM_SETTINGCHANGE не рассылается, и freshly
# запущенные из проводника терминалы не получат новый PATH до следующего
# логина. [Environment]::SetEnvironmentVariable рассылает его сам; здесь
# досылаем вручную (нужно для ветки реестра гибрида).
if (-not ('GreemonEnvBroadcast' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GreemonEnvBroadcast {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam,
        IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    public static void NotifyEnvironmentChange() {
        IntPtr result;
        IntPtr lParam = Marshal.StringToHGlobalUni("Environment");
        try {
            SendMessageTimeout((IntPtr)0xffff, 0x1A, IntPtr.Zero, lParam, 0x0002, 5000, out result);
        } finally {
            Marshal.FreeHGlobal(lParam);
        }
    }
}
'@ -ErrorAction Stop
}

# Источник берём относительно этого скрипта — запуск из любой папки.
$SrcRoot = $PSScriptRoot
if (-not $SrcRoot) { $SrcRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

$Needed = @('bin\greemon.cmd', 'src\greemon.ps1')
foreach ($f in $Needed) {
    $p = Join-Path $SrcRoot $f
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Error "greemon: не найден $f рядом с install.ps1 ($SrcRoot). Запустите установщик из папки проекта."
        exit 1
    }
}

$InstallRoot = Join-Path $env:LOCALAPPDATA 'greemon'
$InstallBin  = Join-Path $InstallRoot 'bin'

# --- 5.1: копирование bin\ и src\ (повторный запуск обновляет файлы) ---
Write-Output "greemon: установка в $InstallRoot"
foreach ($dir in @('bin', 'src')) {
    $from = Join-Path $SrcRoot $dir
    $to   = Join-Path $InstallRoot $dir
    # Полная замена каталога, чтобы удалённые в исходнике файлы не оставались.
    if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
}

# --- 5.1: пользовательский PATH, идемпотентно (raw, без потери %VAR%) ---
$Cur = Get-GreemonUserPath
$UserPath = $Cur.Raw
$Parts = @($UserPath -split ';' | Where-Object { $_ -ne '' })
$InUserPath = $false
foreach ($p in $Parts) {
    if ($p.TrimEnd('\') -ieq $InstallBin.TrimEnd('\')) { $InUserPath = $true; break }
}
if ($InUserPath) {
    Write-Output "greemon: $InstallBin уже есть в пользовательском PATH (запись не дублируется)"
} else {
    if ($UserPath -eq '') { $NewUserPath = $InstallBin } else { $NewUserPath = $UserPath.TrimEnd(';') + ';' + $InstallBin }
    Set-GreemonUserPath $NewUserPath $Cur.Kind
    Write-Output "greemon: $InstallBin добавлен в пользовательский PATH"
}
# WM_SETTINGCHANGE для новых терминалов (при прямой записи в реестр сам API
# его не рассылает); повторяем и при «уже есть» — безвредно, чинит случай,
# когда запись в реестре есть, а проводник о ней не знает.
[GreemonEnvBroadcast]::NotifyEnvironmentChange()

# --- 5.2: PATH текущего процесса + сообщение про перезапуск терминалов ---
$InProcPath = $false
foreach ($p in ($env:Path -split ';')) {
    if ($p.TrimEnd('\') -ieq $InstallBin.TrimEnd('\')) { $InProcPath = $true; break }
}
if (-not $InProcPath) {
    if ($env:Path -eq '') { $env:Path = $InstallBin } else { $env:Path = $env:Path + ';' + $InstallBin }
}
Write-Output 'greemon: PATH текущего процесса обновлён.'
Write-Output 'greemon: в уже открытых терминалах перезапустите терминал — новый PATH подхватывается новыми процессами.'
Write-Output 'greemon: готово. Проверка: greemon -Help'
exit 0
