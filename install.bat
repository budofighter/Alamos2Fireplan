@echo off
chcp 65001 >nul
title Alamos2Fireplan - Installation / Update

:: Aus dem ZIP heraus gestartet? Dann fehlen die uebrigen Dateien.
if not exist "%~dp0setup.ps1" (
    echo.
    echo [FEHLER] setup.ps1 nicht gefunden.
    echo Bitte das ZIP zuerst vollstaendig entpacken ^(Rechtsklick ^> Alle extrahieren^)
    echo und install.bat aus dem entpackten Ordner starten.
    echo.
    pause
    exit /b 1
)

:: UAC-Elevation, falls nicht als Admin gestartet. Pfad per Umgebungsvariable
:: uebergeben -> keine Probleme mit Leerzeichen/Apostrophen im Ordnernamen.
net session >nul 2>&1
if %errorlevel% neq 0 (
    set "A2F_SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:A2F_SELF -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Mode install
set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (
    echo [OK] Vorgang erfolgreich abgeschlossen.
) else (
    echo [FEHLER] Vorgang fehlgeschlagen ^(Code %RC%^). Details siehe oben bzw. logs\setup.log.
)
echo.
pause
exit /b %RC%
