@echo off
set "LUAJIT=C:\tools\luajit\luajit.exe"
if not exist "%LUAJIT%" set "LUAJIT=luajit"
"%LUAJIT%" "%~dp0bin\hs_cli.lua" %*
exit /b %ERRORLEVEL%
