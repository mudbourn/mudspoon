@echo off
rem Double-click to start mudspoon (the Hammerspoon host) with its mudscript config.
rem First run auto-installs LuaJIT / WebView2 / a POSIX shell via winget, then boots
rem the host windowless. This console closes on its own; the host keeps running.
rem Flags pass straight through, e.g.  Mudspoon.cmd -Foreground  or  -NoWebview.
rem The webview boots on a DWM glass frame by default; pass -NoGlass to opt out.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" %*
