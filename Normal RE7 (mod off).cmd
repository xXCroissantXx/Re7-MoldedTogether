@echo off
rem Double-click to switch Molded Together off in RE7's Steam folder, so the game starts normally from Steam.
rem Your co-op settings stay; "Install into Steam.cmd" switches it back on.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-coop-re7.ps1" -SteamFolder -Disable %*
echo.
pause
