@echo off
"%~dp0runtime\lua.exe" -E "%~dp0bin\hs_cli.lua" %*
exit /b %ERRORLEVEL%
