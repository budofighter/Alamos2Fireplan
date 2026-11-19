# Alamos2Fireplan

Ein Python-basiertes Tool zur Verarbeitung von Alarm- und Statusdaten aus **Alamos**,
mit Weiterleitung an **Fireplan**, **Feuersoftware** oder eine externe API. Es läuft als
Windows-Dienst und bietet eine Weboberfläche zur Verwaltung.

---

## Neu in Version 2.3.0

* **Update aus jeder Altversion** (auch 2.0.x mit `venv`): einfach `install.bat` aus dem
  neuen Paket starten. Einstellungen (`config/.env`, RIC-Zuordnung, Feuersoftware-Tokens)
  und die Datenbank (`alarme.db`) bleiben erhalten – der frühere manuelle Umweg über
  Deinstallation/Neuinstallation ist **nicht mehr nötig**.
* **Sicheres Update mit automatischem Zurückrollen:** Startet die neue Version nicht,
  wird die vorherige Version automatisch wiederhergestellt.
* **Echte Erfolgsprüfung:** Installation/Update gelten erst als erfolgreich, wenn die
  Weboberfläche tatsächlich antwortet.
* **MQTT stabiler:** automatisches Wiederverbinden (auch wenn der Broker beim Systemstart
  später startet), persistente Sitzung mit QoS 1 (Alarme während eines Neustarts werden
  vom Broker nachgeliefert), Verarbeitung blockiert die Verbindung nicht mehr.
* **Timeouts** für alle Aufrufe an Fireplan, Feuersoftware und externe API.
* Einstellungen wirken **sofort nach dem Speichern** (kein Dienst-Neustart nötig).
* Weboberfläche funktioniert **ohne Internet** (Bootstrap lokal eingebunden).
* Aktualisierte Komponenten: Python 3.14, Flask 3.1.3, paho-mqtt 2.2, requests 2.34,
  Mosquitto 2.1.4 (Installer im Paket enthalten, Installation ohne Internet möglich).

---

## Funktionen

* Empfang von Alarmen und Fahrzeugstatus über **MQTT**
* Integration mit **Fireplan**, **Feuersoftware** oder externer API
* Weboberfläche auf Port `5000` (passwortgeschützt)
* Speicherung in SQLite-Datenbank
* Live-Anzeige, Log-Verwaltung, Einstellungen im Browser
* Läuft als Windows-Dienst ohne Benutzeranmeldung (via NSSM, Konto `LocalSystem`)
* **Gebündeltes Python** – keine separate Python-Installation nötig
* **Ein `install.bat`** für Erst-Installation **und** Update
* Optionale, vollautomatische Einrichtung eines lokalen **Mosquitto-Brokers**

---

## Schnellstart

1. Release-ZIP (`Alamos2Fireplan_vX.Y.Z.zip`) herunterladen und in einen beliebigen Ordner entpacken.
2. `install.bat` doppelklicken (fragt nach Adminrechten). Das Programm wird nach
   `C:\Alamos2Fireplan` installiert, der Dienst registriert und gestartet.
3. Weboberfläche öffnen: **http://localhost:5000** – Standard-Passwort **`112112`**
   (nach dem ersten Login unter *Einstellungen* ändern!).

> Ausführliche Anleitung: siehe **[Installationsanleitung](https://github.com/budofighter/Alamos2Fireplan/wiki/Installationsanleitung-Alamos2Fireplan)** im Wiki.

---

## Installation & Update

**Immer `install.bat`** – das Skript erkennt selbst, was zu tun ist. Es wird stets aus dem
**entpackten Release-Ordner** gestartet (ZIP vorher entpacken, nicht direkt aus dem ZIP
starten).

* **Erst-Installation:** Dateien werden nach `C:\Alamos2Fireplan` kopiert, der Dienst wird
  registriert und gestartet. Optional wird ein lokaler Mosquitto-Broker eingerichtet.
* **Update (bestehende Installation, jede Version ab 2.0.x):**
  1. Dienst wird gestoppt (es wird gewartet, bis er wirklich steht).
  2. `config/` und `alarme.db` werden nach `backups/backup_<Datum>/data` gesichert.
  3. Der alte Programmcode wird nach `backups/backup_<Datum>/code` **verschoben** (nicht
     gelöscht), Altlasten wie `venv/` gleich mit.
  4. Neuer Code wird eingespielt, der Dienst neu registriert und gestartet.
  5. Antwortet die Weboberfläche nicht, wird automatisch die alte Version wiederhergestellt.

  **Einstellungen und Datenbank werden nie überschrieben.** Es bleiben die letzten 5 Backups
  erhalten.
* **Reparatur:** Wurde das Paket direkt in den Installationsordner entpackt, richtet
  `install.bat` den Dienst neu ein und prüft ihn.

**Update-Ablauf:** neue Version herunterladen, entpacken, `install.bat` aus dem
entpackten Ordner starten. Fertig.

**Deinstallation:** `uninstall.bat` doppelklicken. Es fragt, ob zusätzlich der
Mosquitto-Broker deinstalliert und ob der Installationsordner komplett gelöscht werden
soll. Vor dem Löschen wird angeboten, Einstellungen und Datenbank nach
`C:\Alamos2Fireplan-Datensicherung_<Datum>` zu sichern.

---

## Projektstruktur

```
Alamos2Fireplan/
├── app/                # Weboberfläche (Flask) + Templates/Static
├── backend/            # Logik: MQTT, DB, Fireplan/Feuersoftware/externe API, version.py
├── config/             # Konfiguration (.env, config.py, ric_map.json, fs_api_tokens.json)
├── tools/
│   ├── python/         # Gebündeltes Embeddable Python 3.14 (inkl. Abhängigkeiten)
│   ├── mosquitto/      # Mosquitto-Installer (für Installation ohne Internet)
│   └── nssm.exe        # Windows-Dienst-Tool
├── backups/            # automatische Sicherungen vor jedem Update
├── logs/               # app.log, service.log, setup.log
├── install.bat         # Installation UND Update (auto-erkannt)
├── uninstall.bat       # Dienst/Broker/Ordner entfernen
├── runserver.py        # Einstiegspunkt (waitress-WSGI-Server)
└── requirements.txt    # Python-Abhängigkeiten
```

---

## Voraussetzungen

* Windows 10/11 oder Windows Server
* Adminrechte **nur für die Installation** (Dienst-Registrierung); der laufende Dienst
  benötigt keinen Benutzerlogin
* **Kein** vorinstalliertes Python nötig (ist im Paket enthalten)
* Ein **Mosquitto MQTT-Broker** (lokal per `install.bat` einrichtbar oder extern)

---

## Dokumentation (Wiki)

| Thema | Link |
| --- | --- |
| Mosquitto MQTT-Broker | [Mosquitto MQTT-Broker – Installation & Konfiguration](https://github.com/budofighter/Alamos2Fireplan/wiki/Mosquitto-MQTT%E2%80%90Broker-%E2%80%93-Installation-&-Konfiguration-(Windows)) |
| Installationsanleitung | [Installationsanleitung Alamos2Fireplan](https://github.com/budofighter/Alamos2Fireplan/wiki/Installationsanleitung-Alamos2Fireplan) |
| Konfiguration der Systeme | [Konfiguration Alamos, Fireplan, Feuersoftware](https://github.com/budofighter/Alamos2Fireplan/wiki/Konfiguration-Alamos,-Fireplan,-Feuersoftware) |
| Grundeinstellung Alamos2Fireplan | [Einstellungen Alamos2Fireplan](https://github.com/budofighter/Alamos2Fireplan/wiki/Einstellungen-Alamos2Fireplan) |

---

## Sicherheit

* Die Weboberfläche ist passwortgeschützt; alle Seiten und API-Endpunkte erfordern Login.
* Standard-Passwort **`112112`** nach dem ersten Login ändern.
* Anonyme MQTT-Verbindungen vermeiden – das automatische Mosquitto-Setup richtet
  Benutzer/Passwort ein (`allow_anonymous false`).
* Für Zugriff über das Netz TLS und Firewallregeln nur so weit öffnen wie nötig.

---

## Fehlerbehebung

* **Logs** im Installationsordner:
  * `logs/app.log` – Anwendung (Alarme, MQTT, API)
  * `logs/service.log` – Ausgabe des Dienstes
  * `logs/setup.log` – Installations-/Update-Protokoll
* **Dienststatus prüfen:**
  ```powershell
  Get-Service -Name Alamos2Fireplan
  ```
* **MQTT-Status** in der Weboberfläche oben rechts (grün = wirklich verbunden).
* **Update fehlgeschlagen?** Die vorherige Version wird automatisch wiederhergestellt.
  Das Protokoll steht in `logs/setup.log`, Sicherungen unter `backups/`.
* **Port 5000 belegt?** In `config/.env` `WEB_PORT=<anderer Port>` eintragen und den Dienst
  neu starten.
* **Datenbank:** `alarme.db` im Installationsordner.

---

## Lizenz

MIT License – bereitgestellt von Christian Siebold, Feuerwehr Bad Säckingen.

Für Fragen oder Feedback: bitte an den Administrator wenden oder im Repository ein Issue erstellen.
