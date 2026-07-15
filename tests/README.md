# Tests

Reine Logik aus `setup.lib.ps1` wird mit Pester 5 getestet.

## Ausführen
```powershell
Invoke-Pester -Path tests/setup.Tests.ps1 -Output Detailed
```

Die System-Integration (Dienst, Mosquitto) ist nicht unit-testbar und wird
durch Ausführen von `install.bat` / `update.bat` auf einem Windows-Host geprüft
(siehe Implementierungsplan, Verifikationsschritte je Task).
