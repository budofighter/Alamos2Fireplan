@echo off
setlocal enabledelayedexpansion

:: ===== Konfiguration =====
set SERVICE_NAME=Alamos2Fireplan
set PROJECT_DIR=%~dp0
set NSSM_PATH=%PROJECT_DIR%tools\nssm.exe
set VENV_DIR=%PROJECT_DIR%venv

echo ---------------------------------------
echo   Alamos2Fireplan - Dienst Deinstallation
echo ---------------------------------------

:: ===== Bestätigung durch Nutzer =====
set /p USER_CONFIRM="Möchtest du den Dienst '%SERVICE_NAME%' wirklich entfernen? (j/n): "
if /I not "!USER_CONFIRM!"=="j" (
    echo [INFO] Deinstallation abgebrochen.
    exit /b 0
)

:: ===== NSSM prüfen =====
if not exist "%NSSM_PATH%" (
    echo [FEHLER] NSSM nicht gefunden unter: %NSSM_PATH%
    pause
    exit /b 1
)

:: ===== Dienst stoppen =====
echo [INFO] Stoppe Dienst "%SERVICE_NAME%" ...
"%NSSM_PATH%" stop %SERVICE_NAME% >nul 2>&1

:: ===== Dienst entfernen =====
echo [INFO] Entferne Dienst "%SERVICE_NAME%" ...
"%NSSM_PATH%" remove %SERVICE_NAME% confirm >nul 2>&1

:: ===== Option: Virtuelle Umgebung löschen =====
if exist "%VENV_DIR%" (
    set /p DELETE_VENV="Virtuelle Umgebung '%VENV_DIR%' löschen? (j/n): "
    if /I "!DELETE_VENV!"=="j" (
        echo [INFO] Lösche virtuelle Umgebung ...
        rmdir /s /q "%VENV_DIR%"
    ) else (
        echo [INFO] Virtuelle Umgebung bleibt erhalten.
    )
)

echo ---------------------------------------
echo ✅ Dienst wurde entfernt.
pause
endlocal
