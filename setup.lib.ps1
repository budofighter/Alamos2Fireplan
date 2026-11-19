# setup.lib.ps1 - reine Hilfsfunktionen (keine System-Seiteneffekte).
# Dot-sourced von setup.ps1 und von den Pester-Tests.
# WICHTIG: Datei bleibt reines ASCII (Windows PowerShell 5.1 liest .ps1 ohne
# BOM als ANSI - Umlaute wuerden das Parsen brechen).

# ---------------------------------------------------------------------------
# Was gehoert wozu?
#  - Code-Elemente: werden bei Update komplett ERSETZT (alte Fassung -> Backup).
#  - Config-Code: nur die *.py-Dateien in config\ (config.py, __init__.py).
#    .env und *.json in config\ sind DATEN und werden nie angefasst.
#  - Daten: werden vor jedem Update gesichert und nie ueberschrieben.
#  - Altlasten: Reste alter Versionen (z. B. venv aus 2.0.x), die beim Update
#    aus dem Programmordner ins Backup verschoben werden.
# ---------------------------------------------------------------------------

function Get-CodeItems {
    return @('app','backend','tools','runserver.py','requirements.txt',
             'setup.ps1','setup.lib.ps1','install.bat','uninstall.bat','README.md')
}

function Get-DataItems {
    return @('config','alarme.db','alarme.db-wal','alarme.db-shm')
}

function Get-ObsoleteItems {
    # venv\ + update.bat: Installationsweise bis 2.0.x (System-Python + venv).
    # __pycache__ im Wurzelordner: Reste alter Starts.
    return @('venv','update.bat','__pycache__')
}

function Get-UpdateCopyPlan {
    # Liefert die Code-Elemente, die im Paket tatsaechlich vorhanden sind.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$SourceItems)
    $include = Get-CodeItems
    return @($SourceItems | Where-Object { $include -contains $_ })
}

function Get-BackupItems {
    # Liefert die Daten-Elemente, die im Zielordner tatsaechlich vorhanden sind.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetItems)
    $backup = Get-DataItems
    return @($TargetItems | Where-Object { $backup -contains $_ })
}

function Get-BackupFolderName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$Timestamp)
    return 'backup_' + $Timestamp.ToString('yyyyMMdd-HHmmss')
}

function Get-BackupsToPrune {
    # Aelteste Backups jenseits der Aufbewahrungsgrenze (Name enthaelt den
    # Zeitstempel -> lexikographische Sortierung = chronologisch).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
        [int]$Keep = 5
    )
    $sorted = @($Names | Where-Object { $_ -match '^backup_\d{8}-\d{6}$' } | Sort-Object -Descending)
    if ($sorted.Count -le $Keep) { return @() }
    return @($sorted[$Keep..($sorted.Count - 1)])
}

function Get-AppVersionFromText {
    # Liest APP_VERSION = "x.y.z" aus Python-Quelltext (backend\version.py ab
    # 2.2.x, config\config.py in aelteren Versionen).
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $m = [regex]::Match($Text, '(?m)^\s*APP_VERSION\s*=\s*["'']([^"'']+)["'']')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Compare-AppVersion {
    # -1: A < B, 0: gleich, 1: A > B, $null: nicht vergleichbar
    [CmdletBinding()]
    param([AllowNull()][string]$A, [AllowNull()][string]$B)
    $va = $null; $vb = $null
    if (-not [version]::TryParse([string]$A, [ref]$va)) { return $null }
    if (-not [version]::TryParse([string]$B, [ref]$vb)) { return $null }
    return $va.CompareTo($vb)
}

function Get-EnvValue {
    # Liest einen Schluessel aus einer .env-Datei (ohne Seiteneffekte).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $clean = $line.TrimStart([char]0xFEFF)
        if ($clean -match ('^\s*' + [regex]::Escape($Key) + '\s*=(.*)$')) {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Update-EnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $lines = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path -Encoding UTF8) } else { @() }
    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $first = $true
    foreach ($line in $lines) {
        # Evtl. vorhandenes BOM (aeltere Setups) am Dateianfang entfernen
        if ($first) { $line = $line.TrimStart([char]0xFEFF); $first = $false }
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
    # UTF-8 OHNE BOM schreiben. Windows PowerShell 5.1 wuerde mit
    # 'Set-Content -Encoding UTF8' ein BOM voranstellen, das die erste .env-Zeile
    # (z. B. MQTT_BROKER) fuer python-dotenv unbrauchbar macht.
    # Erst in eine Temp-Datei, dann ersetzen -> nie eine halb geschriebene .env.
    $full = [System.IO.Path]::GetFullPath($Path)
    $tmp = $full + '.tmp'
    [System.IO.File]::WriteAllLines($tmp, $result, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $full -Force
    return $result.ToArray()
}

function Clear-NssmString {
    # nssm gibt UTF-16LE aus; Windows PowerShell dekodiert das mit eingestreuten
    # NUL-Zeichen (z. B. "C`0:`0\`0..."), was Pfad-Aufloesung und Status-Matching
    # bricht. Diese Funktion entfernt die NUL-Zeichen und trimmt das Ergebnis.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text -replace "`0", '').Trim()
}

function Test-PathInside {
    # True, wenn $Path gleich $Root ist oder darunter liegt (ohne Dateizugriff).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}
