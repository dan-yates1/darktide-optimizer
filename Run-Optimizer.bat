@echo off
rem Double-click to run the Darktide Optimizer with the default (Performance) preset.
rem Close Darktide first. Windows will ask for administrator permission.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-Darktide.ps1" %*
