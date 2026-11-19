[CmdletBinding()]
param(
    [ValidateSet('install','uninstall')]
    [string]$Mode = 'install'
)

# ===========================================================================
#  Alamos2Fireplan - Installation, Update, Reparatur und Deinstallation
#
#  Ein Einstieg (install.bat) fuer alles. Das Skript erkennt selbst:
#   - NEUINSTALLATION  : keine bestehende Installation gefunden
#   - UPDATE           : bestehende Installation (jede Version ab 2.0.x)
#   - REPARATUR        : Paket wurde direkt in den Installationsordner entpackt
#
#  Grundsaetze:
#   - Daten (config\.env, config\*.json, alarme.db) werden NIE ueberschrieben
#     und vor jedem Update gesichert.
#   - Das Update ist transaktional: alter Code wird ins Backup verschoben, nicht
#     geloescht. Startet die neue Version nicht, wird automatisch die alte
#     Version wiederhergestellt.
#   - Erfolg = Weboberflaeche antwortet tatsaechlich (HTTP), nicht nur
#     "Dienst-Status laeuft".
#
#  Datei bleibt reines ASCII (Windows PowerShell 5.1 Parse-Sicherheit).
# ===========================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Downloads/Expand ohne Fortschrittsbalken (viel schneller)

# ---- Konstanten ----
$ServiceName  = 'Alamos2Fireplan'
$InstallDir   = 'C:\Alamos2Fireplan'          # Standard-Installationsort (Neuinstallation)
$ProjectDir   = $PSScriptRoot                  # entpacktes Paket = Quelle
$PythonExe    = Join-Path $ProjectDir 'tools\python\python.exe'
$PwFile       = 'C:\ProgramData\Alamos2Fireplan\pwfile.txt'
$MosqVersion  = '2.1.4'
$MosqUrl      = "https://mosquitto.org/files/binary/win64/mosquitto-$MosqVersion-install-windows-x64.exe"
$MosqDir      = 'C:\Program Files\mosquitto'
$BackupKeep   = 5                              # so viele Update-Backups bleiben erhalten
$HealthSecs   = 90                             # so lange darf der Start der Weboberflaeche dauern
$MinFreeMB    = 400                            # Mindest-Speicherplatz fuer Update (Backup + neuer Code)

# Dateien, ohne die das Paket nicht vollstaendig ist
$RequiredPackageFiles = @('runserver.py','app\app.py','backend\version.py','config\config.py',
                          'tools\nssm.exe','tools\python\python.exe','setup.lib.ps1')

# ---- Lib laden ----
. (Join-Path $ProjectDir 'setup.lib.ps1')

# ---- Logging ----
# Zunaechst im Paketordner; sobald der Zielordner feststeht, wird ins dortige
# logs\setup.log weitergeschrieben (Set-LogTarget).
$script:SetupLog = Join-Path (Join-Path $ProjectDir 'logs') 'setup.log'

function Write-Log {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $dir = Split-Path $script:SetupLog -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $script:SetupLog -Value $line -Encoding UTF8
    } catch { }   # Logging darf die Installation nie abbrechen
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ("==> " + $Title) -ForegroundColor Cyan
    Write-Log ("--- " + $Title + " ---")
}

function Set-LogTarget {
    param([Parameter(Mandatory)][string]$Dir)
    $new = Join-Path (Join-Path $Dir 'logs') 'setup.log'
    if ($new -ieq $script:SetupLog) { return }
    try {
        $newDir = Split-Path $new -Parent
        if (-not (Test-Path -LiteralPath $newDir)) { New-Item -ItemType Directory -Path $newDir -Force | Out-Null }
        if (Test-Path -LiteralPath $script:SetupLog) {
            Get-Content -LiteralPath $script:SetupLog -Encoding UTF8 | Add-Content -LiteralPath $new -Encoding UTF8
            Remove-Item -LiteralPath $script:SetupLog -Force -ErrorAction SilentlyContinue
        }
        $script:SetupLog = $new
    } catch { }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Question, [bool]$Default = $false)
    $hint = if ($Default) { '(J/n)' } else { '(j/N)' }
    $answer = Read-Host "$Question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return ($answer -match '^(j|J|y|Y)')
}

# ---- NSSM ----
function Invoke-Nssm {
    # Zentrale nssm-Huelle. Zwei Probleme werden hier abgefangen:
    #  1) nssm gibt UTF-16LE aus -> Windows PowerShell dekodiert mit NUL-Zeichen
    #     -> Ausgabe wird via Clear-NssmString bereinigt.
    #  2) nssm schreibt harmlose Meldungen nach stderr. Unter EAP='Stop' waere
    #     das ein terminierender Fehler -> lokal 'Continue', stderr verwerfen.
    #     Echte Fehler erkennt der Aufrufer ueber $LASTEXITCODE.
    # $NssmArgs hat Position 0 (ValueFromRemainingArguments), $NssmPath ist nur
    # benannt nutzbar.
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$NssmArgs,
        [string]$NssmPath
    )
    $nssm = if ($NssmPath) { $NssmPath } else { Join-Path $ProjectDir 'tools\nssm.exe' }
    $ErrorActionPreference = 'Continue'
    $raw = & $nssm @NssmArgs 2>$null | Out-String
    return (Clear-NssmString -Text $raw)
}

function Get-ServiceRegistration {
    # Liest die NSSM-Parameter direkt aus der Registry (keine Encoding-Probleme
    # mit der nssm-Ausgabe). Liefert $null, wenn der Dienst nicht existiert.
    param([Parameter(Mandatory)][string]$Name)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    $svc = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    $par = Get-ItemProperty -LiteralPath "$key\Parameters" -ErrorAction SilentlyContinue
    $image = [string]$svc.ImagePath
    return [pscustomobject]@{
        ImagePath     = $image
        NssmExe       = ($image.Trim().Trim('"') -replace '"', '')
        Application   = [string]$par.Application
        AppDirectory  = [string]$par.AppDirectory
        AppParameters = [string]$par.AppParameters
    }
}

function Test-ServiceExists {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Service -Name $Name -ErrorAction SilentlyContinue)
}

function Stop-AppProcesses {
    # Beendet alle Prozesse, deren Programmdatei im Ordner $Dir liegt (z. B. ein
    # haengengebliebenes python.exe). Danach sind die Dateien nicht mehr gesperrt.
    param([Parameter(Mandatory)][string]$Dir)
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and (Test-PathInside -Path $_.ExecutablePath -Root $Dir)
    })
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $PID) { continue }
        Write-Log "Beende verbliebenen Prozess $($p.Name) (PID $($p.ProcessId))." 'WARN'
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
    }
    if ($procs.Count) { Start-Sleep -Seconds 2 }
}

function Stop-AppService {
    # Stoppt den Dienst und WARTET, bis er wirklich steht (statt fester Pause).
    param([Parameter(Mandatory)][string]$Dir, [int]$TimeoutSec = 60)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Log "Stoppe Dienst '$ServiceName'..."
        try { Stop-Service -Name $ServiceName -Force -ErrorAction Stop } catch {
            Write-Log "Stop-Service meldete: $($_.Exception.Message)" 'WARN'
        }
        try {
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSec))
        } catch {
            Write-Log "Dienst stoppt nicht innerhalb von $TimeoutSec s - beende Prozesse hart." 'WARN'
        }
    }
    if ($Dir -and (Test-Path -LiteralPath $Dir)) { Stop-AppProcesses -Dir $Dir }
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        throw "Dienst '$ServiceName' laesst sich nicht stoppen (Status: $($svc.Status))."
    }
}

function Remove-AppService {
    param([string]$Dir)
    if (-not (Test-ServiceExists $ServiceName)) { return }
    Stop-AppService -Dir $Dir
    Invoke-Nssm remove $ServiceName confirm | Out-Null
    # Warten, bis der Dienst wirklich aus der Dienstverwaltung verschwunden ist
    foreach ($i in 1..20) {
        if (-not (Test-ServiceExists $ServiceName)) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Test-ServiceExists $ServiceName) {
        & sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }
    if (Test-ServiceExists $ServiceName) {
        throw "Dienst '$ServiceName' konnte nicht entfernt werden (evtl. ist services.msc geoeffnet - bitte schliessen)."
    }
    Write-Log "Dienst '$ServiceName' entfernt."
}

function Register-AppService {
    # Registriert den Dienst mit der nssm.exe IM Installationsordner (nicht im
    # Paketordner, der spaeter geloescht werden kann). Wird bei JEDER
    # Installation/Update neu gemacht -> Dienst zeigt garantiert auf das
    # gebuendelte Python (Altinstallationen zeigten auf venv\Scripts\python.exe).
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$Application,
        [string]$AppParameters,
        [string]$NssmExe
    )
    if (-not $NssmExe)       { $NssmExe = Join-Path $Dir 'tools\nssm.exe' }
    if (-not (Test-Path -LiteralPath $NssmExe)) {
        # Fallback (z. B. Altinstallation ohne tools\nssm.exe): nssm ins Ziel kopieren
        $pkgNssm = Join-Path $ProjectDir 'tools\nssm.exe'
        if (Test-Path -LiteralPath $pkgNssm) {
            $nssmDir = Split-Path $NssmExe -Parent
            if (-not (Test-Path -LiteralPath $nssmDir)) { New-Item -ItemType Directory -Path $nssmDir -Force | Out-Null }
            Copy-Item -LiteralPath $pkgNssm -Destination $NssmExe -Force
        }
    }
    if (-not $Application)   { $Application = Join-Path $Dir 'tools\python\python.exe' }
    if (-not $AppParameters) { $AppParameters = 'runserver.py' }
    $svcLogDir = Join-Path $Dir 'logs'
    if (-not (Test-Path -LiteralPath $NssmExe)) { throw "NSSM fehlt unter $NssmExe." }
    if (-not (Test-Path -LiteralPath $svcLogDir)) { New-Item -ItemType Directory -Path $svcLogDir -Force | Out-Null }

    Remove-AppService -Dir $Dir
    Invoke-Nssm -NssmPath $NssmExe install $ServiceName $Application | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "nssm install schlug fehl (Code $LASTEXITCODE)." }
    $settings = @(
        @('AppParameters', $AppParameters),
        @('AppDirectory', $Dir),
        @('DisplayName', 'Alamos2Fireplan'),
        @('Description', 'Leitet Alamos-Alarme und Fahrzeugstatus an Fireplan/Feuersoftware weiter (Weboberflaeche Port 5000).'),
        @('Start', 'SERVICE_AUTO_START'),
        @('ObjectName', 'LocalSystem'),
        @('AppStdout', (Join-Path $svcLogDir 'service.log')),
        @('AppStderr', (Join-Path $svcLogDir 'service.log')),
        @('AppRotateFiles', '1'),
        @('AppRotateOnline', '1'),
        @('AppRotateBytes', '1048576'),
        @('AppExit', 'Default', 'Restart'),     # bei Absturz automatisch neu starten
        @('AppRestartDelay', '5000'),           # ... aber nicht in einer Endlosschleife
        @('AppThrottle', '10000'),
        @('AppStopMethodConsole', '5000')       # Python 5 s Zeit zum sauberen Beenden
    )
    foreach ($s in $settings) {
        $nssmArgs = @('set', $ServiceName) + $s
        Invoke-Nssm -NssmPath $NssmExe @nssmArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "nssm set $($s[0]) schlug fehl (Code $LASTEXITCODE)." 'WARN' }
    }
    Write-Log "Dienst '$ServiceName' registriert: $Application $AppParameters (Ordner: $Dir)."
}

function Get-WebPort {
    param([Parameter(Mandatory)][string]$Dir)
    $p = Get-EnvValue -Path (Join-Path $Dir 'config\.env') -Key 'WEB_PORT'
    $n = 0
    if ($p -and [int]::TryParse($p, [ref]$n) -and $n -gt 0) { return $n }
    return 5000
}

function Test-WebUi {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/login")
        $req.Proxy = $null            # lokale Pruefung nie ueber einen Proxy
        $req.Timeout = 5000
        $req.AllowAutoRedirect = $false
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -eq 200)
    } catch { return $false }
}

function Show-LogTail {
    param([Parameter(Mandatory)][string]$Dir, [int]$Lines = 15)
    foreach ($name in @('service.log','app.log')) {
        $f = Join-Path (Join-Path $Dir 'logs') $name
        if (Test-Path -LiteralPath $f) {
            Write-Host ''
            Write-Host "---- letzte Zeilen aus logs\$name ----" -ForegroundColor Yellow
            Get-Content -LiteralPath $f -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
        }
    }
}

function Start-AppServiceVerified {
    # Startet den Dienst und wartet, bis die Weboberflaeche wirklich antwortet.
    # Liefert $true/$false (wirft nicht), damit der Aufrufer zurueckrollen kann.
    param([Parameter(Mandatory)][string]$Dir)
    $port = Get-WebPort -Dir $Dir
    Write-Log "Starte Dienst '$ServiceName' und pruefe Weboberflaeche (Port $port, max. $HealthSecs s)..."
    try { Start-Service -Name $ServiceName -ErrorAction Stop } catch {
        Write-Log "Start-Service meldete: $($_.Exception.Message)" 'WARN'
    }
    $deadline = (Get-Date).AddSeconds($HealthSecs)
    while ((Get-Date) -lt $deadline) {
        if (Test-WebUi -Port $port) {
            # Kurz nachpruefen: laeuft der Dienst stabil weiter (kein Crash-Loop)?
            Start-Sleep -Seconds 3
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running' -and (Test-WebUi -Port $port)) {
                Write-Log "Dienst laeuft, Weboberflaeche antwortet: http://localhost:$port" 'OK'
                return $true
            }
        }
        Start-Sleep -Seconds 2
    }
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $state = if ($svc) { $svc.Status } else { 'nicht vorhanden' }
    Write-Log "Weboberflaeche antwortet nach $HealthSecs s nicht (Dienststatus: $state)." 'ERROR'
    Show-LogTail -Dir $Dir
    return $false
}

# ---- Paket / Voraussetzungen ----
function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Dieses Skript benoetigt Administratorrechte. Bitte install.bat/uninstall.bat als Administrator ausfuehren.'
    }
}

function Enable-Tls12 {
    # Windows PowerShell 5.1 auf aelteren Systemen nutzt sonst TLS 1.0 -> Downloads scheitern.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Assert-Package {
    if ($ProjectDir -match '\.zip\\' -or $ProjectDir -match '\\Temp\d*_[^\\]*\.zip') {
        throw 'install.bat wurde direkt aus dem ZIP gestartet. Bitte das ZIP zuerst entpacken (Rechtsklick > Alle extrahieren) und install.bat aus dem entpackten Ordner starten.'
    }
    $missing = @($RequiredPackageFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ProjectDir $_)) })
    if ($missing.Count) {
        throw "Das Paket ist unvollstaendig (fehlt: $($missing -join ', ')). Bitte das ZIP erneut herunterladen und vollstaendig entpacken."
    }
    # "Aus dem Internet heruntergeladen"-Markierung entfernen (sonst blockiert
    # Windows teils DLLs/Skripte aus dem Paket).
    Get-ChildItem -LiteralPath $ProjectDir -Recurse -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue

    # Selbsttest: laedt das gebuendelte Python alle Abhaengigkeiten?
    Push-Location $ProjectDir
    try {
        $ErrorActionPreference = 'Continue'
        $out = & $PythonExe -c "import sys, flask, paho.mqtt.client, cerberus, requests, dotenv, pytz, waitress; print(sys.version.split()[0])" 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { Pop-Location; $ErrorActionPreference = 'Stop' }
    if ($code -ne 0) {
        throw "Das gebuendelte Python im Paket ist nicht lauffaehig: $($out.Trim())"
    }
    Write-Log "Paket geprueft: Alamos2Fireplan v$(Get-PackageVersion), Python $($out.Trim())."
}

function Get-PackageVersion {
    $f = Join-Path $ProjectDir 'backend\version.py'
    return (Get-AppVersionFromText -Text ([string](Get-Content -LiteralPath $f -Raw)))
}

function Get-InstalledVersion {
    param([Parameter(Mandatory)][string]$Dir)
    foreach ($rel in @('backend\version.py', 'config\config.py')) {
        $f = Join-Path $Dir $rel
        if (Test-Path -LiteralPath $f) {
            $v = Get-AppVersionFromText -Text ([string](Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue))
            if ($v) { return $v }
        }
    }
    return $null
}

function Assert-FreeSpace {
    param([Parameter(Mandatory)][string]$Dir)
    $freeMB = $null
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Dir))
        $freeMB = [math]::Floor((New-Object System.IO.DriveInfo($root)).AvailableFreeSpace / 1MB)
    } catch { return }   # Pruefung nicht moeglich -> nicht blockieren
    if ($freeMB -lt $MinFreeMB) {
        throw "Zu wenig Speicherplatz auf $root ($freeMB MB frei, benoetigt: $MinFreeMB MB)."
    }
}

function Test-PortInUse {
    param([Parameter(Mandatory)][int]$Port)
    try {
        return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    } catch { return $false }
}

# ---- Dateien ----
function Copy-Element {
    # Kopiert Datei ODER Verzeichnis von $Src nach $Dst (robocopy fuer Ordner:
    # wiederholt bei kurzzeitig gesperrten Dateien).
    param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Dst)
    if (Test-Path -LiteralPath $Src -PathType Container) {
        & robocopy $Src $Dst /E /NFL /NDL /NJH /NJS /NP /R:5 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Kopieren von '$Src' fehlgeschlagen (robocopy Code $LASTEXITCODE)." }
        $global:LASTEXITCODE = 0
    } else {
        $parent = Split-Path $Dst -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
    }
}

function Copy-PackageCode {
    # Kopiert den kompletten Programmcode aus dem Paket nach $Dir.
    # config\: NUR *.py (config.py, __init__.py) - .env/*.json bleiben unberuehrt.
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $sourceItems = @(Get-ChildItem -LiteralPath $ProjectDir -Force | Select-Object -ExpandProperty Name)
    $plan = Get-UpdateCopyPlan -SourceItems $sourceItems
    foreach ($item in $plan) {
        Copy-Element -Src (Join-Path $ProjectDir $item) -Dst (Join-Path $Dir $item)
    }
    $cfgDst = Join-Path $Dir 'config'
    if (-not (Test-Path -LiteralPath $cfgDst)) { New-Item -ItemType Directory -Path $cfgDst -Force | Out-Null }
    Get-ChildItem -LiteralPath (Join-Path $ProjectDir 'config') -Filter '*.py' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $cfgDst $_.Name) -Force
    }
    # Python-Bytecode alter Versionen entfernen (wird neu erzeugt)
    Get-ChildItem -LiteralPath $Dir -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-PathInside -Path $_.FullName -Root (Join-Path $Dir 'backups')) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Programmcode kopiert ($($plan -join ', '), config\*.py)."
}

function Backup-Data {
    # Sichert config\, alarme.db (+WAL) nach $BackupDir\data und prueft die Kopie.
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$BackupDir)
    $dataDir = Join-Path $BackupDir 'data'
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    $targetItems = @(Get-ChildItem -LiteralPath $Dir -Force | Select-Object -ExpandProperty Name)
    $items = Get-BackupItems -TargetItems $targetItems
    foreach ($item in $items) {
        $src = Join-Path $Dir $item
        Copy-Element -Src $src -Dst (Join-Path $dataDir $item)
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $a = (Get-Item -LiteralPath $src).Length
            $b = (Get-Item -LiteralPath (Join-Path $dataDir $item)).Length
            if ($a -ne $b) { throw "Backup von '$item' ist unvollstaendig ($b von $a Bytes)." }
        }
    }
    if (-not $items.Count) { Write-Log 'Keine Daten zum Sichern gefunden.' 'WARN' }
    else { Write-Log "Daten gesichert nach $dataDir ($($items -join ', '))." }
}

function Move-OldCode {
    # Verschiebt den alten Code (und Altlasten wie venv\) nach $BackupDir\code.
    # Verschieben statt Loeschen: Grundlage fuer das automatische Zurueckrollen.
    # Liefert die Liste der verschobenen Elemente.
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$BackupDir)
    $codeDir = Join-Path $BackupDir 'code'
    New-Item -ItemType Directory -Path $codeDir -Force | Out-Null
    $moved = New-Object System.Collections.Generic.List[string]
    $candidates = @(Get-CodeItems) + @(Get-ObsoleteItems)
    try {
        foreach ($item in $candidates) {
            $src = Join-Path $Dir $item
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $ok = $false
            foreach ($try in 1..5) {
                try { Move-Item -LiteralPath $src -Destination (Join-Path $codeDir $item) -Force -ErrorAction Stop; $ok = $true; break }
                catch { Start-Sleep -Seconds 2 }
            }
            if (-not $ok) { throw "'$src' ist gesperrt und kann nicht ersetzt werden (Datei in einem anderen Programm geoeffnet?)." }
            $moved.Add($item)
        }
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Dir 'config') -Filter '*.py' -File -ErrorAction SilentlyContinue)) {
            $cfgBk = Join-Path $codeDir 'config'
            if (-not (Test-Path -LiteralPath $cfgBk)) { New-Item -ItemType Directory -Path $cfgBk -Force | Out-Null }
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $cfgBk $f.Name) -Force
            $moved.Add("config\$($f.Name)")
        }
    } catch {
        Write-Log "Alter Code konnte nicht vollstaendig verschoben werden - stelle Ausgangszustand wieder her." 'ERROR'
        Restore-OldCode -Dir $Dir -BackupDir $BackupDir -Moved $moved.ToArray()
        throw
    }
    Write-Log "Alter Code ins Backup verschoben ($($moved -join ', '))."
    return $moved.ToArray()
}

function Restore-OldCode {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$BackupDir,
          [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Moved)
    $codeDir = Join-Path $BackupDir 'code'
    foreach ($item in $Moved) {
        $dst = Join-Path $Dir $item
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue }
        $parent = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Move-Item -LiteralPath (Join-Path $codeDir $item) -Destination $dst -Force
    }
}

function Remove-NewCode {
    param([Parameter(Mandatory)][string]$Dir)
    foreach ($item in (Get-CodeItems)) {
        $p = Join-Path $Dir $item
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Get-ChildItem -LiteralPath (Join-Path $Dir 'config') -Filter '*.py' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Remove-OldBackups {
    param([Parameter(Mandatory)][string]$Dir)
    $bkRoot = Join-Path $Dir 'backups'
    if (-not (Test-Path -LiteralPath $bkRoot)) { return }
    $names = @(Get-ChildItem -LiteralPath $bkRoot -Directory | Select-Object -ExpandProperty Name)
    foreach ($n in (Get-BackupsToPrune -Names $names -Keep $BackupKeep)) {
        Remove-Item -LiteralPath (Join-Path $bkRoot $n) -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Altes Backup entfernt: $n"
    }
}

# ---- Ablaeufe ----
function Find-Installation {
    # Ermittelt eine bestehende Installation. Reihenfolge:
    #  1. Ordner des registrierten Dienstes (jede Version, auch 2.0.x mit venv)
    #  2. Standardordner C:\Alamos2Fireplan mit Daten/Code (Dienst fehlt, z. B.
    #     nach manueller Deinstallation des Dienstes)
    $reg = Get-ServiceRegistration -Name $ServiceName
    if ($reg -and $reg.AppDirectory -and (Test-Path -LiteralPath $reg.AppDirectory)) {
        return [pscustomobject]@{ Dir = $reg.AppDirectory.TrimEnd('\'); Registration = $reg }
    }
    if ($reg) {
        Write-Log "Dienst '$ServiceName' existiert, sein Ordner '$($reg.AppDirectory)' aber nicht." 'WARN'
    }
    foreach ($marker in @('config\.env', 'alarme.db', 'runserver.py')) {
        if (Test-Path -LiteralPath (Join-Path $InstallDir $marker)) {
            return [pscustomobject]@{ Dir = $InstallDir; Registration = $reg }
        }
    }
    return [pscustomobject]@{ Dir = $null; Registration = $reg }
}

function Invoke-FreshInstall {
    param([Parameter(Mandatory)][string]$Dir)
    Write-Step "Neuinstallation nach '$Dir'"
    Assert-FreeSpace -Dir (Split-Path $Dir -Qualifier)
    if (Test-PortInUse -Port 5000) {
        Write-Log 'Port 5000 wird bereits von einem anderen Programm verwendet - die Weboberflaeche kann so nicht starten.' 'WARN'
        if (-not (Read-YesNo 'Trotzdem fortfahren?' $false)) { throw 'Installation abgebrochen (Port 5000 belegt).' }
    }
    if (Test-ServiceExists $ServiceName) { Remove-AppService -Dir $Dir }

    Copy-PackageCode -Dir $Dir
    Set-LogTarget -Dir $Dir
    Register-AppService -Dir $Dir

    if (Read-YesNo 'Lokalen Mosquitto-Broker (MQTT) einrichten?' $true) { Setup-Mosquitto -Dir $Dir }

    Write-Step 'Start und Funktionspruefung'
    if (-not (Start-AppServiceVerified -Dir $Dir)) {
        throw "Alamos2Fireplan wurde installiert, startet aber nicht. Details: $Dir\logs\service.log und app.log"
    }
    Write-Log "Installation abgeschlossen. Ordner: $Dir - Weboberflaeche: http://localhost:$(Get-WebPort -Dir $Dir) (Standard-Passwort 112112 bitte aendern)" 'OK'
}

function Invoke-Update {
    param([Parameter(Mandatory)][string]$Dir, $Registration)
    $from = Get-InstalledVersion -Dir $Dir
    $to   = Get-PackageVersion
    $fromText = if ($from) { $from } else { 'unbekannt' }
    Write-Step "Update in '$Dir': v$fromText -> v$to"
    Set-LogTarget -Dir $Dir

    $cmp = Compare-AppVersion -A $to -B $from
    if ($cmp -eq -1) {
        Write-Log "Das Paket (v$to) ist AELTER als die Installation (v$from)." 'WARN'
        if (-not (Read-YesNo 'Wirklich auf die aeltere Version zuruecksetzen?' $false)) { throw 'Update abgebrochen (Downgrade nicht bestaetigt).' }
    } elseif ($cmp -eq 0) {
        Write-Log "Version v$to ist bereits installiert - Dateien und Dienst werden neu eingerichtet (Reparatur)."
    }
    if ($Registration -and $Registration.Application) {
        Write-Log "Bisheriger Dienst: $($Registration.Application) $($Registration.AppParameters)"
    }
    Assert-FreeSpace -Dir $Dir

    # 1) Stoppen - bis hier wurde nichts veraendert
    Write-Step 'Dienst stoppen'
    Stop-AppService -Dir $Dir

    $backupDir = Join-Path (Join-Path $Dir 'backups') (Get-BackupFolderName -Timestamp (Get-Date))
    $moved = @()
    $codeSwapped = $false
    try {
        # 2) Daten sichern (wird nie automatisch zurueckgespielt - nur Notfallkopie)
        Write-Step 'Daten sichern'
        Backup-Data -Dir $Dir -BackupDir $backupDir

        # 3) Alten Code beiseite legen, neuen Code einspielen
        Write-Step 'Programm aktualisieren'
        $moved = Move-OldCode -Dir $Dir -BackupDir $backupDir
        $codeSwapped = $true
        Copy-PackageCode -Dir $Dir

        # 4) Dienst IMMER neu registrieren (Migration alter venv-Installationen)
        Register-AppService -Dir $Dir

        # 5) Starten + echte Funktionspruefung
        Write-Step 'Start und Funktionspruefung'
        if (-not (Start-AppServiceVerified -Dir $Dir)) { throw 'Die neue Version startet nicht.' }
    } catch {
        $reason = $_.Exception.Message
        Write-Log "Update fehlgeschlagen: $reason" 'ERROR'
        if ($codeSwapped) {
            Write-Step 'Automatisches Zurueckrollen auf die vorherige Version'
            try {
                Stop-AppService -Dir $Dir
                Remove-NewCode -Dir $Dir
                Restore-OldCode -Dir $Dir -BackupDir $backupDir -Moved $moved
                if ($Registration -and $Registration.Application) {
                    Register-AppService -Dir $Dir -Application $Registration.Application `
                        -AppParameters $Registration.AppParameters
                } else {
                    Register-AppService -Dir $Dir
                }
                $back = Start-AppServiceVerified -Dir $Dir
                if (-not $back) {
                    # Sehr alte Versionen haben evtl. keine /login-Seite -> dann zaehlt,
                    # dass der Dienst stabil laeuft.
                    Start-Sleep -Seconds 5
                    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
                    $back = [bool]($svc -and $svc.Status -eq 'Running')
                }
                if ($back) {
                    Write-Log "Vorherige Version v$fromText wiederhergestellt und gestartet. Es gingen keine Daten verloren." 'WARN'
                } else {
                    Write-Log "Vorherige Version wiederhergestellt, startet aber ebenfalls nicht. Daten-Backup: $backupDir\data" 'ERROR'
                }
            } catch {
                Write-Log "Zurueckrollen fehlgeschlagen: $($_.Exception.Message). Alter Code: $backupDir\code, Daten: $backupDir\data" 'ERROR'
            }
        } else {
            # Nichts veraendert -> alten Dienst einfach wieder starten
            try { Start-Service -Name $ServiceName -ErrorAction Stop } catch { }
        }
        throw "Update auf v$to fehlgeschlagen: $reason"
    }

    Remove-OldBackups -Dir $Dir
    Write-Log "Update auf v$to abgeschlossen. Einstellungen und Datenbank wurden uebernommen. Backup: $backupDir" 'OK'
}

function Invoke-Repair {
    # Paket wurde direkt in den Installationsordner entpackt: Code ist bereits
    # da - nur Altlasten wegraeumen, Dienst neu registrieren und pruefen.
    param([Parameter(Mandatory)][string]$Dir)
    Write-Step "Reparatur der Installation in '$Dir'"
    Set-LogTarget -Dir $Dir
    Stop-AppService -Dir $Dir
    $backupDir = Join-Path (Join-Path $Dir 'backups') (Get-BackupFolderName -Timestamp (Get-Date))
    Backup-Data -Dir $Dir -BackupDir $backupDir
    foreach ($item in (Get-ObsoleteItems)) {
        $p = Join-Path $Dir $item
        if (Test-Path -LiteralPath $p) {
            $codeDir = Join-Path $backupDir 'code'
            New-Item -ItemType Directory -Path $codeDir -Force | Out-Null
            Move-Item -LiteralPath $p -Destination (Join-Path $codeDir $item) -Force
            Write-Log "Altlast '$item' ins Backup verschoben."
        }
    }
    Register-AppService -Dir $Dir
    if (-not (Start-AppServiceVerified -Dir $Dir)) { throw "Dienst startet nicht. Details: $Dir\logs\service.log und app.log" }
    Remove-OldBackups -Dir $Dir
    Write-Log 'Reparatur abgeschlossen.' 'OK'
}

function Invoke-Setup {
    Assert-Admin
    Enable-Tls12
    Write-Step 'Paket pruefen'
    Assert-Package

    $found = Find-Installation
    if (-not $found.Dir) {
        Write-Log 'Keine bestehende Installation gefunden.'
        Invoke-FreshInstall -Dir $InstallDir
        return
    }
    Write-Log "Bestehende Installation gefunden: '$($found.Dir)'."
    if (Test-PathInside -Path $ProjectDir -Root $found.Dir) {
        if ((Resolve-Path -LiteralPath $ProjectDir).Path.TrimEnd('\') -ieq (Resolve-Path -LiteralPath $found.Dir).Path.TrimEnd('\')) {
            Invoke-Repair -Dir $found.Dir
            return
        }
        throw "Das Paket liegt innerhalb des Installationsordners ($($found.Dir)). Bitte das ZIP an einem anderen Ort entpacken (z. B. Desktop) und install.bat von dort starten."
    }
    Invoke-Update -Dir $found.Dir -Registration $found.Registration
}

# ---- Mosquitto ----
function Get-MosquittoInstaller {
    $bundled = Get-ChildItem -LiteralPath (Join-Path $ProjectDir 'tools\mosquitto') -Filter 'mosquitto-*-install-windows-x64.exe' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($bundled) {
        Write-Log "Verwende mitgelieferten Mosquitto-Installer: $($bundled.Name)"
        return $bundled.FullName
    }
    $installer = Join-Path $env:TEMP "mosquitto-$MosqVersion-install.exe"
    Write-Log "Lade Mosquitto $MosqVersion herunter: $MosqUrl"
    Invoke-WebRequest -Uri $MosqUrl -OutFile $installer -UseBasicParsing
    return $installer
}

function Setup-Mosquitto {
    param([Parameter(Mandatory)][string]$Dir)
    Write-Step 'Mosquitto-Broker einrichten'
    try {
        $mosqExe = Join-Path $MosqDir 'mosquitto.exe'
        $mosqPw  = Join-Path $MosqDir 'mosquitto_passwd.exe'
        $py      = Join-Path $Dir 'tools\python\python.exe'

        # 1. Installieren, falls nicht vorhanden (NSIS-Installer -> /S = lautlos)
        if (-not (Test-Path -LiteralPath $mosqExe)) {
            $installer = Get-MosquittoInstaller
            Write-Log 'Installiere Mosquitto (silent, ohne Rueckfragen)...'
            $p = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru
            if ($p.ExitCode -and $p.ExitCode -ne 0) { throw "Mosquitto-Installer endete mit Code $($p.ExitCode)." }
            if (-not (Test-Path -LiteralPath $mosqExe)) { throw "Mosquitto wurde nicht nach $MosqDir installiert." }
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
        $ErrorActionPreference = 'Continue'
        & $mosqPw -b -c $PwFile $user $pass 2>&1 | Out-Null
        $pwCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($pwCode -ne 0) { throw "mosquitto_passwd schlug fehl (Code $pwCode)." }
        # mosquitto_passwd legt die Datei mit den Rechten des (Admin-)Benutzers an.
        # Der Broker-Dienst laeuft als LocalSystem (SID S-1-5-18) -> Leserecht geben,
        # sonst "Unable to open pwfile" und der Broker startet nicht.
        $acl = Get-Acl -LiteralPath $PwFile
        $sysSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sysSid, 'Read', 'Allow')))
        Set-Acl -LiteralPath $PwFile -AclObject $acl
        Write-Log "MQTT-Benutzer '$user' angelegt (Leserecht fuer Dienst-Konto gesetzt)."

        # 4. mosquitto.conf schreiben (UTF-8 OHNE BOM - sonst ist die erste Zeile ungueltig)
        $conf = @(
            'allow_anonymous false',
            "password_file $PwFile",
            'listener 1883'
        )
        [System.IO.File]::WriteAllLines((Join-Path $MosqDir 'mosquitto.conf'), $conf, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log 'mosquitto.conf geschrieben.'

        # 5. Dienst via NSSM registrieren. mosquittos eigener Dienst-Modus laedt die
        #    conf nicht zuverlaessig (Arbeitsverzeichnis System32), 'run -c' bricht
        #    das Dienst-Protokoll (Fehler 1053). NSSM startet den Vordergrund-Befehl.
        $a2fNssm  = Join-Path $Dir 'tools\nssm.exe'
        $mosqNssm = Join-Path $MosqDir 'nssm.exe'

        Invoke-Nssm -NssmPath $a2fNssm stop mosquitto | Out-Null
        Invoke-Nssm -NssmPath $a2fNssm remove mosquitto confirm | Out-Null
        foreach ($i in 1..20) {
            if (-not (Test-ServiceExists 'mosquitto')) { break }
            Start-Sleep -Milliseconds 500
        }

        # nssm.exe neben mosquitto legen -> Broker-Dienst unabhaengig vom A2F-Ordner.
        Copy-Item -LiteralPath $a2fNssm -Destination $mosqNssm -Force

        $mosqLog = Join-Path (Split-Path $PwFile -Parent) 'mosquitto-service.log'
        Invoke-Nssm -NssmPath $mosqNssm install mosquitto $mosqExe | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "nssm install mosquitto schlug fehl (Code $LASTEXITCODE)." }
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppDirectory $MosqDir | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppParameters "-c mosquitto.conf -v" | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppStdout $mosqLog | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppStderr $mosqLog | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppRotateFiles 1 | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppRotateOnline 1 | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto AppRotateBytes 1048576 | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto Start SERVICE_AUTO_START | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm set mosquitto DisplayName 'Mosquitto Broker' | Out-Null
        Invoke-Nssm -NssmPath $mosqNssm start mosquitto | Out-Null
        Write-Log "Mosquitto-Dienst (via NSSM) registriert und gestartet. Broker-Log: $mosqLog"

        # 5b. Wirklich verifizieren, dass der Broker auf 1883 lauscht
        $listening = $false
        foreach ($try in 1..10) {
            Start-Sleep -Seconds 1
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.Connect('127.0.0.1', 1883)
                $listening = $tcp.Connected
                $tcp.Close()
            } catch { $listening = $false }
            if ($listening) { break }
        }
        if ($listening) {
            Write-Log 'Mosquitto laeuft und lauscht auf 127.0.0.1:1883.' 'OK'
        } else {
            Write-Log 'ACHTUNG: Mosquitto lauscht NICHT auf 1883 - der Broker ist beim Start abgebrochen.' 'WARN'
            Write-Log "Der genaue Grund steht im Broker-Log: $mosqLog" 'WARN'
        }

        # 6. config\.env im Installationsordner sicherstellen und MQTT-Schluessel setzen
        Push-Location $Dir
        try {
            $ErrorActionPreference = 'Continue'
            & $py -c 'import config' 2>&1 | Out-Null
        } finally { Pop-Location; $ErrorActionPreference = 'Stop' }
        $envPath = Join-Path $Dir 'config\.env'
        Update-EnvFile -Path $envPath -Values @{
            MQTT_BROKER   = '127.0.0.1'
            MQTT_PORT     = '1883'
            MQTT_USERNAME = $user
            MQTT_PASSWORD = $pass
        } | Out-Null
        Write-Log 'MQTT-Zugangsdaten in config\.env uebernommen.'

        # 7. Firewall optional
        if (Read-YesNo 'Port 1883 in der Firewall freigeben (Zugriff von anderem Rechner)?' $false) {
            if (-not (Get-NetFirewallRule -DisplayName 'Mosquitto MQTT 1883' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName 'Mosquitto MQTT 1883' -Direction Inbound `
                    -Protocol TCP -LocalPort 1883 -Action Allow -ErrorAction SilentlyContinue | Out-Null
            }
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

        $topic  = Get-EnvValue -Path $envPath -Key 'MQTT_TOPIC'
        $sTopic = Get-EnvValue -Path $envPath -Key 'MQTT_STATUS_TOPIC'
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
        Write-Host '  QoS (empfohlen)        : 1' -ForegroundColor Cyan
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

function Uninstall-Mosquitto {
    try {
        $uninst   = Join-Path $MosqDir 'Uninstall.exe'
        $mosqNssm = Join-Path $MosqDir 'nssm.exe'
        $nssm     = if (Test-Path -LiteralPath $mosqNssm) { $mosqNssm } else { Join-Path $ProjectDir 'tools\nssm.exe' }

        if (Test-ServiceExists 'mosquitto') {
            Stop-Service -Name 'mosquitto' -Force -ErrorAction SilentlyContinue
            # Dienst wurde von uns via NSSM angelegt -> auch via NSSM entfernen
            # (der Mosquitto-Uninstaller kennt diesen Dienst nicht).
            Invoke-Nssm -NssmPath $nssm remove mosquitto confirm | Out-Null
            if (Test-ServiceExists 'mosquitto') { & sc.exe delete mosquitto | Out-Null }
            Write-Log 'Mosquitto-Dienst entfernt.'
        }
        if (Test-Path -LiteralPath $uninst) {
            Write-Log 'Deinstalliere Mosquitto (silent)...'
            Start-Process -FilePath $uninst -ArgumentList '/S' -Wait
            Write-Log 'Mosquitto deinstalliert.'
        } else {
            Write-Log 'Mosquitto-Uninstaller nicht gefunden (evtl. nicht installiert).' 'WARN'
        }
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

# ---- Deinstallation ----
function Save-UninstallData {
    # Letzte Datensicherung VOR dem Loeschen des Ordners - ausserhalb davon.
    param([Parameter(Mandatory)][string]$Dir)
    $dest = Join-Path (Split-Path $Dir -Qualifier) ('\Alamos2Fireplan-Datensicherung_' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Backup-Data -Dir $Dir -BackupDir $dest
    Write-Log "Daten gesichert nach '$dest\data'. Fuer eine spaetere Neuinstallation dorthin zurueckkopieren." 'OK'
}

function Remove-InstallDir {
    # Der laufende Prozess (setup.ps1/uninstall.bat) liegt i. d. R. IM zu
    # loeschenden Ordner -> ein losgeloester Helfer wartet, bis alle Dateien frei
    # sind, loescht den Ordner und raeumt sich selbst weg (gibt nach ~5 min auf).
    param([Parameter(Mandatory)][string]$Dir)
    $deleter = Join-Path $env:TEMP ("a2f_uninstall_" + [guid]::NewGuid().ToString("N") + ".cmd")
    $lines = @(
        '@echo off',
        'cd /d C:\',
        'set /a n=0',
        ':retry',
        ('rmdir /s /q "' + $Dir + '" 2>nul'),
        ('if not exist "' + $Dir + '" goto done'),
        'set /a n+=1',
        'if %n% geq 150 goto done',
        'ping 127.0.0.1 -n 3 >nul',
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
    if (-not (Read-YesNo "Dienst '$ServiceName' wirklich entfernen?" $false)) { Write-Log 'Deinstallation abgebrochen.'; return }

    $found = Find-Installation
    $dir = if ($found.Dir) { $found.Dir } else { $InstallDir }

    Remove-AppService -Dir $dir

    if (Read-YesNo 'Lokalen Mosquitto-Broker ebenfalls deinstallieren?' $false) { Uninstall-Mosquitto }
    else { Write-Log 'Mosquitto bleibt erhalten.' }

    if ((Test-Path -LiteralPath $dir) -and (Read-YesNo "Installationsordner '$dir' komplett loeschen?" $false)) {
        if (Read-YesNo 'Vorher Einstellungen und Datenbank ausserhalb des Ordners sichern?' $true) {
            Save-UninstallData -Dir $dir
        }
        Remove-InstallDir -Dir $dir
    } else {
        Write-Log "Installationsordner '$dir' bleibt erhalten."
    }
    Write-Log 'Deinstallation abgeschlossen.' 'OK'
}

# ---- Dispatch ----
# Nur ausfuehren, wenn das Skript direkt gestartet wird (nicht beim Dot-Sourcing
# durch Tests). Beim Dot-Sourcing ist InvocationName '.'.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Write-Log "setup.ps1 gestartet im Modus '$Mode' (Paket: $ProjectDir, PowerShell $($PSVersionTable.PSVersion))."
        switch ($Mode) {
            'install'   { Invoke-Setup }
            'uninstall' { Invoke-Uninstall }
        }
        exit 0
    }
    catch {
        Write-Log $_.Exception.Message 'ERROR'
        Write-Host ''
        Write-Host "Protokoll: $script:SetupLog" -ForegroundColor Yellow
        exit 1
    }
}
