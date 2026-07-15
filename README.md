
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

## Installation & Update (ab v2.1)

Ein Skript für alles: **immer `install.bat`** – es erkennt selbst, ob eine
Erst-Installation oder ein Update nötig ist.

1. ZIP entpacken (enthält bereits Python – keine separate Python-Installation nötig).
2. `install.bat` doppelklicken (fragt nach Adminrechten).
   - **Erst-Installation:** Die Dateien werden nach `C:\Alamos2Fireplan` kopiert,
     der Dienst wird registriert und gestartet. Optional wird ein lokaler
     Mosquitto-Broker eingerichtet.
   - **Update (Dienst existiert bereits):** Der Dienst wird gestoppt, `config/`,
     `alarme.db` und `logs/` werden gesichert, nur der Code wird ersetzt
     (Einstellungen und Datenbank bleiben erhalten), dann startet der Dienst neu.
3. Für ein Update also einfach die neue Version entpacken und wieder `install.bat`
   doppelklicken – aus dem **entpackten Ordner**, nicht aus `C:\Alamos2Fireplan`.
4. Entfernen: `uninstall.bat` doppelklicken (Installationsordner mit Config/DB bleibt
   erhalten und kann bei Bedarf manuell gelöscht werden).

Die Weboberfläche läuft danach auf `http://localhost:5000`.


## Dokumentation

Bitte bei Erstinstataion komplett durcharbeiten!

| Thema                       | Datei                         |
| --------------------------- | ----------------------------- |
| Mosquitto MQTT Broker       | [1. Mosquitto MQTT‐Broker – Installation & Konfiguration (Windows)](https://github.com/budofighter/Alamos2Fireplan/wiki/1.-Mosquitto-MQTT%E2%80%90Broker-%E2%80%93-Installation-&-Konfiguration-(Windows))   |
| Installationsanleitung      | [2. Installationsanleitung Alamos2Fireplan](https://github.com/budofighter/Alamos2Fireplan/wiki/2.-Installationsanleitung-Alamos2Fireplan)  |
| Konfiguration der Systeme  | [3. Konfiguration Alamos, Fireplan, Feuersoftware](https://github.com/budofighter/Alamos2Fireplan/wiki/3.-Konfiguration) |
| Grundeinstellung Alamos2Fireplan | [4. Einstellungen Alamos2Fireplan](https://github.com/budofighter/Alamos2Fireplan/wiki/4.-Einstellungen-Alamos2Fireplan) |



---

## Voraussetzungen

* Windows 10/11 oder Windows Server
* Keine Adminrechte für Betrieb (nur für Installation als Dienst)
* Mosquitto MQTT-Broker erforderlich (lokal oder extern)

---

## Hinweise zur Sicherheit

* Vermeide anonyme MQTT-Verbindungen (siehe \[Mosquitto\_Installation.md])
* Verwende möglichst TLS-Verschlüsselung in Produktivumgebungen

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
