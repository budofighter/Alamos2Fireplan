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
