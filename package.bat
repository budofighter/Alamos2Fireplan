@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set OUTPUT_DIR=%~dp0
set ZIP_NAME=Alamos2Fireplan
set CONFIG_FILE=%OUTPUT_DIR%config\config.py
set TEMP_FOLDER=%OUTPUT_DIR%__package_tmp__
set PY_VERSION=3.13.14
set PY_URL=https://www.python.org/ftp/python/%PY_VERSION%/python-%PY_VERSION%-embed-amd64.zip
set GETPIP_URL=https://bootstrap.pypa.io/get-pip.py

:: ---- Version aus config.py ----
for /f "tokens=2 delims== " %%A in ('findstr /b "APP_VERSION" "%CONFIG_FILE%"') do set "VERSION_RAW=%%A"
set "APP_VERSION=%VERSION_RAW:"=%"
set "APP_VERSION=%APP_VERSION: =%"
if "%APP_VERSION%"=="" (echo [FEHLER] Version nicht lesbar & pause & exit /b 1)
echo [INFO] Verpacke Version: %APP_VERSION%

:: ---- Temp vorbereiten ----
if exist "%TEMP_FOLDER%" rmdir /s /q "%TEMP_FOLDER%"
mkdir "%TEMP_FOLDER%"

:: ---- Code kopieren ----
xcopy app "%TEMP_FOLDER%\app" /E /I /Y >nul
xcopy backend "%TEMP_FOLDER%\backend" /E /I /Y >nul
xcopy config "%TEMP_FOLDER%\config" /E /I /Y >nul
del "%TEMP_FOLDER%\config\*.json" >nul 2>&1
del "%TEMP_FOLDER%\config\.env" >nul 2>&1
copy runserver.py "%TEMP_FOLDER%" >nul
copy requirements.txt "%TEMP_FOLDER%" >nul
copy setup.ps1 "%TEMP_FOLDER%" >nul
copy setup.lib.ps1 "%TEMP_FOLDER%" >nul
copy install.bat "%TEMP_FOLDER%" >nul
copy update.bat "%TEMP_FOLDER%" >nul
copy uninstall.bat "%TEMP_FOLDER%" >nul

:: ---- tools (ohne bestehendes python) ----
xcopy tools "%TEMP_FOLDER%\tools" /E /I /Y /EXCLUDE:%OUTPUT_DIR%package_exclude.txt >nul 2>&1
if not exist "%TEMP_FOLDER%\tools" mkdir "%TEMP_FOLDER%\tools"
copy tools\nssm.exe "%TEMP_FOLDER%\tools\" >nul

:: ---- Embeddable Python bündeln ----
echo [INFO] Lade Embeddable Python %PY_VERSION% ...
powershell -NoProfile -Command "Invoke-WebRequest -Uri '%PY_URL%' -OutFile '%TEMP_FOLDER%\py.zip'"
powershell -NoProfile -Command "Expand-Archive -Path '%TEMP_FOLDER%\py.zip' -DestinationPath '%TEMP_FOLDER%\tools\python' -Force"
del "%TEMP_FOLDER%\py.zip" >nul
:: ._pth: 'import site' aktivieren
powershell -NoProfile -Command "$p = Get-ChildItem '%TEMP_FOLDER%\tools\python\python*._pth' | Select-Object -First 1; (Get-Content $p.FullName) -replace '#\s*import site','import site' | Set-Content $p.FullName -Encoding ASCII"
echo [INFO] Richte pip ein ...
powershell -NoProfile -Command "Invoke-WebRequest -Uri '%GETPIP_URL%' -OutFile '%TEMP_FOLDER%\tools\python\get-pip.py'"
"%TEMP_FOLDER%\tools\python\python.exe" "%TEMP_FOLDER%\tools\python\get-pip.py" --no-warn-script-location
"%TEMP_FOLDER%\tools\python\python.exe" -m pip install -r "%TEMP_FOLDER%\requirements.txt" --no-warn-script-location

:: ---- __pycache__ entfernen ----
for /d /r "%TEMP_FOLDER%" %%d in (__pycache__) do if exist "%%d" rmdir /s /q "%%d"

:: ---- ZIP erstellen ----
set ZIP_FILE=%OUTPUT_DIR%%ZIP_NAME%_v%APP_VERSION%.zip
if exist "%ZIP_FILE%" del "%ZIP_FILE%"
echo [INFO] Erstelle ZIP: %ZIP_FILE%
powershell -NoProfile -Command "Compress-Archive -Path '%TEMP_FOLDER%\*' -DestinationPath '%ZIP_FILE%' -Force -CompressionLevel Optimal"

if exist "%ZIP_FILE%" (echo [OK] Paket erstellt: %ZIP_FILE%) else (echo [FEHLER] ZIP fehlgeschlagen)
rmdir /s /q "%TEMP_FOLDER%"
pause
endlocal
