@echo off
setlocal enabledelayedexpansion

:: ===== Konfiguration =====
set SERVICE_NAME=Alamos2Fireplan
set PROJECT_DIR=%~dp0
set NSSM_PATH=%PROJECT_DIR%tools\nssm.exe
set PYTHON_EXEC=%PROJECT_DIR%tools\python\python.exe
set VENV_DIR=%PROJECT_DIR%venv
set VENV_PYTHON=%VENV_DIR%\Scripts\python.exe
set SCRIPT_PATH=%PROJECT_DIR%runserver.py

echo ---------------------------------------
echo   Alamos2Fireplan - Dienst Installer
echo ---------------------------------------

:: ===== Benutzer bestätigen lassen =====
set /p USER_CONFIRM="Möchtest du den Dienst installieren? (j/n): "
if /I not "!USER_CONFIRM!"=="j" (
    echo [INFO] Installation abgebrochen.
    exit /b 0
)

:: ===== Prüfen: Portable Python vorhanden? =====
if not exist "%PYTHON_EXEC%" (
    echo [FEHLER] Python nicht gefunden unter: %PYTHON_EXEC%
    pause
    exit /b 1
)

:: ===== Virtuelle Umgebung einrichten =====
if not exist "%VENV_DIR%" (
    echo [INFO] Erstelle virtuelle Umgebung mit portablem Python ...
    "%PYTHON_EXEC%" -m venv "%VENV_DIR%"
    if errorlevel 1 (
        echo [FEHLER] Konnte virtuelle Umgebung nicht erstellen. Fehlt venv-Modul?
        pause
        exit /b 1
    )
) else (
    echo [INFO] Virtuelle Umgebung existiert bereits.
)

:: ===== Dependencies installieren =====
echo [INFO] Installiere Abhängigkeiten ...
call "%VENV_DIR%\Scripts\activate.bat"
"%VENV_PYTHON%" -m pip install --upgrade pip
if errorlevel 1 (
    echo [FEHLER] pip konnte nicht aktualisiert werden.
    pause
    exit /b 1
)
"%VENV_PYTHON%" -m pip install -r requirements.txt
if errorlevel 1 (
    echo [FEHLER] Anforderungen aus requirements.txt konnten nicht installiert werden.
    pause
    exit /b 1
)

:: ===== pywin32 postinstall (falls nötig) =====
if exist "%VENV_DIR%\Lib\site-packages\pywin32_postinstall.py" (
    echo [INFO] Führe pywin32_postinstall aus ...
    "%VENV_PYTHON%" "%VENV_DIR%\Lib\site-packages\pywin32_postinstall.py" -install
)

:: ===== NSSM prüfen =====
if not exist "%NSSM_PATH%" (
    echo [FEHLER] NSSM nicht gefunden unter: %NSSM_PATH%
    pause
    exit /b 1
)

:: ===== Dienst registrieren =====
echo [INFO] (Neu-)Installation Dienst "%SERVICE_NAME%" ...
"%NSSM_PATH%" stop %SERVICE_NAME% >nul 2>&1
"%NSSM_PATH%" remove %SERVICE_NAME% confirm >nul 2>&1

"%NSSM_PATH%" install %SERVICE_NAME% "%VENV_PYTHON%" "%SCRIPT_PATH%"
"%NSSM_PATH%" set %SERVICE_NAME% AppDirectory "%PROJECT_DIR:~0,-1%"
"%NSSM_PATH%" set %SERVICE_NAME% Start SERVICE_AUTO_START
"%NSSM_PATH%" set %SERVICE_NAME% ObjectName "LocalSystem"


:: ===== Dienst starten =====
echo [INFO] Starte Dienst "%SERVICE_NAME%" ...
"%NSSM_PATH%" start %SERVICE_NAME%

echo ---------------------------------------
echo ✅ Dienst "%SERVICE_NAME%" wurde erfolgreich installiert und gestartet!
pause
endlocal
