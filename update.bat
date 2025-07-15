@echo off
setlocal enabledelayedexpansion

title Alamos2Fireplan - Update
echo ---------------------------------------
echo    🔄 Update Alamos2Fireplan starten
echo ---------------------------------------

:: ==== KONFIGURATION =====
set SERVICE_NAME=Alamos2Fireplan
set VENV_DIR=venv
set REQUIREMENTS=requirements.txt

:: ==== Benutzer nach Zielverzeichnis fragen ====
echo.
set /p TARGET_DIR=Bitte gib den Installationspfad an (z. B. C:\Alamos2Fireplan): 
if not exist "!TARGET_DIR!" (
    echo [FEHLER] Zielverzeichnis existiert nicht!
    pause
    exit /b 1
)

:: ==== Dienst stoppen ====
echo.
echo [1/5] Stoppe Dienst "%SERVICE_NAME%" (falls vorhanden)...
nssm stop %SERVICE_NAME% >nul 2>&1

:: ==== Dateien kopieren ====
echo.
echo [2/5] Kopiere Dateien ins Zielverzeichnis...
xcopy * "!TARGET_DIR!\" /E /I /Y /EXCLUDE:update.bat

:: ==== Python-Abhängigkeiten aktualisieren (optional) ====
if exist "!TARGET_DIR!\%VENV_DIR%\Scripts\activate.bat" (
    echo.
    echo [3/5] Aktualisiere Python-Abhängigkeiten...
    call "!TARGET_DIR!\%VENV_DIR%\Scripts\activate.bat"
    pip install -r "!TARGET_DIR!\%REQUIREMENTS%"
)

:: ==== Dienst neu starten ====
echo.
echo [4/5] Starte Dienst "%SERVICE_NAME%" neu...
nssm start %SERVICE_NAME% >nul 2>&1

echo.
echo ---------------------------------------
echo ✅ Update abgeschlossen!
pause
endlocal
