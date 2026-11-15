# Проверка roadmap 7.5: после выхода greemon (клавиша q) — курсор виден, основной
# экран цел, кодировка консоли восстановлена, процессов-сирот nvidia-smi нет.
#
# Механизм (тот же, что 7.1): рабочий в новой скрытой conhost-сессии (свой
# настоящий экран). Рабочий: печатает маркер на основной экран; снимает состояние
# консоли (видимость курсора, кодовая страница вывода, режим экрана с флагом VT);
# открывает CONIN$/CONOUT$; запускает src\greemon.ps1 интерактивно (без -Once)
# с этими std-ручками; через выдержку пишет в консольный ввод нажатие «q»
# (WriteConsoleInput); ждёт выхода детей; снимает состояние повторно и читает
# клетки экрана. Кодировка проверяется кросспроцессно: кодовая страница вывода —
# свойство консоли, её меняет и обязан восстановить дочерний greemon.
#
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-exit-cleanup.ps1 [-DelaySec 18] [-TimeoutSec 90]
# Код возврата 0 — все проверки прошли.
param(
    [int]$DelaySec = 18,      # выдержка до нажатия q (старт PS + компиляция Add-Type)
    [int]$TimeoutSec = 90,    # общий предел ожидания выхода greemon
    # --- служебный режим рабочего процесса ---
    [switch]$Worker,
    [string]$InfoFile = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:Self = Join-Path $PSScriptRoot 'test-exit-cleanup.ps1'

# Консольные Win32-вызовы целиком на C# (маршалинг STARTUPINFO из PS 5.1 ломается,
# см. NOTES.md фаза 7). WriteConsoleInput — классический KEY_EVENT_RECORD (16 байт).
$cs = @'
using System;
using System.Runtime.InteropServices;
public static class GreemonExitHost {
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
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetConsoleOutputCP();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [StructLayout(LayoutKind.Sequential)]
    public struct CONSOLE_CURSOR_INFO { public uint dwSize; [MarshalAs(UnmanagedType.Bool)] public bool bVisible; }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleCursorInfo(IntPtr h, out CONSOLE_CURSOR_INFO info);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, int len, COORD at, out int read);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool WriteConsoleOutputCharacterW(IntPtr h, string s, int len, COORD at, out int written);
    public static bool WriteScreenText(IntPtr h, int x, int y, string s) {
        COORD at = new COORD(); at.X = (short)x; at.Y = (short)y; int n;
        return WriteConsoleOutputCharacterW(h, s, s.Length, at, out n);
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD Size; public COORD MaxSize; public SMALL_RECT Window;
        public short CursorX; public short CursorY; public uint Attr; }

    [StructLayout(LayoutKind.Sequential)]
    struct KEY_EVENT_RECORD {
        [MarshalAs(UnmanagedType.Bool)] public bool bKeyDown;
        public ushort wRepeatCount; public ushort wVirtualKeyCode; public ushort wVirtualScanCode;
        public char UnicodeChar; public uint dwControlKeyState;
    }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUT_UNION { [FieldOffset(0)] public KEY_EVENT_RECORD KeyEvent; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT_RECORD { public ushort EventType; public ushort Pad; public INPUT_UNION Union; }
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] recs, int len, out int written);

    // Нажатие+отпускание символа в консольный ввод (EventType=1 = KEY_EVENT).
    public static bool SendKey(IntPtr hIn, char ch, ushort vk) {
        INPUT_RECORD[] recs = new INPUT_RECORD[2];
        recs[0].EventType = 1; recs[0].Union.KeyEvent.bKeyDown = true;
        recs[0].Union.KeyEvent.UnicodeChar = ch; recs[0].Union.KeyEvent.wVirtualKeyCode = vk;
        recs[0].Union.KeyEvent.wRepeatCount = 1;
        recs[1].EventType = 1; recs[1].Union.KeyEvent.bKeyDown = false;
        recs[1].Union.KeyEvent.UnicodeChar = ch; recs[1].Union.KeyEvent.wVirtualKeyCode = vk;
        int written;
        return WriteConsoleInputW(hIn, recs, 2, out written) && written == 2;
    }

    // Запуск детей с отдельными stdin/stdout; возвращает PROCESS_INFORMATION-код через out-параметры.
    public static IntPtr SpawnWithStd(string cmdline, IntPtr hIn, IntPtr hOut) {
        SetHandleInformation(hIn, 1, 1); SetHandleInformation(hOut, 1, 1);   // HANDLE_FLAG_INHERIT
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.dwFlags = 0x100;   // STARTF_USESTDHANDLES
        si.hStdInput = hIn; si.hStdOutput = hOut; si.hStdError = hOut;
        PROCESS_INFORMATION pi;
        if (!CreateProcess(null, cmdline, IntPtr.Zero, IntPtr.Zero, true, 0, IntPtr.Zero, null, ref si, out pi))
            return IntPtr.Zero;
        return pi.hProcess;
    }
    public static uint WaitExit(IntPtr hProc, uint ms) {   // 259 = STILL_ACTIVE при таймауте
        WaitForSingleObject(hProc, ms);
        uint code; if (!GetExitCodeProcess(hProc, out code)) return 0xFFFFFFF;
        return code;
    }
    public static void ForceKill(IntPtr hProc) { TerminateProcess(hProc, 42); }
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
    public static uint OutCP { get { return GetConsoleOutputCP(); } }
    public static uint GetMode(IntPtr h) { uint m; return GetConsoleMode(h, out m) ? m : 0xFFFFFFFF; }
    public static int CursorVisible(IntPtr h) {
        CONSOLE_CURSOR_INFO ci;
        if (!GetConsoleCursorInfo(h, out ci)) return -1;
        return ci.bVisible ? 1 : 0;
    }
}
'@
if (-not ('GreemonExitHost' -as [type])) { Add-Type -TypeDefinition $cs }

if ($Worker) {
    # --- рабочий: свой экран, снимки состояния, дочерний greemon, «q», повторные снимки ---
    $linesOut = @()
    $raw = $Host.UI.RawUI
    $cur = $raw.WindowSize
    $raw.WindowSize = New-Object System.Management.Automation.Host.Size(
        [Math]::Min(100, $cur.Width), [Math]::Min(30, $cur.Height))
    $raw.BufferSize = New-Object System.Management.Automation.Host.Size(100, 30)
    $raw.WindowSize = New-Object System.Management.Automation.Host.Size(100, 30)
    # Маркер пишем сразу в клетки экранного буфера (WriteScreenText): у скрытого
    # worker'а stdout — pipe (унаследован), и Write-Host ушёл бы в pipe, а не на
    # экран (проверено). После «q» и выхода greemon маркер обязан остаться на
    # основном экране.
    $genRW = [Convert]::ToUInt32('C0000000', 16)
    $hOut = [GreemonExitHost]::CreateFileW('CONOUT$', $genRW, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $hIn = [GreemonExitHost]::CreateFileW('CONIN$', $genRW, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($hOut -eq [IntPtr]::MinusOne -or $hIn -eq [IntPtr]::MinusOne) { exit 4 }
    $null = [GreemonExitHost]::WriteScreenText($hOut, 1, 27, 'GREEMON75-MAIN-MARKER')
    $cpBefore = [GreemonExitHost]::OutCP
    $modeBefore = [GreemonExitHost]::GetMode($hOut)
    $cursorBefore = [GreemonExitHost]::CursorVisible($hOut)
    $cmd = '"' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') +
        '" -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'src\greemon.ps1') + '"'
    $hProc = [GreemonExitHost]::SpawnWithStd($cmd, $hIn, $hOut)
    if ($hProc -eq [IntPtr]::Zero) { exit 5 }
    Start-Sleep -Seconds $DelaySec
    $sent = [GreemonExitHost]::SendKey($hIn, [char]'q', [uint16]0x51)
    $code = [GreemonExitHost]::WaitExit($hProc, [uint32]($TimeoutSec * 1000))
    $killed = $false
    if ($code -eq 259) { [GreemonExitHost]::ForceKill($hProc); $killed = $true }
    Start-Sleep -Milliseconds 700    # последние VT-последовательности finally должны примениться
    # CONOUT$ переоткрываем заново: после 1049h/l он должен указывать на основной
    # экран; снимки «после» снимаем со свежегоhandles, а не сhandle'а до запуска
    $hOut2 = [GreemonExitHost]::CreateFileW('CONOUT$', $genRW, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($hOut2 -eq [IntPtr]::MinusOne) { $hOut2 = $hOut }
    $cpAfter = [GreemonExitHost]::OutCP
    $modeAfter = [GreemonExitHost]::GetMode($hOut2)
    $cursorAfter = [GreemonExitHost]::CursorVisible($hOut2)
    $screen = [GreemonExitHost]::ReadScreen($hOut2)
    $smi = @(Get-Process -Name nvidia-smi -ErrorAction SilentlyContinue).Count
    $linesOut += ('CHILD_EXIT=' + $code)
    $linesOut += ('KILLED=' + [int]$killed)
    $linesOut += ('KEY_SENT=' + [int]$sent)
    $linesOut += ('CP_BEFORE=' + $cpBefore)
    $linesOut += ('CP_AFTER=' + $cpAfter)
    $linesOut += ('MODE_BEFORE=' + $modeBefore)
    $linesOut += ('MODE_AFTER=' + $modeAfter)
    $linesOut += ('CURSOR_BEFORE=' + $cursorBefore)
    $linesOut += ('CURSOR_AFTER=' + $cursorAfter)
    $linesOut += ('SMI_PROCS=' + $smi)
    if ($null -ne $screen) { Set-Content -Path ($InfoFile + '.screen') -Value ($screen -join "`r`n") -Encoding UTF8 }
    Set-Content -Path $InfoFile -Value ($linesOut -join "`r`n") -Encoding UTF8
    exit 0
}

# --- раннер: один worker-прогон, разбор ключей, проверки ---
$failures = @()
function Step { param([bool]$Cond, [string]$Name)
    if ($Cond) { Write-Output ('PASS: ' + $Name) }
    else { Write-Output ('FAIL: ' + $Name); $script:failures += $Name }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('greemon75_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
$info = Join-Path $tmp 'info.txt'
$errf = Join-Path $tmp 'stderr.txt'
$outf = Join-Path $tmp 'stdout.txt'
$p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Self, '-Worker', '-InfoFile', $info
) -WindowStyle Hidden -RedirectStandardError $errf -RedirectStandardOutput $outf -Wait -PassThru
Step ($p.ExitCode -eq 0) ('worker отработал (exit=' + $p.ExitCode + ')')
if ($p.ExitCode -eq 0) {
    $kv = @{}
    foreach ($ln in (Get-Content $info -Encoding UTF8)) {
        $t = $ln.Split('='); if ($t.Count -eq 2) { $kv[$t[0]] = $t[1] }
    }
    Step ($kv['KEY_SENT'] -eq '1') ('нажатие q доставлено в консольный ввод (WriteConsoleInput)')
    Step ($kv['KILLED'] -eq '0' -and $kv['CHILD_EXIT'] -eq '0') ('greemon вышел по q сам, код 0 (не убит: exit=' + $kv['CHILD_EXIT'] + ')')
    Step ($kv['CURSOR_AFTER'] -eq '1') ('после выхода курсор виден (было до: ' + $kv['CURSOR_BEFORE'] + ', стало: ' + $kv['CURSOR_AFTER'] + ')')
    Step ($kv['CP_AFTER'] -eq $kv['CP_BEFORE']) ('кодовая страница вывода восстановлена (' + $kv['CP_BEFORE'] + ' → ' + $kv['CP_AFTER'] + ')')
    $vt = 0x0004   # ENABLE_VIRTUAL_TERMINAL_PROCESSING
    $modeAfter = [uint32]$kv['MODE_AFTER']; $modeBefore = [uint32]$kv['MODE_BEFORE']
    Step ($modeAfter -eq $modeBefore) ('режим экрана восстановлен (до=' + $modeBefore + ', после=' + $modeAfter + ', VT-флаг не оставлен)')
    $screenFile = $info + '.screen'
    $screen = ''
    if (Test-Path $screenFile) { $screen = (Get-Content $screenFile -Encoding UTF8 -Raw) }
    Step ($screen -match 'GREEMON75-MAIN-MARKER') ('основной экран цел: маркер рабочего виден после выхода')
    Step (-not ($screen -match 'GREEMON|Overview|GPU load')) ('основной экран цел: кадр greemon на нём не остался')
    Step ($kv['SMI_PROCS'] -eq '0') ('нет процессов-сирот nvidia-smi (найдено: ' + $kv['SMI_PROCS'] + ')')
}
Remove-Item -Recurse -Force $tmp
if ($failures.Count -gt 0) {
    Write-Output ('ИТОГО: провалено ' + $failures.Count)
    exit 1
}
Write-Output 'ИТОГО: все проверки 7.5 пройдены'
exit 0
