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
if "%APP_VERSION%"=="" (set "ERRMSG=Version nicht aus config.py lesbar." & goto :fail)
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
if not exist "tools\nssm.exe" (set "ERRMSG=tools\nssm.exe fehlt - kann nicht ins Paket kopiert werden." & goto :fail)
copy tools\nssm.exe "%TEMP_FOLDER%\tools\" >nul

:: ---- Embeddable Python bündeln ----
echo [INFO] Lade Embeddable Python %PY_VERSION% ...
powershell -NoProfile -Command "try { Invoke-WebRequest -Uri '%PY_URL%' -OutFile '%TEMP_FOLDER%\py.zip' -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (set "ERRMSG=Python-Download fehlgeschlagen. Existiert Version %PY_VERSION%? URL: %PY_URL%" & goto :fail)

powershell -NoProfile -Command "try { Expand-Archive -Path '%TEMP_FOLDER%\py.zip' -DestinationPath '%TEMP_FOLDER%\tools\python' -Force -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (set "ERRMSG=Entpacken des Embeddable-Python-Archivs fehlgeschlagen." & goto :fail)
del "%TEMP_FOLDER%\py.zip" >nul

:: ._pth anpassen: 'import site' aktivieren (fuer site-packages) UND die App-Wurzel
:: (..\.. relativ zu tools\python) aufnehmen, damit das gebuendelte Python die
:: lokalen Pakete app/backend/config findet. Ohne diese Zeile bricht runserver.py
:: mit "ModuleNotFoundError: No module named 'app'" ab (Embeddable-Python legt das
:: Skriptverzeichnis NICHT automatisch auf sys.path).
powershell -NoProfile -Command "try { $p = Get-ChildItem '%TEMP_FOLDER%\tools\python\python*._pth' | Select-Object -First 1; if (-not $p) { exit 1 }; $c = (Get-Content $p.FullName) -replace '#\s*import site','import site'; $c += '..\..'; Set-Content -LiteralPath $p.FullName -Value $c -Encoding ASCII } catch { exit 1 }"
if errorlevel 1 (set "ERRMSG=Anpassen der ._pth-Datei (import site + App-Wurzel) fehlgeschlagen." & goto :fail)

echo [INFO] Richte pip ein ...
powershell -NoProfile -Command "try { Invoke-WebRequest -Uri '%GETPIP_URL%' -OutFile '%TEMP_FOLDER%\tools\python\get-pip.py' -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (set "ERRMSG=Download von get-pip.py fehlgeschlagen." & goto :fail)

"%TEMP_FOLDER%\tools\python\python.exe" "%TEMP_FOLDER%\tools\python\get-pip.py" --no-warn-script-location
if errorlevel 1 (set "ERRMSG=pip-Installation (get-pip) fehlgeschlagen." & goto :fail)

"%TEMP_FOLDER%\tools\python\python.exe" -m pip install -r "%TEMP_FOLDER%\requirements.txt" --no-warn-script-location
if errorlevel 1 (set "ERRMSG=pip install der requirements fehlgeschlagen." & goto :fail)

:: ---- __pycache__ entfernen ----
for /d /r "%TEMP_FOLDER%" %%d in (__pycache__) do if exist "%%d" rmdir /s /q "%%d"

:: ---- Selbsttest: laedt das gebuendelte Python alle Abhaengigkeiten? ----
echo [INFO] Selbsttest: importiere Abhaengigkeiten im gebuendelten Python ...
"%TEMP_FOLDER%\tools\python\python.exe" -c "import flask, paho.mqtt.client, cerberus, requests, dotenv, pytz"
if errorlevel 1 (set "ERRMSG=Selbsttest fehlgeschlagen - Abhaengigkeiten im gebuendelten Python nicht importierbar. Kein Paket erstellt." & goto :fail)
echo [OK] Selbsttest bestanden.

:: ---- ZIP erstellen ----
set ZIP_FILE=%OUTPUT_DIR%%ZIP_NAME%_v%APP_VERSION%.zip
if exist "%ZIP_FILE%" del "%ZIP_FILE%"
echo [INFO] Erstelle ZIP: %ZIP_FILE%
powershell -NoProfile -Command "try { Compress-Archive -Path '%TEMP_FOLDER%\*' -DestinationPath '%ZIP_FILE%' -Force -CompressionLevel Optimal -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (set "ERRMSG=ZIP-Erstellung fehlgeschlagen." & goto :fail)
if not exist "%ZIP_FILE%" (set "ERRMSG=ZIP-Datei wurde nicht erstellt." & goto :fail)

rmdir /s /q "%TEMP_FOLDER%"
echo.
echo [OK] Paket erfolgreich erstellt: %ZIP_FILE%
pause
endlocal
exit /b 0

:fail
echo.
echo [FEHLER] %ERRMSG%
if exist "%TEMP_FOLDER%" rmdir /s /q "%TEMP_FOLDER%"
pause
endlocal
exit /b 1
