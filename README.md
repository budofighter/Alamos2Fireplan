
# Alamos2Fireplan

Ein kleines Python-basiertes Tool zur Verarbeitung von Alarm- und Statusdaten aus Alamos, mit Weiterleitung an Fireplan, Feuersoftware oder externe APIs. Das Tool läuft als Windows-Dienst und bietet eine Weboberfläche zur Verwaltung.

---

## Funktionen

* Empfang von Alarmen und Fahrzeugstatus über MQTT
* Integration mit Fireplan, Feuersoftware oder externer API
* Web-Oberfläche auf Port `5000`
* Speicherung in SQLite-Datenbank
* Live-Anzeige & Log-Verwaltung
* Windows-Dienst ohne Benutzeranmeldung (via NSSM)

---

## Projektstruktur

```
Alamos2Fireplan/
├── app/                # Webanwendung (Flask)
├── backend/            # Logik: MQTT, API, DB, Fireplan
├── config/             # .env, config.py
├── static/, templates/ # UI-Ressourcen
├── tools/              # Python portable, NSSM
├── runserver.py        # Flask-Einstiegspunkt
├── install.bat         # Dienstinstallation
├── uninstall.bat       # Dienst entfernen
├── requirements.txt    # Abhängigkeiten
```

---

## Schnellstart

1. **Installation starten:**

   ```
   install.bat
   ```
   
Startpasswort: `112112`



2. **Weboberfläche aufrufen:**

   ```
   http://localhost:5000
   ```

3. **Dienst läuft automatisch nach Systemstart**, auch ohne Benutzeranmeldung

---

## Dokumentation

| Thema                       | Datei                         |
| --------------------------- | ----------------------------- |
| Installationsanleitung      | [Installationsanleitung](https://github.com/budofighter/Alamos2Fireplan/wiki/2.-Installationsanleitung)  |
| Konfiguration von Systemen  | [Konfiguration](https://github.com/budofighter/Alamos2Fireplan/wiki/3.-Konfiguration) |
| Mosquitto MQTT-Broker Setup | [Einrichtung von Mosquitto (MQTT-Broker)](https://github.com/budofighter/Alamos2Fireplan/wiki/1.-Mosquitto-MQTT%E2%80%90Broker-%E2%80%93-Installation-&-Konfiguration-(Windows)) |

---

## Voraussetzungen

* Windows 10/11 oder Windows Server
* Keine Adminrechte für Betrieb (nur für Installation als Dienst)
* Mosquitto MQTT-Broker erforderlich (lokal oder extern)

---

## Hinweise zur Sicherheit

* Vermeide anonyme MQTT-Verbindungen (siehe \[Mosquitto\_Installation.md])
* Verwende möglichst TLS-Verschlüsselung in Produktivumgebungen
* Zugangsdaten werden in `.env` gespeichert → Dateizugriff absichern

---

## Fehlerbehebung

* Logs unter: `logs/app.log`
* Dienststatus prüfen mit:

  ```powershell
  Get-Service -Name Alamos2Fireplan
  ```
* Datenbank: `alamos.db` im Projektverzeichnis

---

## Lizenz

MIT License – bereitgestellt von Christian Siebold, Feuerwehr Bad Säckingen.

---

Für Fragen oder Feedback: Bitte an den Administrator wenden oder im Git-Repository ein Issue erstellen.
