# 🚨 Alamos2Fireplan

**Einsatzdaten-Verarbeitung vom MQTT-Broker**  
➡ Weiterleitung an **Fireplan**, **Feuersoftware** und eine **externe Status-API**

---

## 🛠 Voraussetzungen

- ✅ Ein **lokaler oder externer MQTT-Broker** (z. B. [Mosquitto](https://mosquitto.org/)) muss auf dem Zielsystem oder im Netzwerk installiert und konfiguriert sein.

---

## 💾 Installation

1. **ZIP-Datei herunterladen und entpacken**  
   Die ZIP enthält:

   - `Alamos2Fireplan.exe` → Das Hauptprogramm (ausführbare Datei)
   - `_internal/` → Notwendige Python-Dateien für die Ausführung
   - `resources/` → Logos und Icons
   - `.env` (wird beim ersten Start automatisch erstellt)

2. **Starten**  
   Starte das Programm mit einem Doppelklick auf:
    Alamos2Fireplan.exe

> 💡 Eine Python-Installation ist **nicht notwendig** – alles ist integriert!

---

## ⚙️ Erste Schritte

1. Wechsle in den Tab **„⚙️ Einstellungen“**

2. Trage folgende Felder ein:

- `MQTT_BROKER` – z. B. `localhost` oder die IP des Brokers
- `MQTT_PORT` – meist `1883`
- `MQTT_TOPIC` – z. B. `alamos/alarm/json`
- `MQTT_USERNAME` / `MQTT_PASSWORD` – sofern der Broker gesichert ist

3. Weiter unten:

- `FIREPLAN_SECRET` – dein API-Key
- `FIREPLAN_DIVISION` – Abteilungsnummer
- Optional: `FEUERSOFTWARE_API_TOKEN`
- Optional: Externe API:
  - `EXTERNE_API_URL` – z. B. `https://status.fwbs.de/api.php`
  - `EXTERNE_API_TOKEN` – API-Schlüssel für Statusübertragung

4. Änderungen mit dem Button **💾 Speichern** sichern  
→ Die Datei `.env` wird automatisch angepasst

---

## 🔁 ISE → RIC-Zuordnung

Damit dein System weiß, welcher ISE-Code zu welchem RIC gehört:

1. Gehe im Tab **„Einstellungen“** zum Abschnitt  
**🔁 ISE - RIC Zuordnung**

2. Klicke auf **📝 Zuordnung bearbeiten**

3. Trage je Zeile ein:
ise1234sys00abcde12300:123456

➤ Nur gültige RICs (6-stellig, numerisch) werden gespeichert

4. Speichern & Schließen – fertig ✅

---

## 🔍 Funktionen im Überblick

| System            | Funktion                                           |
|-------------------|----------------------------------------------------|
| **MQTT**          | Empfang von Alarmmeldungen im JSON-Format          |
| **Fireplan**      | Automatische Einsatz-POSTs mit Koordinaten & RICs |
| **Feuersoftware** | Ergänzende Alarmweiterleitung mit Zusatzinfos     |
| **Externe API**   | Übergibt Fahrzeugstatusmeldungen (z. B. Status 1–8)|

---

## 🧪 Test & Logs

- Logdatei: `logs/app.log`
- Alarme & Statusmeldungen werden lokal in einer SQLite-Datenbank gespeichert
- Im Tab **„📄 Logs“** kannst du die Log-Datei einsehen oder löschen

---

## 🖼 GUI-Vorschau

![GUI Screenshot](./resources/screenshot.png)  
_Füge bei Bedarf eigene Screenshots hinzu_

---

## 🧹 Tipps

- Wenn du Probleme hast, kannst du `.env` und `ric_map.json` löschen – sie werden neu erstellt
- Die Datenbankdateien (`alarme.db`) kannst du mit einem SQLite-Viewer einsehen
- Die Anwendung läuft auch **portabel von USB-Stick**

---

## 🧑‍💻 Entwickler

Quellcode & Issues:  
**https://github.com/budofighter/Alamos2Fireplan**

---

## 📜 Lizenz

MIT License  
© Christian Siebold


