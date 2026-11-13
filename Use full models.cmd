@echo off
rem Double-click (with the game closed) after downloading "Third Person Full Model Placeholders" (Nexus RE7
rem mod 86) into Downloads: sets its models up for the co-op lobby only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0use-full-models.ps1" %*
echo.
pause
