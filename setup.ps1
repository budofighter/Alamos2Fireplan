[CmdletBinding()]
param(
    [ValidateSet('install','update','uninstall')]
    [string]$Mode = 'install'
)

$ErrorActionPreference = 'Stop'

# ---- Konstanten ----
$ServiceName = 'Alamos2Fireplan'
$ProjectDir  = $PSScriptRoot
$PythonExe   = Join-Path $ProjectDir 'tools\python\python.exe'
$RunServer   = Join-Path $ProjectDir 'runserver.py'
$LogDir      = Join-Path $ProjectDir 'logs'
$SetupLog    = Join-Path $LogDir 'setup.log'
$PwFile      = 'C:\ProgramData\Alamos2Fireplan\pwfile.txt'
$PyVersion   = '3.13.14'
$PyUrl       = "https://www.python.org/ftp/python/$PyVersion/python-$PyVersion-embed-amd64.zip"
$MosqVersion = '2.0.20'
$MosqUrl     = "https://mosquitto.org/files/binary/win64/mosquitto-$MosqVersion-install-windows-x64.exe"

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
    # Zentrale nssm-Hülle. Zwei Probleme werden hier abgefangen:
    #  1) nssm gibt UTF-16LE aus -> Windows PowerShell dekodiert mit NUL-Zeichen
    #     -> Ausgabe wird via Clear-NssmString bereinigt.
    #  2) nssm schreibt harmlose Meldungen (z. B. "Dienst nicht gestartet",
    #     "Can't open service") nach stderr. Unter $ErrorActionPreference='Stop'
    #     würde das einen terminierenden Fehler auslösen. Daher lokal 'Continue'
    #     und stderr nach stdout mergen. Echte Fehler erkennt der Aufrufer über
    #     $LASTEXITCODE, nicht über Exceptions.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NssmArgs)
    $nssm = Get-Nssm
    $ErrorActionPreference = 'Continue'
    $raw = & $nssm @NssmArgs 2>&1 | Out-String
    return (Clear-NssmString -Text $raw)
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Dieses Skript benötigt Administratorrechte. Bitte install.bat/update.bat/uninstall.bat als Administrator ausführen.'
    }
}

function Test-Python {
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        throw "Embeddable Python fehlt unter $PythonExe. Ist das Paket vollständig entpackt?"
    }
    & $PythonExe --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Python unter $PythonExe ist nicht lauffähig." }
    return $true
}

function Remove-Service {
    Invoke-Nssm stop $ServiceName | Out-Null
    Invoke-Nssm remove $ServiceName confirm | Out-Null
    Write-Log "Vorhandener Dienst '$ServiceName' gestoppt/entfernt (falls vorhanden)."
}

function Install-Service {
    $nssm = Get-Nssm
    if (-not (Test-Path -LiteralPath $nssm)) { throw "NSSM fehlt unter $nssm." }
    Remove-Service
    Invoke-Nssm install $ServiceName $PythonExe $RunServer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "nssm install schlug fehl (Code $LASTEXITCODE)." }
    Invoke-Nssm set $ServiceName AppDirectory $ProjectDir | Out-Null
    Invoke-Nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
    Invoke-Nssm set $ServiceName ObjectName LocalSystem | Out-Null
    Invoke-Nssm set $ServiceName AppStdout (Join-Path $LogDir 'service.log') | Out-Null
    Invoke-Nssm set $ServiceName AppStderr (Join-Path $LogDir 'service.log') | Out-Null
    Invoke-Nssm set $ServiceName AppRotateFiles 1 | Out-Null
    Invoke-Nssm set $ServiceName AppRotateBytes 1048576 | Out-Null
    Write-Log "Dienst '$ServiceName' registriert (Logging → logs/service.log)."
}

function Assert-ServiceStarted {
    $status = Invoke-Nssm status $ServiceName
    if ($status -notmatch 'SERVICE_RUNNING') {
        throw "Dienst '$ServiceName' läuft nicht (Status: $status). Siehe logs/service.log."
    }
    Write-Log "Dienst '$ServiceName' läuft."
}

function Setup-Mosquitto {
    try {
        $mosqDir = 'C:\Program Files\mosquitto'
        $mosqExe = Join-Path $mosqDir 'mosquitto.exe'
        $mosqPw  = Join-Path $mosqDir 'mosquitto_passwd.exe'

        # 1. Installieren, falls nicht vorhanden
        if (-not (Test-Path -LiteralPath $mosqExe)) {
            $installer = Join-Path $env:TEMP "mosquitto-install.exe"
            Write-Log "Lade Mosquitto herunter: $MosqUrl"
            Invoke-WebRequest -Uri $MosqUrl -OutFile $installer
            Write-Log 'Installiere Mosquitto (silent)...'
            Start-Process -FilePath $installer -ArgumentList '/S' -Wait
        } else {
            Write-Log 'Mosquitto bereits installiert – nur Neukonfiguration.'
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

        # 6. config/.env sicherstellen und MQTT-Schlüssel synchronisieren
        Push-Location $ProjectDir
        try { & $PythonExe -c 'import config' | Out-Null } finally { Pop-Location }
        $envPath = Join-Path $ProjectDir 'config\.env'
        Update-EnvFile -Path $envPath -Values @{
            MQTT_BROKER   = '127.0.0.1'
            MQTT_PORT     = '1883'
            MQTT_USERNAME = $user
            MQTT_PASSWORD = $pass
        } | Out-Null
        Write-Log 'MQTT-Zugangsdaten in config/.env übernommen.'

        # 7. Firewall optional
        $fw = Read-Host 'Port 1883 in der Firewall freigeben (Zugriff von anderem Rechner)? (j/n)'
        if ($fw -match '^(j|J)') {
            New-NetFirewallRule -DisplayName 'Mosquitto MQTT 1883' -Direction Inbound `
                -Protocol TCP -LocalPort 1883 -Action Allow -ErrorAction SilentlyContinue | Out-Null
            Write-Log 'Firewall-Regel für Port 1883 angelegt.'
        }

        # 8. Abschlusshinweis
        Write-Log "FERTIG. MQTT-Zugang: Benutzer '$user' / Broker 127.0.0.1:1883."
        Write-Host "WICHTIG: Diese Zugangsdaten auch in Alamos eintragen (Benutzer: $user)." -ForegroundColor Cyan
    }
    catch {
        Write-Log "Mosquitto-Setup fehlgeschlagen: $($_.Exception.Message)" 'WARN'
        Write-Log 'Die Alamos2Fireplan-Installation läuft trotzdem weiter.' 'WARN'
    }
}

function Invoke-Install {
    Assert-Admin
    Test-Python | Out-Null
    Install-Service

    $answer = Read-Host 'Lokalen Mosquitto-Broker einrichten? (j/n)'
    if ($answer -match '^(j|J)') { Setup-Mosquitto }

    Invoke-Nssm start $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Assert-ServiceStarted
    Write-Log "Installation abgeschlossen. Weboberfläche: http://localhost:5000"
}

function Get-ServiceDir {
    $dir = Invoke-Nssm get $ServiceName AppDirectory
    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw "Dienst '$ServiceName' nicht gefunden. Bitte zuerst install.bat ausführen."
    }
    return $dir
}

function Invoke-Update {
    Assert-Admin
    $target = Get-ServiceDir
    Write-Log "Update-Ziel automatisch erkannt: $target"

    # Same-Dir-Schutz: update.bat muss aus der NEUEN, separat entpackten Version
    # laufen, nicht aus dem installierten Ordner selbst (sonst würde eine Datei
    # auf sich selbst kopiert). Prüfen, bevor der Dienst gestoppt wird.
    $srcResolved = (Resolve-Path -LiteralPath $ProjectDir).Path.TrimEnd('\')
    $dstResolved = (Resolve-Path -LiteralPath $target).Path.TrimEnd('\')
    if ($srcResolved -ieq $dstResolved) {
        throw "update.bat läuft aus dem installierten Ordner selbst ($target). Bitte die NEUE Version in einen ANDEREN Ordner entpacken und update.bat von dort starten."
    }

    Write-Log 'Stoppe Dienst für Update...'
    Invoke-Nssm stop $ServiceName | Out-Null
    Start-Sleep -Seconds 2

    # --- Backup ---
    $targetItems = Get-ChildItem -LiteralPath $target -Force | Select-Object -ExpandProperty Name
    $backupItems = Get-BackupItems -TargetItems $targetItems
    $backupDir = Join-Path (Join-Path $target 'backups') (Get-BackupFolderName -Timestamp (Get-Date))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    foreach ($item in $backupItems) {
        Copy-Item -LiteralPath (Join-Path $target $item) -Destination $backupDir -Recurse -Force
    }
    Write-Log "Backup erstellt: $backupDir (Elemente: $($backupItems -join ', '))"

    # --- Code kopieren (nur Allowlist) ---
    $sourceItems = Get-ChildItem -LiteralPath $ProjectDir -Force | Select-Object -ExpandProperty Name
    $copyPlan = Get-UpdateCopyPlan -SourceItems $sourceItems
    foreach ($item in $copyPlan) {
        $src = Join-Path $ProjectDir $item
        $dst = Join-Path $target $item
        if (Test-Path -LiteralPath $src -PathType Container) {
            # Verzeichnisinhalt ins bestehende Ziel spiegeln. Copy-Item -Recurse in ein
            # existierendes Verzeichnis würde die Quelle hineinschachteln (app -> app\app);
            # robocopy überschreibt Dateien, verschachtelt nicht und wiederholt bei
            # kurzzeitig gesperrten Dateien (z. B. gerade gestopptes tools\python).
            robocopy $src $dst /E /NFL /NDL /NJH /NJS /R:3 /W:2 | Out-Null
            if ($LASTEXITCODE -ge 8) {
                throw "Kopieren von '$item' fehlgeschlagen (robocopy Code $LASTEXITCODE)."
            }
            $global:LASTEXITCODE = 0
        } else {
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    Write-Log "Code aktualisiert (Elemente: $($copyPlan -join ', '))."

    # --- Abhängigkeiten aktualisieren ---
    $targetPython = Join-Path $target 'tools\python\python.exe'
    $reqs = Join-Path $target 'requirements.txt'
    if ((Test-Path -LiteralPath $targetPython) -and (Test-Path -LiteralPath $reqs)) {
        & $targetPython -m pip install -r $reqs
        Write-Log 'Python-Abhängigkeiten aktualisiert.'
    }

    Invoke-Nssm start $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Assert-ServiceStarted
    Write-Log 'Update abgeschlossen.'
}

function Invoke-Uninstall {
    Assert-Admin
    $confirm = Read-Host "Dienst '$ServiceName' wirklich entfernen? (j/n)"
    if ($confirm -notmatch '^(j|J)') { Write-Log 'Deinstallation abgebrochen.'; return }

    Remove-Service
    Write-Log "Dienst '$ServiceName' entfernt."

    $delPy = Read-Host 'Gebündeltes Python (tools\python) löschen? (j/n)'
    if ($delPy -match '^(j|J)') {
        $py = Join-Path $ProjectDir 'tools\python'
        if (Test-Path -LiteralPath $py) { Remove-Item -LiteralPath $py -Recurse -Force; Write-Log 'tools\python gelöscht.' }
    }

    $delBk = Read-Host 'Backups (backups\) löschen? (j/n)'
    if ($delBk -match '^(j|J)') {
        $bk = Join-Path $ProjectDir 'backups'
        if (Test-Path -LiteralPath $bk) { Remove-Item -LiteralPath $bk -Recurse -Force; Write-Log 'backups gelöscht.' }
    }

    Write-Log 'Mosquitto wurde NICHT entfernt. Bei Bedarf manuell über die Windows-Programme deinstallieren.'
}

# ---- Dispatch (Platzhalter, in Folgetasks gefüllt) ----
try {
    Write-Log "setup.ps1 gestartet im Modus '$Mode'."
    switch ($Mode) {
        'install'   { Invoke-Install }
        'update'    { Invoke-Update }
        'uninstall' { Invoke-Uninstall }
    }
    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
