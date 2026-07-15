# Design-Spec: Einheitliches `setup.ps1` für Installation, Update & Mosquitto

**Datum:** 2026-07-15
**Status:** Genehmigt (Design)
**Autor:** Christian Siebold (mit Claude Code)

## 1. Ziel & Motivation

Der bisherige Installations-/Update-Prozess (`install.bat`, `update.bat`, `uninstall.bat`)
wird von Admins als schwierig empfunden. Die Analyse hat neben UX-Schwächen mehrere
konkrete Bugs aufgedeckt, die das Update faktisch wirkungslos machen. Zusätzlich muss
Mosquitto heute vollständig manuell eingerichtet werden.

Dieses Design ersetzt die drei getrennten, inkonsistenten Batch-Skripte durch **ein**
einheitliches PowerShell-Skript `setup.ps1` mit den Modi `install` / `update` /
`uninstall`, das über schlanke `.bat`-Wrapper doppelklickbar bleibt. Optional richtet es
einen lokalen Mosquitto-Broker ein.

### Behobene Probleme (aus der Analyse)

| Nr. | Problem | Fundstelle |
|-----|---------|-----------|
| 1 | `nssm` ohne Pfad → Stop/Start im Update passiert nie (Dienst läuft mit altem Code weiter) | `update.bat:26,44` |
| 2 | Falsche `/EXCLUDE:`-Syntax bei `xcopy` | `update.bat:31` |
| 3 | `update.bat` fehlt im ausgelieferten ZIP | `package.bat:45-46` |
| 4 | Kein Admin-Rechte-Check (stille Fehler) | alle Skripte |
| 5 | `install.bat` meldet immer Erfolg, auch bei fehlgeschlagenem Start | `install.bat:102-112` |
| 6 | Kein NSSM-Dienst-Logging → Fehlersuche bei Crash unmöglich | `install.bat:102-105` |
| 7 | Update fragt Zielpfad manuell ab + Gefahr, Config/DB zu überschreiben | `update.bat:16,31` |
| 8 | Manuelle Python-Installation als Voraussetzung (größte Hürde); README verspricht „Python portable", das fehlt | `README.md:27`, `install.bat:25-52` |
| 9 | NSSM-Logik dreimal leicht unterschiedlich implementiert | `install.bat` vs `update.bat` |
| neu | Mosquitto-Broker muss komplett manuell installiert/konfiguriert werden | Wiki-Anleitung |

## 2. Getroffene Design-Entscheidungen

| Thema | Entscheidung |
|-------|-------------|
| Python-Bereitstellung | **Embeddable Python im Paket mitliefern** (kein System-Python, kein PATH, kein Admin für Python, kein venv) |
| Einstieg für Admins | **Thin `.bat`-Wrapper** (`install.bat`/`update.bat`/`uninstall.bat`) mit UAC-Self-Elevation, rufen `setup.ps1` mit Modus auf |
| Update-Zielverzeichnis | **Automatisch** aus dem NSSM-Dienst auslesen (kein manuelles Eintippen mehr) |
| Update-Datensicherheit | **Backup** von `config/`, `alarme.db`, `logs/` mit Zeitstempel; nur Code-Dateien werden aktualisiert |
| Dienstkonto | bleibt **`LocalSystem`** (kein Regressionsrisiko bei DB-Schreibrechten) |
| `pywin32` | **entfernt** (nirgends im Code importiert, nur in `requirements.txt`/`install.bat` referenziert) |
| Mosquitto | **Optionaler Schritt in `install.bat`** (Abfrage j/n) |
| Mosquitto-Credentials | **Admin gibt Benutzername + Passwort ein**, werden in pwfile UND `config/.env` geschrieben |
| Mosquitto-Installer | **Zur Laufzeit von mosquitto.org herunterladen** (feste, getestete Version) |

## 3. Dateistruktur (Ziel)

```
Alamos2Fireplan/
├── install.bat          # Thin-Wrapper → setup.ps1 -Mode install
├── update.bat           # Thin-Wrapper → setup.ps1 -Mode update
├── uninstall.bat        # Thin-Wrapper → setup.ps1 -Mode uninstall
├── setup.ps1            # Gesamte Logik
├── requirements.txt     # pywin32 entfernt
├── runserver.py
├── app/  backend/  config/
├── tools/
│   ├── nssm.exe
│   └── python/          # Embeddable Python inkl. Lib/site-packages (im ZIP)
├── logs/
│   ├── app.log          # von der App
│   ├── setup.log        # NEU: Protokoll aller setup.ps1-Läufe
│   └── service.log      # NEU: NSSM stdout/stderr des Dienstes
├── backups/             # NEU: Update-Backups backup_<zeitstempel>/
└── package.bat          # erweitert (nicht im Auslieferungs-ZIP)
```

## 4. `setup.ps1` — Architektur

Ein Skript, Parameter `-Mode {install|update|uninstall}` (Default: `install`).
Gemeinsame Funktionen, damit jede Logik nur **einmal** existiert (behebt Nr. 9):

| Funktion | Verantwortung |
|----------|---------------|
| `Assert-Admin` | Prüft Elevation; bricht mit klarer Meldung ab, falls nicht als Admin gestartet |
| `Write-Log` | Schreibt gleichzeitig auf Konsole und nach `logs/setup.log` (mit Zeitstempel + Level) |
| `Get-Nssm` | Liefert immer `<ProjectDir>\tools\nssm.exe` (behebt Nr. 1) |
| `Test-Python` / `Initialize-Python` | Prüft/bereitet Embeddable Python vor (§5) |
| `Install-Service` | Registriert NSSM-Dienst inkl. Logging (§6) |
| `Remove-Service` | Stoppt und entfernt den Dienst |
| `Get-ServiceDir` | Liest `AppDirectory` des Dienstes via `nssm get` (für Update) |
| `Assert-ServiceStarted` | Prüft nach dem Start wirklich den Status (behebt Nr. 5) |
| `Setup-Mosquitto` | Optionaler Mosquitto-Ablauf (§9) |

**Grundsätze:**
- `$ErrorActionPreference = 'Stop'`, jede Phase in `try/catch`, Fehler werden geloggt
  (nicht mehr per `>nul 2>&1` verschluckt).
- Konstanten (SERVICE_NAME=`Alamos2Fireplan`, Pfade) einmal oben definiert.
- Projektverzeichnis = Ordner des Skripts (`$PSScriptRoot`).

### `.bat`-Wrapper (Muster)

Jeder Wrapper ist minimal und identisch bis auf den Modus:
1. Prüft Adminrechte; falls nicht, startet sich per UAC (`runas`) neu.
2. Ruft `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Mode <mode>`.
3. `pause` am Ende, damit das Fenster bei Doppelklick offen bleibt.

## 5. Python-Bootstrap (Embeddable)

- `tools/python/` enthält die Embeddable-Distribution **inklusive** installierter Pakete
  in `Lib/site-packages`. Beim Admin ist damit alles fertig: kein Netz, kein venv,
  kein PATH, kein Admin für Python.
- Aufbau geschieht zur **Build-Zeit** in `package.bat` (§8):
  1. Embeddable-ZIP (feste Python-Version, x64) herunterladen und nach `tools/python/` entpacken.
  2. `python3xx._pth` anpassen: Zeile `#import site` → `import site` (aktiviert
     `site-packages` und normalen Import).
  3. `get-pip.py` ausführen → pip verfügbar machen.
  4. `python -m pip install -r requirements.txt` in die Embeddable-Umgebung.
- Der Dienst zeigt direkt auf `tools\python\python.exe runserver.py`.
- **`pywin32` wird aus `requirements.txt` entfernt.** Damit entfällt der komplette
  `pywin32_postinstall`-Schritt — der heikelste Teil bei Embeddable Python.
- `Test-Python` prüft beim Install nur, dass `tools\python\python.exe` existiert und
  startbar ist (`--version`). Fehlt es, klare Fehlermeldung (Paket unvollständig).

## 6. Install-Flow (`-Mode install`)

1. `Assert-Admin`.
2. `logs/` anlegen (falls fehlt).
3. `Test-Python` — Embeddable vorhanden & lauffähig.
4. Dienst sauber neu registrieren: vorhandenen Dienst stoppen + entfernen (idempotent).
5. `nssm install Alamos2Fireplan <ProjectDir>\tools\python\python.exe <ProjectDir>\runserver.py`
6. `nssm set` Parameter:
   - `AppDirectory <ProjectDir>`
   - `Start SERVICE_AUTO_START`
   - `ObjectName LocalSystem`
   - **NEU:** `AppStdout <ProjectDir>\logs\service.log`
   - **NEU:** `AppStderr <ProjectDir>\logs\service.log`
   - **NEU:** `AppRotateFiles 1`, `AppRotateBytes 1048576`
7. Optionaler Mosquitto-Schritt (§9) — Abfrage j/n.
8. Dienst starten (`nssm start`).
9. `Assert-ServiceStarted`: Status via `nssm status` prüfen. Ehrliche Erfolgs- oder
   Fehlermeldung; bei Fehler Hinweis auf `logs/service.log` (behebt Nr. 5).

## 7. Update-Flow (`-Mode update`)

Läuft aus dem **neuen** (entpackten) Paket; aktualisiert eine bestehende Installation.

1. `Assert-Admin`.
2. **Zielverzeichnis automatisch** ermitteln: `Get-ServiceDir` via
   `nssm get Alamos2Fireplan AppDirectory` (behebt Nr. 7). Existiert der Dienst nicht,
   Abbruch mit Hinweis „Bitte zuerst install.bat ausführen".
3. Dienst stoppen (mit korrektem nssm-Pfad, Fehler **sichtbar**) (behebt Nr. 1).
4. **Backup** nach `<Ziel>\backups\backup_<yyyyMMdd-HHmmss>\`:
   - `config/` (komplett), `alarme.db`, `logs/`.
5. **Nur Code kopieren** ins Zielverzeichnis (behebt Nr. 2):
   - `app/`, `backend/`, `runserver.py`, `requirements.txt`, `setup.ps1`,
     `install.bat`, `update.bat`, `uninstall.bat`, `tools/`.
   - **Nie angefasst:** `config/`, `alarme.db`, `logs/`, `backups/`.
   - Kopieren gezielt pro Element (kein `xcopy *`), damit nichts Fremdes mitkommt.
6. Abhängigkeiten aktualisieren, falls `requirements.txt` sich geändert hat:
   `tools\python\python.exe -m pip install -r requirements.txt`.
7. Dienst starten + `Assert-ServiceStarted`.

## 8. `package.bat` — Anpassungen

- **Embeddable Python bündeln:** Schritte aus §5 (Download, `._pth`, get-pip, pip install)
  in einen frischen `tools/python/`-Ordner, der mit ins ZIP kommt.
- **Neue Dateien ins ZIP:** `update.bat` (behebt Nr. 3), `setup.ps1`.
- Weiterhin ausschließen: `config/*.json`, `config/.env`, `alarme.db`, `logs/`, `backups/`,
  `__pycache__/`.
- Versionsnummer weiterhin aus `config/config.py` (`APP_VERSION`) auslesen.

## 9. Mosquitto-Setup (`Setup-Mosquitto`, optional)

Wird im Install-Flow nach Abfrage „Lokalen Mosquitto-Broker einrichten? (j/n)" aufgerufen.
Bei *Nein*: keine Änderung, Installation läuft normal weiter (externer/vorhandener Broker).
Bei *Ja*, jede Phase in `try/catch` (ein Mosquitto-Fehler bricht die A2F-Installation nicht ab):

1. **Erkennen:** Existiert Dienst „Mosquitto Broker" oder `C:\Program Files\mosquitto\mosquitto.exe`?
   → dann nur neu konfigurieren (Schritt 4+), nicht neu installieren.
2. **Download:** Feste, getestete Mosquitto-Version (x64-Installer) von mosquitto.org nach
   `%TEMP%` laden.
3. **Silent-Install:** `mosquitto-...-x64.exe /S` (Standardpfad `C:\Program Files\mosquitto`).
4. **Credentials abfragen:** Benutzername (Klartext) + Passwort (verdeckt, `Read-Host -AsSecureString`).
5. **pwfile anlegen:** Zielpfad **ohne Leerzeichen**:
   `C:\ProgramData\Alamos2Fireplan\pwfile.txt`. Anlage nicht-interaktiv:
   `mosquitto_passwd -b -c <pwfile> <user> <pass>`.
6. **`mosquitto.conf` schreiben** (`C:\Program Files\mosquitto\mosquitto.conf`):
   ```
   allow_anonymous false
   password_file C:\ProgramData\Alamos2Fireplan\pwfile.txt
   listener 1883
   ```
7. **Dienst sicherstellen & starten:** `mosquitto install` (falls Dienst fehlt),
   dann Dienst (neu-)starten.
8. **Credential-Sync in `config/.env`:**
   - Sicherstellen, dass `config/.env` existiert: einmal `tools\python\python.exe -c "import config"`
     ausführen → die App erzeugt `.env` (+ leere JSON-Dateien) aus ihrer **eigenen** Vorlage.
   - Danach nur die MQTT-Schlüssel patchen: `MQTT_BROKER=127.0.0.1`, `MQTT_PORT=1883`,
     `MQTT_USERNAME=<user>`, `MQTT_PASSWORD=<pass>`.
   - Keine doppelte `.env`-Vorlage im Skript.
9. **Firewall (optional abgefragt):** „Port 1883 in der Firewall freigeben (für Zugriff
   von anderem Rechner)? (j/n)". Bei Ja:
   `New-NetFirewallRule -DisplayName 'Mosquitto MQTT 1883' -Direction Inbound -Protocol TCP -LocalPort 1883 -Action Allow`.
10. **Abschlusshinweis:** Zugangsdaten nochmal anzeigen mit Hinweis
    „Diese Daten auch in Alamos eintragen."

## 10. Uninstall-Flow (`-Mode uninstall`)

Wie bisher, aber mit `Assert-Admin`, korrektem nssm-Pfad und Logging:
1. Bestätigung abfragen.
2. Dienst stoppen + entfernen.
3. Optional abfragen: `tools/python/` löschen? `backups/` löschen?
4. Mosquitto wird **nicht** automatisch entfernt (separater Broker, evtl. anderweitig genutzt);
   Hinweis, wie man ihn bei Bedarf manuell entfernt.

## 11. Fehlerbehandlung & Logging (durchgängig)

- `$ErrorActionPreference = 'Stop'`, jede Phase in `try/catch`.
- `Write-Log` schreibt Konsole + `logs/setup.log` (Zeitstempel, Level INFO/WARN/ERROR).
- Keine verschluckten Fehler mehr.
- Exit-Codes: 0 = Erfolg, ≠0 = Fehler (für spätere Automatisierung nutzbar).

## 12. Bewusst NICHT im Scope (YAGNI)

- Dienstkonto bleibt `LocalSystem` (kein Wechsel auf dediziertes Konto).
- Keine Migration auf MSI/Inno-Setup-Installer.
- Die Python/Flask-App selbst (`app/`, `backend/`) bleibt unverändert.
- Mosquitto-Installer wird nicht gebündelt (nur Download).
- Kein automatisches Deinstallieren von Mosquitto.
- TLS/Verschlüsselung für Mosquitto bleibt manuell (nur Passwort-Absicherung wird automatisiert).

## 13. Offene Risiken / Hinweise

- **Offline-Rechner:** Python funktioniert (gebündelt), Mosquitto-Setup benötigt Internet.
  Für den optionalen Schritt akzeptiert; bei fehlendem Netz klare Fehlermeldung.
- **Mosquitto-Silent-Install/Service:** Verhalten der NSIS-Komponentenauswahl im Silent-Modus
  absichern, indem der Dienst nach der Installation explizit via `mosquitto install`
  sichergestellt wird (idempotent behandeln).
- **Feste Versionen:** Sowohl Python-Embeddable- als auch Mosquitto-Download-URL/Version
  sind im Skript/Build gepinnt und bei Bedarf bewusst zu aktualisieren.
