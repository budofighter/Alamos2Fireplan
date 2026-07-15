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
$PyVersion   = '3.12.8'
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
    $nssm = Get-Nssm
    & $nssm stop $ServiceName 2>$null | Out-Null
    & $nssm remove $ServiceName confirm 2>$null | Out-Null
    Write-Log "Vorhandener Dienst '$ServiceName' gestoppt/entfernt (falls vorhanden)."
}

function Install-Service {
    $nssm = Get-Nssm
    if (-not (Test-Path -LiteralPath $nssm)) { throw "NSSM fehlt unter $nssm." }
    Remove-Service
    & $nssm install $ServiceName $PythonExe $RunServer
    if ($LASTEXITCODE -ne 0) { throw "nssm install schlug fehl (Code $LASTEXITCODE)." }
    & $nssm set $ServiceName AppDirectory $ProjectDir | Out-Null
    & $nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
    & $nssm set $ServiceName ObjectName LocalSystem | Out-Null
    & $nssm set $ServiceName AppStdout (Join-Path $LogDir 'service.log') | Out-Null
    & $nssm set $ServiceName AppStderr (Join-Path $LogDir 'service.log') | Out-Null
    & $nssm set $ServiceName AppRotateFiles 1 | Out-Null
    & $nssm set $ServiceName AppRotateBytes 1048576 | Out-Null
    Write-Log "Dienst '$ServiceName' registriert (Logging → logs/service.log)."
}

function Assert-ServiceStarted {
    $nssm = Get-Nssm
    $status = (& $nssm status $ServiceName) 2>$null
    if ("$status".Trim() -notmatch 'SERVICE_RUNNING') {
        throw "Dienst '$ServiceName' läuft nicht (Status: $status). Siehe logs/service.log."
    }
    Write-Log "Dienst '$ServiceName' läuft."
}

# Temporärer Stub — wird in Task 8 ersetzt.
function Setup-Mosquitto { Write-Log 'Mosquitto-Setup wird in Task 8 implementiert.' }

function Invoke-Install {
    Assert-Admin
    Test-Python | Out-Null
    Install-Service

    $answer = Read-Host 'Lokalen Mosquitto-Broker einrichten? (j/n)'
    if ($answer -match '^(j|J)') { Setup-Mosquitto }

    & (Get-Nssm) start $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Assert-ServiceStarted
    Write-Log "Installation abgeschlossen. Weboberfläche: http://localhost:5000"
}

function Get-ServiceDir {
    $nssm = Get-Nssm
    $dir = (& $nssm get $ServiceName AppDirectory) 2>$null
    $dir = "$dir".Trim()
    if ([string]::IsNullOrWhiteSpace($dir)) {
        throw "Dienst '$ServiceName' nicht gefunden. Bitte zuerst install.bat ausführen."
    }
    return $dir
}

function Invoke-Update {
    Assert-Admin
    $target = Get-ServiceDir
    Write-Log "Update-Ziel automatisch erkannt: $target"
    $nssm = Get-Nssm

    Write-Log 'Stoppe Dienst für Update...'
    & $nssm stop $ServiceName | Out-Null
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
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
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

    & $nssm start $ServiceName | Out-Null
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
