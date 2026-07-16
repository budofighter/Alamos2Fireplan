[CmdletBinding()]
param(
    [ValidateSet('install','uninstall')]
    [string]$Mode = 'install'
)

$ErrorActionPreference = 'Stop'

# ---- Konstanten ----
$ServiceName = 'Alamos2Fireplan'
$InstallDir  = 'C:\Alamos2Fireplan'          # fester Installationsort (Neuinstallation)
$ProjectDir  = $PSScriptRoot                  # entpacktes Paket = Quelle/Staging
$PythonExe   = Join-Path $ProjectDir 'tools\python\python.exe'
$LogDir      = Join-Path $ProjectDir 'logs'
$SetupLog    = Join-Path $LogDir 'setup.log'
$PwFile      = 'C:\ProgramData\Alamos2Fireplan\pwfile.txt'
$PyVersion   = '3.13.14'
$PyUrl       = "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-embed-amd64.zip"
$MosqVersion = '2.0.22'
$MosqUrl     = "https://mosquitto.org/files/binary/win64/mosquitto-$MosqVersion-install-windows-x64.exe"

# Vollstaendige Dateiliste fuer eine Neuinstallation (Code + gebuendeltes Python/NSSM).
$FreshItems  = @('app','backend','config','runserver.py','requirements.txt',
                 'setup.ps1','setup.lib.ps1','install.bat','uninstall.bat','tools')

# ---- Lib laden ----
. (Join-Path $ProjectDir 'setup.lib.ps1')

# ---- Logging ----
function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Add-Content -LiteralPath $SetupLog -Value $line -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Get-Nssm { return (Join-Path $ProjectDir 'tools\nssm.exe') }

function Invoke-Nssm {
    # Zentrale nssm-Huelle. Zwei Probleme werden hier abgefangen:
    #  1) nssm gibt UTF-16LE aus -> Windows PowerShell dekodiert mit NUL-Zeichen
    #     -> Ausgabe wird via Clear-NssmString bereinigt.
    #  2) nssm schreibt harmlose Meldungen (z. B. "Dienst nicht gestartet",
    #     "Can't open service") nach stderr. Unter $ErrorActionPreference='Stop'
    #     wuerde das einen terminierenden Fehler ausloesen. Daher lokal 'Continue'
    #     und stderr nach stdout mergen. Echte Fehler erkennt der Aufrufer ueber
    #     $LASTEXITCODE, nicht ueber Exceptions.
    # -NssmPath: explizite nssm.exe (fuer die Registrierung mit der Ziel-nssm,
    # damit die Dienst-Binaerdatei im Installationsordner liegt).
    # WICHTIG: $NssmArgs hat Position 0 (ValueFromRemainingArguments), damit
    # positionelle Aufrufe wie 'Invoke-Nssm get <svc> AppDirectory' NICHT ihr
    # erstes Wort an $NssmPath binden. $NssmPath ist dadurch nur benannt nutzbar.
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$NssmArgs,
        [string]$NssmPath
    )
    $nssm = if ($NssmPath) { $NssmPath } else { Get-Nssm }
    # EAP=Continue: nssm-stderr wird KEIN terminierender Fehler. Nur stdout
    # auswerten (2>$null), damit nssm-Fehlermeldungen die Ausgabe (z. B. den
    # AppDirectory-Pfad oder SERVICE_RUNNING) nicht verschmutzen. Echte Fehler
    # erkennt der Aufrufer ueber $LASTEXITCODE.
    $ErrorActionPreference = 'Continue'
    $raw = & $nssm @NssmArgs 2>$null | Out-String
    return (Clear-NssmString -Text $raw)
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Dieses Skript benoetigt Administratorrechte. Bitte install.bat/uninstall.bat als Administrator ausfuehren.'
    }
}

function Test-Python {
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        throw "Embeddable Python fehlt unter $PythonExe. Ist das Paket vollstaendig entpackt?"
    }
    & $PythonExe --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Python unter $PythonExe ist nicht lauffaehig." }
    return $true
}

function Copy-Element {
    # Kopiert Datei ODER Verzeichnis von $Src nach $Dst. Verzeichnisse werden mit
    # robocopy gespiegelt (ueberschreibt, verschachtelt NICHT in ein bestehendes
    # Ziel, wiederholt bei kurzzeitig gesperrten Dateien).
    param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Dst)
    if (Test-Path -LiteralPath $Src -PathType Container) {
        robocopy $Src $Dst /E /NFL /NDL /NJH /NJS /R:3 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Kopieren von '$Src' fehlgeschlagen (robocopy Code $LASTEXITCODE)." }
        $global:LASTEXITCODE = 0
    } else {
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
    }
}

function Remove-Service {
    Invoke-Nssm stop $ServiceName | Out-Null
    Invoke-Nssm remove $ServiceName confirm | Out-Null
    Write-Log "Vorhandener Dienst '$ServiceName' gestoppt/entfernt (falls vorhanden)."
}

function Install-Service {
    # Registriert den Dienst mit der nssm.exe IM Installationsordner, damit der
    # Dienst nicht von der (evtl. spaeter geloeschten) Staging-Kopie abhaengt.
    param([Parameter(Mandatory)][string]$Dir)
    $targetNssm = Join-Path $Dir 'tools\nssm.exe'
    $py         = Join-Path $Dir 'tools\python\python.exe'
    $run        = Join-Path $Dir 'runserver.py'
    $svcLogDir  = Join-Path $Dir 'logs'
    if (-not (Test-Path -LiteralPath $targetNssm)) { throw "NSSM fehlt unter $targetNssm." }
    if (-not (Test-Path -LiteralPath $svcLogDir)) { New-Item -ItemType Directory -Path $svcLogDir -Force | Out-Null }

    Remove-Service
    Invoke-Nssm -NssmPath $targetNssm install $ServiceName $py $run | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "nssm install schlug fehl (Code $LASTEXITCODE)." }
    Invoke-Nssm -NssmPath $targetNssm set $ServiceName AppDirectory $Dir | Out-Null
    Invoke-Nssm -NssmPath $targetNssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
    Invoke-Nssm -NssmPath $targetNssm set $ServiceName ObjectName LocalSystem | Out-Null
    Invoke-Nssm -NssmPath $targetNssm set $ServiceName AppStdout (Join-Path $svcLogDir 'service.log') | Out-Null
    Invoke-Nssm -NssmPath $targetNssm set $ServiceName AppStderr (Join-Path $svcLogDir 'service.log') | Out-Null
    Invoke-Nssm -NssmPath $targetNssm set $ServiceName AppRotateFiles 1 | Out-Null
    Invoke-Nssm -NssmPath $targetNssm set $ServiceName AppRotateBytes 1048576 | Out-Null
    Write-Log "Dienst '$ServiceName' registriert (Zielordner: $Dir, Logging -> logs\service.log)."
}

function Assert-ServiceStarted {
    $status = Invoke-Nssm status $ServiceName
    if ($status -notmatch 'SERVICE_RUNNING') {
        throw "Dienst '$ServiceName' laeuft nicht (Status: $status). Siehe logs\service.log im Installationsordner."
    }
    Write-Log "Dienst '$ServiceName' laeuft."
}

function Setup-Mosquitto {
    param([Parameter(Mandatory)][string]$Dir)
    try {
        $mosqDir = 'C:\Program Files\mosquitto'
        $mosqExe = Join-Path $mosqDir 'mosquitto.exe'
        $mosqPw  = Join-Path $mosqDir 'mosquitto_passwd.exe'
        $py      = Join-Path $Dir 'tools\python\python.exe'

        # 1. Installieren, falls nicht vorhanden (NSIS-Installer -> /S = lautlos)
        if (-not (Test-Path -LiteralPath $mosqExe)) {
            $installer = Join-Path $env:TEMP "mosquitto-install.exe"
            Write-Log "Lade Mosquitto herunter: $MosqUrl"
            $ProgressPreference = 'SilentlyContinue'   # ohne Fortschrittsbalken deutlich schneller
            Invoke-WebRequest -Uri $MosqUrl -OutFile $installer
            Write-Log 'Installiere Mosquitto (silent, ohne Rueckfragen)...'
            Start-Process -FilePath $installer -ArgumentList '/S' -Wait
        } else {
            Write-Log 'Mosquitto bereits installiert - nur Neukonfiguration.'
        }

        # 2. Credentials abfragen
        $user = Read-Host 'MQTT-Benutzername'
        $secure = Read-Host 'MQTT-Passwort' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) {
            Write-Log 'MQTT-Benutzername/Passwort leer - Mosquitto-Setup abgebrochen.' 'WARN'
            return
        }

        # 3. pwfile anlegen (Pfad ohne Leerzeichen)
        $pwDir = Split-Path $PwFile -Parent
        if (-not (Test-Path -LiteralPath $pwDir)) { New-Item -ItemType Directory -Path $pwDir -Force | Out-Null }
        & $mosqPw -b -c $PwFile $user $pass
        if ($LASTEXITCODE -ne 0) { throw "mosquitto_passwd schlug fehl (Code $LASTEXITCODE)." }
        Write-Log "MQTT-Benutzer '$user' angelegt."

        # 4. mosquitto.conf schreiben
        $conf = @(
            'allow_anonymous false',
            "password_file $PwFile",
            'listener 1883'
        )
        # UTF-8 OHNE BOM: WPS 5.1 wuerde mit -Encoding UTF8 ein BOM voranstellen,
        # das die erste conf-Zeile (allow_anonymous) fuer mosquitto unbrauchbar macht.
        [System.IO.File]::WriteAllLines((Join-Path $mosqDir 'mosquitto.conf'), $conf, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log 'mosquitto.conf geschrieben.'

        # 5. Dienst via NSSM registrieren. mosquittos eigener Windows-Dienst-Modus
        # ('run') laedt die mosquitto.conf nicht zuverlaessig (Arbeitsverzeichnis
        # System32 -> Broker laeuft, lauscht aber nicht), und 'run -c' bricht das
        # Dienst-Protokoll (Fehler 1053). NSSM startet stattdessen den bewiesenen
        # Vordergrund-Befehl 'mosquitto -c <config>' als sauberen Dienst.
        $a2fNssm  = Join-Path $Dir 'tools\nssm.exe'
        $mosqNssm = Join-Path $mosqDir 'nssm.exe'

        # Bestehenden mosquitto-Dienst (nativ oder NSSM) entfernen (Steuerbefehle
        # ueber die A2F-nssm, damit eine evtl. genutzte mosqNssm freigegeben wird).
        Invoke-Nssm -NssmPath $a2fNssm stop mosquitto | Out-Null
        Invoke-Nssm -NssmPath $a2fNssm remove mosquitto confirm | Out-Null
        Start-Sleep -Seconds 2

        # nssm.exe neben mosquitto legen, damit der Broker-Dienst unabhaengig vom
        # A2F-Ordner ist (der spaeter geloescht werden koennte).
        Copy-Item -LiteralPath $a2fNssm -Destination $mosqNssm -Force

        # AppDirectory = mosquitto-Ordner, Config RELATIV angeben (-c mosquitto.conf).
        # Kein voller Pfad mit Leerzeichen/Quotes als Argument -> umgeht das
        # PowerShell-5.1-Quoting-Problem bei eingebetteten Anfuehrungszeichen.
        Invoke-Nssm -NssmPath $mosqNssm install mosquitto $mosqExe | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "nssm install mosquitto schlug fehl (Code $LASTEXITCODE)." }
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppDirectory $mosqDir | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppParameters "-c mosquitto.conf" | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto Start SERVICE_AUTO_START | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto DisplayName 'Mosquitto Broker' | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm start mosquitto | Out-Null
        Write-Log 'Mosquitto-Dienst (via NSSM) registriert und gestartet.'

        # 5b. Wirklich verifizieren, dass der Broker auf 1883 lauscht. Startet
        # mosquitto wegen eines Config-Fehlers nicht, gibt es sonst nur ein stilles
        # "Connection refused" spaeter.
        Start-Sleep -Seconds 2
        $listening = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect('127.0.0.1', 1883)
            $listening = $tcp.Connected
            $tcp.Close()
        } catch { $listening = $false }
        if ($listening) {
            Write-Log 'Mosquitto laeuft und lauscht auf 127.0.0.1:1883.'
        } else {
            Write-Log 'ACHTUNG: Mosquitto lauscht NICHT auf 1883 - der Dienst ist vermutlich beim Start abgebrochen.' 'WARN'
            Write-Log 'Diagnose: Admin-Konsole -> cd "C:\Program Files\mosquitto" -> mosquitto -c mosquitto.conf -v   (zeigt die genaue Fehlerursache).' 'WARN'
        }

        # 6. config/.env im Installationsordner sicherstellen und MQTT-Schluessel synchronisieren
        Push-Location $Dir
        try { & $py -c 'import config' | Out-Null } finally { Pop-Location }
        $envPath = Join-Path $Dir 'config\.env'
        Update-EnvFile -Path $envPath -Values @{
            MQTT_BROKER   = '127.0.0.1'
            MQTT_PORT     = '1883'
            MQTT_USERNAME = $user
            MQTT_PASSWORD = $pass
        } | Out-Null
        Write-Log 'MQTT-Zugangsdaten in config\.env uebernommen.'

        # 7. Firewall optional
        $fw = Read-Host 'Port 1883 in der Firewall freigeben (Zugriff von anderem Rechner)? (j/n)'
        if ($fw -match '^(j|J)') {
            New-NetFirewallRule -DisplayName 'Mosquitto MQTT 1883' -Direction Inbound `
                -Protocol TCP -LocalPort 1883 -Action Allow -ErrorAction SilentlyContinue | Out-Null
            Write-Log 'Firewall-Regel fuer Port 1883 angelegt.'
        }

        # 8. Zugangsdaten fuer Alamos ausgeben
        $ips = @()
        try {
            $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -ExpandProperty IPAddress)
        } catch {}
        $ipText = if ($ips.Count) { $ips -join ', ' } else { '(keine LAN-IP gefunden)' }

        $envLines = @(Get-Content -LiteralPath $envPath -ErrorAction SilentlyContinue)
        $topic  = (($envLines | Where-Object { $_ -like 'MQTT_TOPIC=*' } | Select-Object -First 1) -replace '^MQTT_TOPIC=', '')
        $sTopic = (($envLines | Where-Object { $_ -like 'MQTT_STATUS_TOPIC=*' } | Select-Object -First 1) -replace '^MQTT_STATUS_TOPIC=', '')
        if (-not $topic)  { $topic  = 'Alarm_Topic' }
        if (-not $sTopic) { $sTopic = 'status' }

        Write-Log "Mosquitto eingerichtet, MQTT-Benutzer '$user' angelegt."
        Write-Host ''
        Write-Host '==================== MQTT-ZUGANGSDATEN FUER ALAMOS ====================' -ForegroundColor Cyan
        Write-Host ("  Broker (dieser Rechner): $ipText") -ForegroundColor Cyan
        Write-Host  '                           (bzw. 127.0.0.1, wenn Alamos auf DIESEM Rechner laeuft)' -ForegroundColor Cyan
        Write-Host  '  Port                   : 1883' -ForegroundColor Cyan
        Write-Host ("  Benutzername           : $user") -ForegroundColor Cyan
        Write-Host ("  Passwort               : $pass") -ForegroundColor Cyan
        Write-Host ("  Alarm-Topic            : $topic") -ForegroundColor Cyan
        Write-Host ("  Status-Topic           : $sTopic") -ForegroundColor Cyan
        Write-Host '======================================================================' -ForegroundColor Cyan
        Write-Host 'Diese Daten in ALAMOS als MQTT-Ziel eintragen - bitte notieren!' -ForegroundColor Yellow
        Write-Host 'Alamos2Fireplan selbst verbindet sich lokal mit 127.0.0.1 - diese' -ForegroundColor Yellow
        Write-Host 'Einstellung in den A2F-Einstellungen NICHT auf die LAN-IP aendern.' -ForegroundColor Yellow
        Write-Host ''
    }
    catch {
        Write-Log "Mosquitto-Setup fehlgeschlagen: $($_.Exception.Message)" 'WARN'
        Write-Log 'Die Alamos2Fireplan-Installation laeuft trotzdem weiter.' 'WARN'
    }
}

function Get-ServiceDir {
    $dir = Invoke-Nssm get $ServiceName AppDirectory
    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw "Installationsordner des Dienstes '$ServiceName' konnte nicht ermittelt werden."
    }
    return $dir
}

function Invoke-FreshInstall {
    param([Parameter(Mandatory)][string]$Dir)
    Write-Log "Neuinstallation nach '$Dir'."
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

    foreach ($item in $FreshItems) {
        $src = Join-Path $ProjectDir $item
        if (-not (Test-Path -LiteralPath $src)) { continue }
        Copy-Element -Src $src -Dst (Join-Path $Dir $item)
    }
    Write-Log "Dateien nach '$Dir' kopiert."

    Install-Service -Dir $Dir

    $answer = Read-Host 'Lokalen Mosquitto-Broker einrichten? (j/n)'
    if ($answer -match '^(j|J)') { Setup-Mosquitto -Dir $Dir }

    Invoke-Nssm start $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Assert-ServiceStarted
    Write-Log "Installation abgeschlossen. Installationsordner: $Dir - Weboberflaeche: http://localhost:5000"
}

function Invoke-UpdateInPlace {
    param([Parameter(Mandatory)][string]$Dir)
    Write-Log "Update der bestehenden Installation in '$Dir'."

    Write-Log 'Stoppe Dienst fuer Update...'
    Invoke-Nssm stop $ServiceName | Out-Null
    Start-Sleep -Seconds 2

    # --- Backup (config, alarme.db, logs) ---
    $targetItems = Get-ChildItem -LiteralPath $Dir -Force | Select-Object -ExpandProperty Name
    $backupItems = Get-BackupItems -TargetItems $targetItems
    $backupDir = Join-Path (Join-Path $Dir 'backups') (Get-BackupFolderName -Timestamp (Get-Date))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    foreach ($item in $backupItems) {
        Copy-Item -LiteralPath (Join-Path $Dir $item) -Destination $backupDir -Recurse -Force
    }
    Write-Log "Backup erstellt: $backupDir (Elemente: $($backupItems -join ', '))"

    # --- Nur Code aktualisieren (config/, alarme.db, logs/ bleiben unangetastet) ---
    $sourceItems = Get-ChildItem -LiteralPath $ProjectDir -Force | Select-Object -ExpandProperty Name
    $copyPlan = Get-UpdateCopyPlan -SourceItems $sourceItems
    foreach ($item in $copyPlan) {
        Copy-Element -Src (Join-Path $ProjectDir $item) -Dst (Join-Path $Dir $item)
    }
    Write-Log "Code aktualisiert (Elemente: $($copyPlan -join ', '))."

    Invoke-Nssm start $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Assert-ServiceStarted
    Write-Log 'Update abgeschlossen.'
}

function Invoke-Setup {
    # Ein Einstieg fuer Erst-Installation UND Update: erkennt anhand des Dienstes,
    # was zu tun ist. Der Kunde fuehrt immer install.bat aus dem entpackten Paket aus.
    Assert-Admin
    Test-Python | Out-Null

    $exists = [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
    $target = if ($exists) { Get-ServiceDir } else { $InstallDir }

    # Same-Dir-Schutz: install.bat muss aus dem ENTPACKTEN Paket laufen, nicht aus
    # dem Installationsordner selbst (sonst Datei-auf-sich-selbst-Kopie).
    $srcResolved = (Resolve-Path -LiteralPath $ProjectDir).Path.TrimEnd('\')
    if (Test-Path -LiteralPath $target) {
        $dstResolved = (Resolve-Path -LiteralPath $target).Path.TrimEnd('\')
        if ($srcResolved -ieq $dstResolved) {
            throw "install.bat laeuft aus dem Installationsordner selbst ($target). Bitte das ENTPACKTE Paket (neue Version) verwenden und install.bat von dort starten."
        }
    }

    if ($exists) {
        Write-Log "Bestehende Installation gefunden unter '$target' - fuehre UPDATE durch."
        Invoke-UpdateInPlace -Dir $target
    } else {
        Write-Log "Keine bestehende Installation - fuehre NEUINSTALLATION durch."
        Invoke-FreshInstall -Dir $target
    }
}

function Uninstall-Mosquitto {
    try {
        $mosqDir = 'C:\Program Files\mosquitto'
        $mosqExe = Join-Path $mosqDir 'mosquitto.exe'
        $uninst  = Join-Path $mosqDir 'Uninstall.exe'

        if (Get-Service -Name 'mosquitto' -ErrorAction SilentlyContinue) {
            Stop-Service -Name 'mosquitto' -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $mosqExe) { & $mosqExe uninstall 2>$null | Out-Null }
        }
        if (Test-Path -LiteralPath $uninst) {
            Write-Log 'Deinstalliere Mosquitto (silent)...'
            Start-Process -FilePath $uninst -ArgumentList '/S' -Wait
            Write-Log 'Mosquitto deinstalliert.'
        } else {
            Write-Log 'Mosquitto-Uninstaller nicht gefunden (evtl. nicht installiert).' 'WARN'
        }
        # pwfile-Verzeichnis + Firewall-Regel entfernen
        $pwDir = Split-Path $PwFile -Parent
        if (Test-Path -LiteralPath $pwDir) { Remove-Item -LiteralPath $pwDir -Recurse -Force -ErrorAction SilentlyContinue }
        Get-NetFirewallRule -DisplayName 'Mosquitto MQTT 1883' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-Log 'Mosquitto-Zugangsdatei und Firewall-Regel entfernt (falls vorhanden).'
    }
    catch {
        Write-Log "Mosquitto-Deinstallation fehlgeschlagen: $($_.Exception.Message)" 'WARN'
    }
}

function Remove-InstallDir {
    # Der laufende Prozess (setup.ps1/uninstall.bat) liegt i. d. R. IM zu
    # loeschenden Ordner -> ein losgeloester Helfer wartet, bis alle Dateien frei
    # sind (User beendet das Fenster), loescht den Ordner und raeumt sich selbst weg.
    param([Parameter(Mandatory)][string]$Dir)
    $deleter = Join-Path $env:TEMP ("a2f_uninstall_" + [guid]::NewGuid().ToString("N") + ".cmd")
    $lines = @(
        '@echo off',
        'cd /d C:\',
        ':retry',
        ('rmdir /s /q "' + $Dir + '" 2>nul'),
        ('if not exist "' + $Dir + '" goto done'),
        'ping 127.0.0.1 -n 2 >nul',
        'goto retry',
        ':done',
        'del "%~f0" >nul 2>&1'
    )
    Set-Content -LiteralPath $deleter -Value $lines -Encoding ASCII
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', $deleter -WindowStyle Hidden -WorkingDirectory 'C:\'
    Write-Log "Installationsordner '$Dir' wird nach dem Schliessen dieses Fensters vollstaendig entfernt."
}

function Invoke-Uninstall {
    Assert-Admin
    $confirm = Read-Host "Dienst '$ServiceName' wirklich entfernen? (j/n)"
    if ($confirm -notmatch '^(j|J)') { Write-Log 'Deinstallation abgebrochen.'; return }

    $dir = $null
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        try { $dir = Get-ServiceDir } catch { $dir = $null }
    }
    if (-not $dir) { $dir = $InstallDir }

    Remove-Service
    Write-Log "Dienst '$ServiceName' entfernt."

    $delMosq = Read-Host 'Lokalen Mosquitto-Broker ebenfalls deinstallieren? (j/n)'
    if ($delMosq -match '^(j|J)') { Uninstall-Mosquitto }
    else { Write-Log 'Mosquitto bleibt erhalten.' }

    $delDir = Read-Host "Installationsordner '$dir' komplett loeschen - inkl. Config, Datenbank und Backups? (j/n)"
    if ($delDir -match '^(j|J)') {
        Remove-InstallDir -Dir $dir
    } else {
        Write-Log "Installationsordner '$dir' bleibt erhalten."
    }
    Write-Log 'Deinstallation abgeschlossen.'
}

# ---- Dispatch ----
# Nur ausfuehren, wenn das Skript direkt gestartet wird (nicht beim Dot-Sourcing
# durch Tests). Beim Dot-Sourcing ist InvocationName '.'.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Write-Log "setup.ps1 gestartet im Modus '$Mode'."
        switch ($Mode) {
            'install'   { Invoke-Setup }
            'uninstall' { Invoke-Uninstall }
        }
        exit 0
    }
    catch {
        Write-Log $_.Exception.Message 'ERROR'
        exit 1
    }
}
