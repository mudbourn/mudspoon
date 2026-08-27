@echo off
rem Stop the windowless mudspoon host. Because it runs with no window, this is the
rem clean way to quit it from outside (the app's own menubar quit also works).
rem Kills only luajit processes running run_mudscript.lua -- nothing else.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1"
