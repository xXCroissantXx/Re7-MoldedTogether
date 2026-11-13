@echo off
rem Double-click to install (or update) Molded Together into RE7's own Steam folder: afterwards pressing Play
rem in Steam starts the mod. "Normal RE7 (mod off).cmd" switches it off again. Runs install-coop-re7.ps1 with
rem this run's script policy relaxed (Windows blocks downloaded scripts by default).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-coop-re7.ps1" %*
echo.
pause
