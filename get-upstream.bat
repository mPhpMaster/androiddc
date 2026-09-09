@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0get-upstream.ps1" %*
