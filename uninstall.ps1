# greemon: деинсталлятор (фаза 5, roadmap.md).
#   5.3: удаляет запись из пользовательского PATH и папку установки
#        ($env:LOCALAPPDATA\greemon).
# Целевая оболочка: Windows PowerShell 5.1.
#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# Тот же безопасный доступ к пользовательскому PATH, что в install.ps1:
# читаем HKCU\Environment без разворачивания %VAR%, пишем с сохранением типа
# (уточнение согласовано с пользователем 2026-11-15, см. NOTES.md);
# без %токенов — [Environment]::SetEnvironmentVariable(..., 'User').
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
        $writeKind = $Kind
        if ($null -eq $writeKind) { $writeKind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
        try { $k.SetValue('Path', $Raw, $writeKind) } finally { $k.Close() }
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $Raw, 'User')
}

# WM_SETTINGCHANGE при прямой записи в реестр не рассылается — досылаем
# вручную (см. install.ps1 / NOTES.md).
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

$InstallRoot = Join-Path $env:LOCALAPPDATA 'greemon'
$InstallBin  = Join-Path $InstallRoot 'bin'

# --- 5.3: убрать запись из пользовательского PATH (raw, без потери %VAR%) ---
$Cur = Get-GreemonUserPath
$UserPath = $Cur.Raw
$Parts = @($UserPath -split ';')
$Kept = @($Parts | Where-Object { $_.TrimEnd('\') -ine $InstallBin.TrimEnd('\') })
if ($Kept.Count -ne $Parts.Count) {
    $NewUserPath = ($Kept -join ';')
    if ($NewUserPath.Trim(';') -eq '') { $NewUserPath = '' }
    Set-GreemonUserPath $NewUserPath $Cur.Kind
    [GreemonEnvBroadcast]::NotifyEnvironmentChange()   # WM_SETTINGCHANGE для новых терминалов
    Write-Output "greemon: запись $InstallBin удалена из пользовательского PATH"
} else {
    Write-Output 'greemon: записи установки в пользовательском PATH не найдено (ничего не меняю)'
}

# --- 5.3: удалить папку установки ---
if (Test-Path -LiteralPath $InstallRoot) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    Write-Output "greemon: папка $InstallRoot удалена"
} else {
    Write-Output "greemon: папка $InstallRoot не найдена (ничего не удаляю)"
}
Write-Output 'greemon: готово. В уже открытых терминалах перезапустите терминал.'
exit 0
