@echo off
reg add "HKLM\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v ExecutionPolicy /t REG_SZ /d RemoteSigned /f >nul 2>&1
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -File "%~dp0orchestrator.ps1"
exit /b 0