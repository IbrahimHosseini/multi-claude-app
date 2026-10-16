@echo off
rem Double-click to open the claude-multi menu, or run: claude-multi.cmd <command> [args]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-multi.ps1" %*
if "%~1"=="" pause
