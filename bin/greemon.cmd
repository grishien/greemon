@echo off
rem greemon launcher: runs src\greemon.ps1 located next to this folder.
rem Target shell: Windows PowerShell 5.1 (see roadmap.md).
setlocal
set "GREEMON_PS1=%~dp0..\src\greemon.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%GREEMON_PS1%" %*
endlocal & exit /b %errorlevel%
