# Проверка roadmap 7.1: greemon -Mock -Once на размерах окна 110x32 и 80x24 даёт
# кадр без исключений; нужные подписи присутствуют.
#
# Механизм: для каждого размера запускается рабочий процесс в новой скрытой
# conhost-сессии (там свой настоящий консольный экран). Рабочий задаёт размер
# окна/буфера, открывает CONOUT$ (GENERIC_READ|GENERIC_WRITE — нужно для
# GetConsoleScreenBufferInfo), запускает src\greemon.ps1 -Mock -Once через
# CreateProcessW с этим stdout/stderr (дочерний получает реальный размер окна и
# рисует на экран), затем читает клетки экрана — это и есть захваченный кадр.
#
# Запуск:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-frame-render.ps1
# Код возврата 0 — все проверки прошли.
param(
    [int[]]$Sizes = @(110, 32, 80, 24),   # пары W,H
    # --- служебный режим рабочего процесса ---
    [switch]$Worker,
    [int]$Width = 0,
    [int]$Height = 0,
    [string]$FrameFile = '',
    [string]$InfoFile = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Self = Join-Path $PSScriptRoot 'test-frame-render.ps1'

# Подпись и запуск дочернего процесса с готовыми консольными std-ручками.
# Весь вызов — на C#: маршалинг STARTUPINFO из PowerShell почему-то даёт
# ERROR_INVALID_NAME (зафиксировано при разработке проверки).
$cs = @'
using System;
using System.Runtime.InteropServices;
public static class GreemonTestHost {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tpl);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="CreateProcessW")]
    static extern bool CreateProcess(string app, string cmdline, IntPtr pa, IntPtr pt, bool inherit,
        uint creation, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, int len, COORD at, out int read);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD Size; public COORD MaxSize; public SMALL_RECT Window;
        public short CursorX; public short CursorY; public uint Attr; }

    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);

    // std — CONOUT$-ручка; возвращает код выхода детей или -err при ошибке запуска.
    public static int RunWithStd(string cmdline, IntPtr std, uint waitMs) {
        SetHandleInformation(std, 1, 1);   // HANDLE_FLAG_INHERIT — иначе у ребёнка ручка мусорная
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.dwFlags = 0x100;   // STARTF_USESTDHANDLES
        si.hStdInput = std; si.hStdOutput = std; si.hStdError = std;
        PROCESS_INFORMATION pi;
        if (!CreateProcess(null, cmdline, IntPtr.Zero, IntPtr.Zero, true, 0, IntPtr.Zero, null, ref si, out pi))
            return -Marshal.GetLastWin32Error();
        WaitForSingleObject(pi.hProcess, waitMs);
        uint code = 0; GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return (int)code;
    }
    // Клетки всего буфера → массив строк (правые пробелы отрезаны); $null при отказе.
    public static string[] ReadScreen(IntPtr h) {
        CONSOLE_SCREEN_BUFFER_INFO info;
        if (!GetConsoleScreenBufferInfo(h, out info)) return null;
        string[] lines = new string[info.Size.Y];
        char[] buf = new char[info.Size.X];
        for (int y = 0; y < info.Size.Y; y++) {
            COORD at = new COORD(); at.X = 0; at.Y = (short)y;
            int n;
            if (ReadConsoleOutputCharacterW(h, buf, info.Size.X, at, out n))
                lines[y] = new string(buf, 0, n).TrimEnd();
            else lines[y] = null;
        }
        return lines;
    }
}
'@
if (-not ('GreemonTestHost' -as [type])) { Add-Type -TypeDefinition $cs }

if ($Worker) {
    # --- рабочий: свой экран, размер, дочерний greemon, чтение буфера ---
    Set-Content -Path $InfoFile -Value 'start'
    $raw = $Host.UI.RawUI
    $cur = $raw.WindowSize
    # сначала уменьшить окно, затем буфер, затем окно до целевого размера
    $raw.WindowSize = New-Object System.Management.Automation.Host.Size(
        [Math]::Min($Width, $cur.Width), [Math]::Min($Height, $cur.Height))
    $raw.BufferSize = New-Object System.Management.Automation.Host.Size($Width, $Height)
    $raw.WindowSize = New-Object System.Management.Automation.Host.Size($Width, $Height)
    $genRW = [Convert]::ToUInt32('C0000000', 16)
    $hcon = [GreemonTestHost]::CreateFileW('CONOUT$', $genRW, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($hcon -eq [IntPtr]::MinusOne) { exit 4 }
    $cmd = '"' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') +
        '" -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'src\greemon.ps1') + '" -Mock -Once'
    $childExit = [GreemonTestHost]::RunWithStd($cmd, $hcon, 60000)
    Add-Content -Path $InfoFile -Value ('CHILD_EXIT=' + $childExit)
    if ($childExit -ne 0) { exit 5 }
    $lines = [GreemonTestHost]::ReadScreen($hcon)
    if ($null -eq $lines) { exit 6 }
    Set-Content -Path $FrameFile -Value ($lines -join "`r`n") -Encoding UTF8
    exit 0
}

# --- раннер: поWorker-прогону на каждую пару размеров, затем проверки ---
$failures = @()
# ширина контента в кадре — по той же формуле, что Format-GreemonFrame (3.12):
# margin 2 (3 в классической консоли), legacy-кап 100, кап 110. Legacy-детект —
# копия Test-GreemonLegacyConsole(auto) из greemon.ps1: ребёнок наследует окружение.
$legacyConsole = -not [bool]($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:ConEmuANSI -or $env:ANSICON -or
    ($env:TERM -and $env:TERM -match '^(xterm|screen|tmux|vt)'))
function Expected-ContentWidth { param([int]$W)
    $m = 2; if ($legacyConsole) { $m = 3 }
    $w = $W - $m
    if ($w -lt 30) { $w = 30 }
    if ($legacyConsole -and $w -gt 100) { $w = 100 }
    if ($w -gt 110) { $w = 110 }
    return $w
}
function Step { param([bool]$Cond, [string]$Name)
    if ($Cond) { Write-Output ('PASS: ' + $Name) }
    else { Write-Output ('FAIL: ' + $Name); $script:failures += $Name }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('greemon71_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
for ($i = 0; $i -lt $Sizes.Count; $i += 2) {
    $W = $Sizes[$i]; $H = $Sizes[$i + 1]
    $frame = Join-Path $tmp ('frame_' + $W + 'x' + $H + '.txt')
    $info = Join-Path $tmp ('info_' + $W + 'x' + $H + '.txt')
    $errf = Join-Path $tmp ('stderr_' + $W + 'x' + $H + '.txt')
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Self,
        '-Worker', '-Width', $W, '-Height', $H, '-FrameFile', $frame, '-InfoFile', $info
    ) -WindowStyle Hidden -RedirectStandardError $errf -Wait -PassThru
    Step ($p.ExitCode -eq 0) ('кадр ' + $W + 'x' + $H + ' получен (worker exit=0, child exit=0)')
    if ($p.ExitCode -ne 0) { continue }
    $text = @(Get-Content $frame -Encoding UTF8)
    # без исключений: в кадре нет хвостов сообщений PowerShell
    $joined = $text -join "`n"
    Step (-not ($joined -match 'FullyQualified|ParserError|Exception')) ('кадр ' + $W + 'x' + $H + ' без сообщений об ошибках')
    # не сработала защита «окно слишком маленькое»
    Step (-not ($joined -match 'слишком маленькое')) ('кадр ' + $W + 'x' + $H + ': не сработала минимальная граница 78x23')
    # размер окна применён: самая длинная строка кадра = ширина контента по формуле
    # Format-GreemonFrame (min(W − margin, 110, legacy-кап 100)); при откате на
    # типовые 112×32 длина была бы другой. Строка заголовка при высоте кадра > H
    # уходит за край прокруткой (-Once пишет кадр в поток, см. NOTES.md), поэтому
    # проверяется не первая строка, а максимальная.
    $cw = Expected-ContentWidth -W $W
    $maxLen = 0
    foreach ($ln in $text) { if ($ln.Length -gt $maxLen) { $maxLen = $ln.Length } }
    Step ($maxLen -eq $cw) ('кадр ' + $W + 'x' + $H + ': самая длинная строка = ' + $cw + ' (размер окна применён)')
    Step (@($text | Where-Object { $_ -match 'Read only\s+\|\s+q quits' }).Count -ge 1) ('кадр ' + $W + 'x' + $H + ': строка «Read only  |  q quits»')
    foreach ($label in @('Speed', 'GPU load', 'VRAM', 'GPU temp', 'Power', 'PCIe', 'CPU', 'Disk read', 'Context fill', 'System RAM')) {
        Step ($joined -match ('(?m)^.*\b' + [regex]::Escape($label) + '\b.*$')) ('кадр ' + $W + 'x' + $H + ': подпись «' + $label + '»')
    }
    $stderr = ''
    if (Test-Path $errf) { $stderr = (Get-Content $errf -Raw) }
    Step ([string]::IsNullOrWhiteSpace($stderr)) ('worker ' + $W + 'x' + $H + ': stderr пуст')
}
Remove-Item -Recurse -Force $tmp
if ($failures.Count -gt 0) {
    Write-Output ('ИТОГО: провалено ' + $failures.Count)
    exit 1
}
Write-Output 'ИТОГО: все проверки 7.1 пройдены'
exit 0
