@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0gnirehtet-share.ps1" ^
  -PauseOnError %*
