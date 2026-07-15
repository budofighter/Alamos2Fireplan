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

# ---- Dispatch (Platzhalter, in Folgetasks gefüllt) ----
try {
    Write-Log "setup.ps1 gestartet im Modus '$Mode'."
    switch ($Mode) {
        'install'   { Invoke-Install }
        'update'    { Write-Log 'Update-Flow folgt in Task 6.' }
        'uninstall' { Write-Log 'Uninstall-Flow folgt in Task 7.' }
    }
    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
