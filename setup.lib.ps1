# setup.lib.ps1 - reine Hilfsfunktionen (keine System-Seiteneffekte).
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

function Get-UpdateCopyPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$SourceItems)
    $include = @('app','backend','tools','runserver.py','requirements.txt',
                 'setup.ps1','setup.lib.ps1','install.bat','uninstall.bat')
    return @($SourceItems | Where-Object { $include -contains $_ })
}

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

function Clear-NssmString {
    # nssm gibt UTF-16LE aus; Windows PowerShell dekodiert das mit eingestreuten
    # NUL-Zeichen (z. B. "C`0:`0\`0..."), was Pfad-Aufloesung und Status-Matching
    # bricht. Diese Funktion entfernt die NUL-Zeichen und trimmt das Ergebnis.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text -replace "`0", '').Trim()
}
