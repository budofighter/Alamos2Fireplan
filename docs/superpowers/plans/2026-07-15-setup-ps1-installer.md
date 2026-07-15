# setup.ps1 Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ersetze die drei fehlerhaften Batch-Skripte durch ein einheitliches `setup.ps1` (Modi install/update/uninstall) mit gebündeltem Embeddable Python, Auto-Erkennung des Update-Ziels inkl. Backup und optionalem Mosquitto-Setup, doppelklickbar über schlanke `.bat`-Wrapper.

**Architecture:** Reine Logik (`.env`-Patchen, Update-Kopierauswahl, Backup-Auswahl) liegt in einer dot-sourcebaren `setup.lib.ps1` und wird mit Pester getestet (TDD). `setup.ps1` orchestriert und kapselt alle Windows-Seiteneffekte (NSSM-Dienst, Downloads, Mosquitto). Drei `.bat`-Wrapper erledigen UAC-Elevation und rufen `setup.ps1` mit dem passenden Modus auf. `package.bat` baut das Auslieferungs-ZIP inkl. Embeddable Python.

**Tech Stack:** Windows PowerShell / PowerShell 7 (pwsh), Pester 5 (Tests), NSSM (Dienstverwaltung), Python 3.12 Embeddable, Mosquitto 2.0 (optional), Batch (Wrapper).

## Global Constraints

- **Dienstname (SERVICE_NAME):** `Alamos2Fireplan` (exakt, überall identisch).
- **Python-Version (Embeddable, x64):** `3.12.8` — URL `https://www.python.org/ftp/python/3.12.8/python-3.12.8-embed-amd64.zip`. Bei Aktualisierung bewusst ändern.
- **Mosquitto-Version (x64-Installer):** `2.0.20` — URL `https://mosquitto.org/files/binary/win64/mosquitto-2.0.20-install-windows-x64.exe`. Bei Aktualisierung bewusst ändern.
- **pwfile-Pfad (ohne Leerzeichen):** `C:\ProgramData\Alamos2Fireplan\pwfile.txt`.
- **Dienstkonto:** `LocalSystem` (unverändert, kein Wechsel).
- **Update schont immer:** `config/`, `alarme.db`, `logs/`, `backups/` — werden nie überschrieben.
- **Update aktualisiert (Allowlist):** `app/`, `backend/`, `tools/`, `runserver.py`, `requirements.txt`, `setup.ps1`, `setup.lib.ps1`, `install.bat`, `update.bat`, `uninstall.bat`.
- **`pywin32` ist entfernt** (nirgends im Code importiert).
- **Alle Skripte:** `$ErrorActionPreference = 'Stop'`, jede Phase in `try/catch`, Logging nach `logs/setup.log`, keine per `>nul 2>&1` verschluckten Fehler.
- **Encoding:** Alle geschriebenen Textdateien UTF-8.

---

## File Structure

- Create: `setup.lib.ps1` — reine Hilfsfunktionen (`Update-EnvFile`, `Get-UpdateCopyPlan`, `Get-BackupItems`, `Get-BackupFolderName`). Keine Seiteneffekte auf System/Dienst.
- Create: `setup.ps1` — Orchestrierung + Seiteneffekte (`Assert-Admin`, `Write-Log`, `Get-Nssm`, `Test-Python`, `Install-Service`, `Remove-Service`, `Get-ServiceDir`, `Assert-ServiceStarted`, `Setup-Mosquitto`, Modus-Dispatch).
- Create/Replace: `install.bat`, `update.bat`, `uninstall.bat` — Thin-Wrapper mit UAC-Elevation.
- Modify: `package.bat` — Embeddable Python bündeln, neue Dateien ins ZIP.
- Modify: `requirements.txt` — `pywin32`-Zeile entfernen.
- Create: `tests/setup.Tests.ps1` — Pester-Tests für `setup.lib.ps1`.
- Create: `tests/README.md` — wie man die Tests ausführt.

---

### Task 1: Test-Harness + `Update-EnvFile` (TDD)

Erste reine Funktion: MQTT-Schlüssel in `config/.env` patchen, ohne bestehende Zeilen zu verlieren (Kern der Credential-Synchronisation, Spec §9.8).

**Files:**
- Create: `setup.lib.ps1`
- Create: `tests/setup.Tests.ps1`
- Create: `tests/README.md`

**Interfaces:**
- Produces: `Update-EnvFile -Path <string> -Values <hashtable>` → gibt das resultierende String-Array der Zeilen zurück und schreibt die Datei (UTF-8). Vorhandene Schlüssel werden an Ort und Stelle ersetzt, fehlende ans Ende angehängt, alle anderen Zeilen bleiben erhalten.

- [ ] **Step 1: Pester 5 sicherstellen**

Run:
```powershell
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0.0' })) {
  Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
}
Get-Module -ListAvailable Pester | Select-Object Version | Sort-Object Version -Descending | Select-Object -First 1
```
Expected: Eine Version `>= 5.0.0` wird angezeigt.

- [ ] **Step 2: `tests/README.md` schreiben**

```markdown
# Tests

Reine Logik aus `setup.lib.ps1` wird mit Pester 5 getestet.

## Ausführen
```powershell
Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed
```

Die System-Integration (Dienst, Mosquitto) ist nicht unit-testbar und wird
durch Ausführen von `install.bat` / `update.bat` auf einem Windows-Host geprüft
(siehe Implementierungsplan, Verifikationsschritte je Task).
```

- [ ] **Step 3: Failing test für `Update-EnvFile` schreiben**

`tests/setup.Tests.ps1`:
```powershell
BeforeAll {
    . "$PSScriptRoot/../setup.lib.ps1"
}

Describe 'Update-EnvFile' {
    It 'ersetzt vorhandene Schlüssel und erhält andere Zeilen' {
        $tmp = Join-Path $TestDrive '.env'
        Set-Content -LiteralPath $tmp -Value @(
            'MQTT_BROKER=127.0.0.1',
            'MQTT_USERNAME=alt',
            'FIREPLAN_SECRET=geheim'
        ) -Encoding UTF8

        $result = Update-EnvFile -Path $tmp -Values @{ MQTT_USERNAME = 'neu'; MQTT_PASSWORD = 'pw' }

        $result | Should -Contain 'MQTT_USERNAME=neu'
        $result | Should -Contain 'MQTT_PASSWORD=pw'
        $result | Should -Contain 'FIREPLAN_SECRET=geheim'
        ($result | Where-Object { $_ -like 'MQTT_USERNAME=*' }).Count | Should -Be 1
    }

    It 'legt Schlüssel an, wenn die Datei fehlt' {
        $tmp = Join-Path $TestDrive 'neu.env'
        $result = Update-EnvFile -Path $tmp -Values @{ MQTT_PORT = '1883' }
        $result | Should -Contain 'MQTT_PORT=1883'
        (Test-Path $tmp) | Should -BeTrue
    }
}
```

- [ ] **Step 4: Test ausführen, Fehlschlag verifizieren**

Run: `Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed`
Expected: FAIL — `Update-EnvFile` ist nicht definiert.

- [ ] **Step 5: `setup.lib.ps1` mit `Update-EnvFile` anlegen**

```powershell
# setup.lib.ps1 — reine Hilfsfunktionen (keine System-Seiteneffekte).
# Dot-sourced von setup.ps1 und von den Pester-Tests.

function Update-EnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $lines = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path) } else { @() }
    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($line in $lines) {
        $matched = $false
        foreach ($key in $Values.Keys) {
            if ($line -match ('^\s*' + [regex]::Escape($key) + '=')) {
                $result.Add("$key=$($Values[$key])")
                $seen[$key] = $true
                $matched = $true
                break
            }
        }
        if (-not $matched) { $result.Add($line) }
    }
    foreach ($key in $Values.Keys) {
        if (-not $seen.ContainsKey($key)) { $result.Add("$key=$($Values[$key])") }
    }
    Set-Content -LiteralPath $Path -Value $result -Encoding UTF8
    return $result.ToArray()
}
```

- [ ] **Step 6: Test ausführen, Erfolg verifizieren**

Run: `Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed`
Expected: PASS (2 Tests grün).

- [ ] **Step 7: Commit**

```bash
git add setup.lib.ps1 tests/setup.Tests.ps1 tests/README.md
git commit -m "feat(setup): Update-EnvFile mit Pester-Tests"
```

---

### Task 2: `Get-UpdateCopyPlan` (TDD)

Regressionstest gegen Bug #2/#7: Update kopiert **nur** die Allowlist und **nie** `config`, `.env`, `alarme.db`, `logs`, `backups`.

**Files:**
- Modify: `setup.lib.ps1`
- Modify: `tests/setup.Tests.ps1`

**Interfaces:**
- Consumes: —
- Produces: `Get-UpdateCopyPlan -SourceItems <string[]>` → gefiltertes String-Array; enthält nur Elemente aus der Allowlist (siehe Global Constraints).

- [ ] **Step 1: Failing test schreiben**

An `tests/setup.Tests.ps1` anhängen:
```powershell
Describe 'Get-UpdateCopyPlan' {
    It 'behält nur Code-Elemente und schließt Daten aus' {
        $items = @('app','backend','tools','runserver.py','requirements.txt',
                   'setup.ps1','setup.lib.ps1','install.bat','update.bat','uninstall.bat',
                   'config','alarme.db','logs','backups','.env','README.md')
        $plan = Get-UpdateCopyPlan -SourceItems $items

        $plan | Should -Contain 'app'
        $plan | Should -Contain 'backend'
        $plan | Should -Contain 'setup.ps1'
        $plan | Should -Not -Contain 'config'
        $plan | Should -Not -Contain 'alarme.db'
        $plan | Should -Not -Contain 'logs'
        $plan | Should -Not -Contain 'backups'
        $plan | Should -Not -Contain '.env'
    }
}
```

- [ ] **Step 2: Test ausführen, Fehlschlag verifizieren**

Run: `Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed`
Expected: FAIL — `Get-UpdateCopyPlan` nicht definiert.

- [ ] **Step 3: Funktion in `setup.lib.ps1` ergänzen**

```powershell
function Get-UpdateCopyPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$SourceItems)
    $include = @('app','backend','tools','runserver.py','requirements.txt',
                 'setup.ps1','setup.lib.ps1','install.bat','update.bat','uninstall.bat')
    return @($SourceItems | Where-Object { $include -contains $_ })
}
```

- [ ] **Step 4: Test ausführen, Erfolg verifizieren**

Run: `Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed`
Expected: PASS (alle Tests grün).

- [ ] **Step 5: Commit**

```bash
git add setup.lib.ps1 tests/setup.Tests.ps1
git commit -m "feat(setup): Get-UpdateCopyPlan mit Allowlist-Regressionstest"
```

---

### Task 3: Backup-Auswahl `Get-BackupItems` + `Get-BackupFolderName` (TDD)

**Files:**
- Modify: `setup.lib.ps1`
- Modify: `tests/setup.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-BackupItems -TargetItems <string[]>` → gefiltertes Array; enthält nur `config`, `alarme.db`, `logs`, sofern vorhanden.
  - `Get-BackupFolderName -Timestamp <datetime>` → `backup_yyyyMMdd-HHmmss` (deterministisch aus dem übergebenen Zeitstempel).

- [ ] **Step 1: Failing tests schreiben**

An `tests/setup.Tests.ps1` anhängen:
```powershell
Describe 'Get-BackupItems' {
    It 'wählt nur vorhandene schützenswerte Elemente' {
        $items = @('app','config','alarme.db','logs','backups','runserver.py')
        $backup = Get-BackupItems -TargetItems $items
        $backup | Should -Contain 'config'
        $backup | Should -Contain 'alarme.db'
        $backup | Should -Contain 'logs'
        $backup | Should -Not -Contain 'app'
        $backup | Should -Not -Contain 'backups'
    }
}

Describe 'Get-BackupFolderName' {
    It 'formatiert den Zeitstempel deterministisch' {
        $ts = [datetime]'2026-07-15T13:05:09'
        Get-BackupFolderName -Timestamp $ts | Should -Be 'backup_20260715-130509'
    }
}
```

- [ ] **Step 2: Test ausführen, Fehlschlag verifizieren**

Run: `Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed`
Expected: FAIL — Funktionen nicht definiert.

- [ ] **Step 3: Funktionen in `setup.lib.ps1` ergänzen**

```powershell
function Get-BackupItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$TargetItems)
    $backup = @('config','alarme.db','logs')
    return @($TargetItems | Where-Object { $backup -contains $_ })
}

function Get-BackupFolderName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$Timestamp)
    return 'backup_' + $Timestamp.ToString('yyyyMMdd-HHmmss')
}
```

- [ ] **Step 4: Test ausführen, Erfolg verifizieren**

Run: `Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed`
Expected: PASS (alle Tests grün).

- [ ] **Step 5: Commit**

```bash
git add setup.lib.ps1 tests/setup.Tests.ps1
git commit -m "feat(setup): Backup-Auswahl und Ordnernamen mit Tests"
```

---

### Task 4: `setup.ps1` Grundgerüst (Dispatch, Logging, Admin, Nssm, Python)

Rahmen, der die Lib dot-sourced und die gemeinsamen Seiteneffekt-Funktionen bereitstellt. Noch kein Dienst — nur Gerüst + Hilfen (behebt Nr. 1, 4, 9).

**Files:**
- Create: `setup.ps1`

**Interfaces:**
- Consumes: `setup.lib.ps1` (dot-sourced).
- Produces (für Folgetasks):
  - `Write-Log -Message <string> -Level <string>` (Default Level `INFO`) → Konsole + `logs/setup.log`.
  - `Get-Nssm` → voller Pfad `<ProjectDir>\tools\nssm.exe`.
  - `Assert-Admin` → wirft bei fehlender Elevation eine terminierende Exception mit klarer Meldung.
  - `Test-Python` → `$true`, wenn `<ProjectDir>\tools\python\python.exe` existiert und `--version` liefert; sonst terminierende Exception.
  - Skript-Variablen: `$ServiceName`, `$ProjectDir`, `$PythonExe`, `$RunServer`, `$LogDir`.

- [ ] **Step 1: `setup.ps1` Grundgerüst schreiben**

```powershell
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

# ---- Dispatch (Platzhalter, in Folgetasks gefüllt) ----
try {
    Write-Log "setup.ps1 gestartet im Modus '$Mode'."
    switch ($Mode) {
        'install'   { Write-Log 'Install-Flow folgt in Task 5.' }
        'update'    { Write-Log 'Update-Flow folgt in Task 6.' }
        'uninstall' { Write-Log 'Uninstall-Flow folgt in Task 7.' }
    }
    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
```

- [ ] **Step 2: Gerüst manuell verifizieren (als Admin-Konsole)**

Run: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Mode install`
Expected: Ausgabe enthält „setup.ps1 gestartet im Modus 'install'." und „Install-Flow folgt in Task 5."; `logs/setup.log` wurde angelegt und enthält dieselben Zeilen; Exit-Code 0.

- [ ] **Step 3: Nicht-Admin-Abbruch später prüfbar — Syntax-Check jetzt**

Run: `pwsh -NoProfile -Command "& { . .\setup.lib.ps1; 'lib ok' }"`
Expected: `lib ok` (Lib lädt fehlerfrei, keine Syntaxfehler).

- [ ] **Step 4: Commit**

```bash
git add setup.ps1
git commit -m "feat(setup): setup.ps1 Grundgerüst mit Logging/Admin/Nssm/Python"
```

---

### Task 5: Install-Flow + `Install-Service` / `Assert-ServiceStarted`

NSSM-Dienst mit Logging registrieren und ehrlich prüfen (behebt Nr. 5, 6). Mosquitto-Abfrage ruft in Task 8 gefüllte `Setup-Mosquitto` auf; hier zunächst als No-Op-Stub, damit der Flow lauffähig ist.

**Files:**
- Modify: `setup.ps1`

**Interfaces:**
- Consumes: `Get-Nssm`, `Write-Log`, `Test-Python`, `Assert-Admin`.
- Produces:
  - `Install-Service` → registriert/überschreibt den Dienst inkl. Logging-Parameter.
  - `Remove-Service` → stoppt + entfernt den Dienst (idempotent).
  - `Assert-ServiceStarted` → wirft, wenn `nssm status` nicht `SERVICE_RUNNING` liefert.
  - `Invoke-Install` → kompletter Install-Ablauf.
  - `Setup-Mosquitto` → in Task 8 implementiert; hier temporärer Stub, der nur loggt.

- [ ] **Step 1: Funktionen in `setup.ps1` ergänzen (vor dem Dispatch-`try`)**

```powershell
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
```

- [ ] **Step 2: Dispatch für `install` verdrahten**

Ersetze im Dispatch-`switch` die Zeile
`'install'   { Write-Log 'Install-Flow folgt in Task 5.' }`
durch
`'install'   { Invoke-Install }`

- [ ] **Step 3: Install real ausführen (Admin-Konsole, Testverzeichnis)**

Voraussetzung: `tools\python\python.exe` vorhanden (Task 11 baut das Paket; für diesen Test entweder Paket nutzen oder Embeddable manuell nach `tools\python\` legen).
Run: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Mode install` → bei der Mosquitto-Frage `n`.
Expected:
- `sc query Alamos2Fireplan` → `STATE: 4 RUNNING`.
- `logs/service.log` existiert.
- `http://localhost:5000` liefert die Login-Seite.
- `logs/setup.log` enthält „Dienst 'Alamos2Fireplan' läuft." und „Installation abgeschlossen".

- [ ] **Step 4: Fehlerpfad prüfen (ehrliche Meldung)**

Dienst manuell stoppen, `runserver.py` temporär unbrauchbar machen (z. B. Datei umbenennen), erneut installieren.
Expected: `Assert-ServiceStarted` wirft; Ausgabe (rot) „Dienst 'Alamos2Fireplan' läuft nicht … Siehe logs/service.log."; Exit-Code 1. Danach `runserver.py` zurückbenennen.

- [ ] **Step 5: Commit**

```bash
git add setup.ps1
git commit -m "feat(setup): Install-Flow mit NSSM-Logging und echter Startprüfung"
```

---

### Task 6: Update-Flow (Auto-Ziel, Backup, Code-Kopie)

Behebt Nr. 1, 2, 7. Nutzt die getesteten Lib-Funktionen aus Task 2/3.

**Files:**
- Modify: `setup.ps1`

**Interfaces:**
- Consumes: `Get-Nssm`, `Write-Log`, `Get-UpdateCopyPlan`, `Get-BackupItems`, `Get-BackupFolderName`, `Assert-ServiceStarted`.
- Produces:
  - `Get-ServiceDir` → `AppDirectory` des Dienstes (getrimmt); wirft, wenn der Dienst fehlt.
  - `Invoke-Update` → kompletter Update-Ablauf; Quelle = `$PSScriptRoot` (neues Paket), Ziel = `Get-ServiceDir`.

- [ ] **Step 1: Funktionen ergänzen**

```powershell
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
```

- [ ] **Step 2: Dispatch für `update` verdrahten**

Ersetze `'update'    { Write-Log 'Update-Flow folgt in Task 6.' }` durch `'update'    { Invoke-Update }`.

- [ ] **Step 3: Update real ausführen und Datenschutz prüfen**

Voraussetzung: Task 5 hat einen laufenden Dienst installiert. In der Ziel-Installation eine Markierung setzen: bekannte Zeile in `config/.env` (z. B. `FIREPLAN_SECRET=TESTMARKER`) und einen Alarm in der DB (oder DB-Zeitstempel notieren).
Aus einem **anderen** Ordner (simuliertes neues Paket, gleiche Skripte) `setup.ps1 -Mode update` ausführen.
Expected:
- `logs/setup.log`: „Update-Ziel automatisch erkannt: <Zielpfad>".
- `<Ziel>\backups\backup_<zeitstempel>\` enthält `config`, `alarme.db`, `logs`.
- `config/.env` im Ziel enthält weiterhin `FIREPLAN_SECRET=TESTMARKER` (unverändert).
- `alarme.db` unverändert (gleiche Größe/Änderungszeit wie vor dem Update).
- Dienst läuft wieder (`sc query Alamos2Fireplan` → RUNNING).

- [ ] **Step 4: Commit**

```bash
git add setup.ps1
git commit -m "feat(setup): Update-Flow mit Auto-Ziel, Backup und Code-only-Kopie"
```

---

### Task 7: Uninstall-Flow

**Files:**
- Modify: `setup.ps1`

**Interfaces:**
- Consumes: `Remove-Service`, `Write-Log`, `Assert-Admin`.
- Produces: `Invoke-Uninstall` → Bestätigung, Dienst entfernen, optionale Aufräumabfragen.

- [ ] **Step 1: Funktion ergänzen**

```powershell
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
```

- [ ] **Step 2: Dispatch für `uninstall` verdrahten**

Ersetze `'uninstall' { Write-Log 'Uninstall-Flow folgt in Task 7.' }` durch `'uninstall' { Invoke-Uninstall }`.

- [ ] **Step 3: Uninstall real ausführen**

Run (Admin): `pwsh -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Mode uninstall` → `j`, Python/Backups nach Wunsch `n`.
Expected: `sc query Alamos2Fireplan` → „Der angegebene Dienst ist kein installierter Dienst"; `logs/setup.log` protokolliert die Entfernung.

- [ ] **Step 4: Commit**

```bash
git add setup.ps1
git commit -m "feat(setup): Uninstall-Flow mit optionalen Aufräumabfragen"
```

---

### Task 8: `Setup-Mosquitto` (Download, Install, Credentials, Config, Firewall)

Ersetzt den Stub aus Task 5. Umsetzung Spec §9.

**Files:**
- Modify: `setup.ps1`

**Interfaces:**
- Consumes: `Write-Log`, `Update-EnvFile`, `$PythonExe`, `$PwFile`, `$MosqUrl`.
- Produces: `Setup-Mosquitto` → richtet lokalen Broker ein und synchronisiert Credentials nach `config/.env`.

- [ ] **Step 1: Stub durch echte Funktion ersetzen**

```powershell
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
```

- [ ] **Step 2: Install mit Mosquitto ausführen**

Run (Admin): `pwsh -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -Mode install` → Mosquitto-Frage `j`, Benutzer/Passwort eingeben, Firewall nach Wunsch.
Expected:
- `Get-Service mosquitto` → `Running`.
- `C:\Program Files\mosquitto\mosquitto.conf` enthält die drei Zeilen.
- `C:\ProgramData\Alamos2Fireplan\pwfile.txt` existiert.
- `config/.env` enthält `MQTT_USERNAME=<user>` und `MQTT_PASSWORD=<pass>`.

- [ ] **Step 3: Broker-Login verifizieren**

Run: `& 'C:\Program Files\mosquitto\mosquitto_sub.exe' -h 127.0.0.1 -p 1883 -u <user> -P <pass> -t 'test' -C 1 -W 3`
Expected: Kein Auth-Fehler (Timeout nach 3 s ist ok — Verbindung/Anmeldung hat funktioniert). Mit falschem Passwort: „Connection Refused: not authorised".

- [ ] **Step 4: Commit**

```bash
git add setup.ps1
git commit -m "feat(setup): optionales Mosquitto-Setup mit Credential-Sync"
```

---

### Task 9: Thin-`.bat`-Wrapper mit UAC-Elevation

Ersetzt die alten `install.bat` / `update.bat` / `uninstall.bat`.

**Files:**
- Replace: `install.bat`
- Replace: `update.bat`
- Replace: `uninstall.bat`

**Interfaces:**
- Consumes: `setup.ps1` (Modus-Parameter).

- [ ] **Step 1: `install.bat` schreiben**

```bat
@echo off
chcp 65001 >nul
:: UAC-Elevation, falls nicht als Admin gestartet
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Mode install
pause
```

- [ ] **Step 2: `update.bat` schreiben** (identisch, Modus `update`)

```bat
@echo off
chcp 65001 >nul
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Mode update
pause
```

- [ ] **Step 3: `uninstall.bat` schreiben** (identisch, Modus `uninstall`)

```bat
@echo off
chcp 65001 >nul
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Mode uninstall
pause
```

- [ ] **Step 4: Doppelklick-Elevation verifizieren**

Aus einer **nicht**-erhöhten Explorer-Sitzung `install.bat` doppelklicken.
Expected: UAC-Abfrage erscheint; nach Zustimmung läuft `setup.ps1 -Mode install` in einem erhöhten Fenster; ohne Zustimmung passiert nichts (kein stiller Fehlschlag).

- [ ] **Step 5: Commit**

```bash
git add install.bat update.bat uninstall.bat
git commit -m "feat(setup): Thin-.bat-Wrapper mit UAC-Elevation"
```

---

### Task 10: `package.bat` + `requirements.txt` + README

Baut das Auslieferungs-ZIP inkl. Embeddable Python; entfernt `pywin32`; ergänzt README-Hinweis (behebt Nr. 3, 8).

**Files:**
- Modify: `requirements.txt`
- Modify: `package.bat`
- Modify: `README.md`

- [ ] **Step 1: `pywin32` aus `requirements.txt` entfernen**

Lösche die Zeile `pywin32==310`. Ergebnis:
```
Cerberus==1.3.7
Flask==3.1.0
paho-mqtt==2.1.0
python-dotenv==1.1.0
pytz==2025.2
requests==2.32.3
```

- [ ] **Step 2: `package.bat` — Embeddable-Python-Bootstrap + neue Dateien**

Ersetze `package.bat` durch:
```bat
@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

set OUTPUT_DIR=%~dp0
set ZIP_NAME=Alamos2Fireplan
set CONFIG_FILE=%OUTPUT_DIR%config\config.py
set TEMP_FOLDER=%OUTPUT_DIR%__package_tmp__
set PY_VERSION=3.12.8
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
```

- [ ] **Step 3: `package_exclude.txt` anlegen** (verhindert Mitkopieren eines lokalen `tools\python`)

```
python\
```

- [ ] **Step 4: README-Hinweis ergänzen**

Unter „Projektstruktur" in `README.md` folgenden Absatz einfügen:
```markdown
## Installation & Update (ab v2.1)

1. ZIP entpacken (enthält bereits Python – keine separate Python-Installation nötig).
2. `install.bat` doppelklicken (fragt nach Adminrechten). Optional wird dabei ein
   lokaler Mosquitto-Broker eingerichtet.
3. Update: neues ZIP entpacken, `update.bat` doppelklicken – der Installationspfad
   wird automatisch erkannt, `config/`, `alarme.db` und `logs/` werden vorher gesichert.
4. Entfernen: `uninstall.bat` doppelklicken.
```

- [ ] **Step 5: Paket bauen und Inhalt prüfen**

Run: `.\package.bat`
Expected:
- `Alamos2Fireplan_v2.0.9.zip` entsteht.
- Enthält `setup.ps1`, `setup.lib.ps1`, `install.bat`, `update.bat`, `uninstall.bat`, `tools\nssm.exe`, `tools\python\python.exe`.
- `tools\python\Lib\site-packages` enthält `flask`, `paho`, `cerberus`.
- Enthält **kein** `config\.env`, **kein** `*.db`.

- [ ] **Step 6: Verpacktes Python lauffähig prüfen**

Run: `powershell -Command "Expand-Archive Alamos2Fireplan_v2.0.9.zip -DestinationPath _verify -Force; ._verify\tools\python\python.exe -c \"import flask, paho.mqtt.client, cerberus; print('deps ok')\""`
Expected: `deps ok`. Danach `_verify` löschen.

- [ ] **Step 7: Commit**

```bash
git add requirements.txt package.bat package_exclude.txt README.md
git commit -m "feat(build): package.bat bündelt Embeddable Python; pywin32 entfernt"
```

---

## Self-Review Ergebnis

**Spec-Abdeckung:** §3 Dateistruktur → Tasks 4/9/10. §4 Architektur/Funktionen → Tasks 4–8. §5 Python-Bootstrap → Task 10 (+ Test-Python Task 4). §6 Install-Flow inkl. NSSM-Logging & Startprüfung → Task 5. §7 Update-Flow (Auto-Ziel, Backup, Code-only) → Task 6 (+ Lib Tasks 2/3). §8 package.bat → Task 10. §9 Mosquitto (alle 10 Punkte) → Task 8. §10 Uninstall → Task 7. §11 Fehlerbehandlung/Logging → Task 4 (durchgängig genutzt). §12 YAGNI → keine Tasks (bewusst). Bug-Tabelle 1–9 → siehe Task-Referenzen. Keine Lücke.

**Placeholder-Scan:** Keine TBD/TODO; alle Code-Schritte enthalten vollständigen Code.

**Typ-Konsistenz:** Funktionsnamen über Tasks hinweg konsistent (`Update-EnvFile`, `Get-UpdateCopyPlan`, `Get-BackupItems`, `Get-BackupFolderName`, `Install-Service`, `Remove-Service`, `Assert-ServiceStarted`, `Get-ServiceDir`, `Setup-Mosquitto`). `Setup-Mosquitto` in Task 5 als Stub eingeführt, in Task 8 ersetzt — bewusst, dokumentiert.
