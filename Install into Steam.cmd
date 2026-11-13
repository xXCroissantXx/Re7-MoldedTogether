@echo off
rem Double-click to install Molded Together into RE7's own Steam folder (no copy of the game):
rem then pressing Play in Steam starts the mod. "Normal RE7 (mod off).cmd" switches it off again.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-coop-re7.ps1" -SteamFolder %*
echo.
pause
