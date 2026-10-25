@echo off
rem Prefer PowerShell 7 (pwsh) when installed; fall back to the built-in 5.1.
setlocal
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"
start "" %PSEXE% -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0todo-hud.ps1"
endlocal
