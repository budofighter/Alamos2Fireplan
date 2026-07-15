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
$MosqVersion = '2.0.20'
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

        # 1. Installieren, falls nicht vorhanden
        if (-not (Test-Path -LiteralPath $mosqExe)) {
            $installer = Join-Path $env:TEMP "mosquitto-install.exe"
            Write-Log "Lade Mosquitto herunter: $MosqUrl"
            Invoke-WebRequest -Uri $MosqUrl -OutFile $installer
            Write-Log 'Installiere Mosquitto (silent)...'
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
        Set-Content -LiteralPath (Join-Path $mosqDir 'mosquitto.conf') -Value $conf -Encoding UTF8
        Write-Log 'mosquitto.conf geschrieben.'

        # 5. Dienst sicherstellen + neu starten
        if (-not (Get-Service -Name 'mosquitto' -ErrorAction SilentlyContinue)) {
            & $mosqExe install | Out-Null
        }
        Restart-Service -Name 'mosquitto' -ErrorAction SilentlyContinue
        Start-Service -Name 'mosquitto' -ErrorAction SilentlyContinue
        Write-Log 'Mosquitto-Dienst gestartet.'

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

        # 8. Abschlusshinweis
        Write-Log "FERTIG. MQTT-Zugang: Benutzer '$user' / Broker 127.0.0.1:1883."
        Write-Host "WICHTIG: Diese Zugangsdaten auch in Alamos eintragen (Benutzer: $user)." -ForegroundColor Cyan
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

function Invoke-Uninstall {
    Assert-Admin
    $confirm = Read-Host "Dienst '$ServiceName' wirklich entfernen? (j/n)"
    if ($confirm -notmatch '^(j|J)') { Write-Log 'Deinstallation abgebrochen.'; return }

    $dir = $null
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        try { $dir = Get-ServiceDir } catch { $dir = $null }
    }

    Remove-Service
    Write-Log "Dienst '$ServiceName' entfernt."

    if ($dir) {
        Write-Log "Installationsordner '$dir' (inkl. Config, Datenbank, Backups) wurde NICHT geloescht - bei Bedarf manuell entfernen."
    }
    Write-Log 'Mosquitto wurde NICHT entfernt. Bei Bedarf manuell ueber die Windows-Programme deinstallieren.'
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
