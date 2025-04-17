# 🚨 Alamos2Fireplan

**Einsatzdaten-Verarbeitung vom MQTT-Broker**  
➡ Weiterleitung von Alarm- und Fahrzeugdaten an **Fireplan**, **Feuersoftware** und eine **externe Status-API**

---

## 🛠 Voraussetzungen

- ✅ Ein **lokaler oder externer MQTT-Broker** (z. B. [Mosquitto](https://mosquitto.org/)) muss auf dem Zielsystem oder im Netzwerk installiert und konfiguriert sein.

---

## 💾 Installation

1. **ZIP-Datei herunterladen und entpacken**  
   Die ZIP enthält:

   - `Alamos2Fireplan.exe` → Das Hauptprogramm (ausführbare Datei)
   - `_internal/` → Notwendige Python-Dateien für die Ausführung
   - `logs/, .env, ric_map.json und alarme.db` → werden beim ersten Start erstellt

2. **Starten**  
   Starte das Programm mit einem Doppelklick auf:
    Alamos2Fireplan.exe


---

## ⚙️ Erste Schritte

1. Wechsle in den Tab **„⚙️ Einstellungen“**

2. Trage folgende Felder ein:

- `MQTT_BROKER` – z. B. `127.0.0.1` 
- `MQTT_PORT` – meist `1883`
- `MQTT_TOPIC` – z. B. `alamos/alarm/json` → definiert in Alamos
- `MQTT_USERNAME` / `MQTT_PASSWORD` → aus der Mosquitto-Einrichtung

3. Weiter unten:

- `FIREPLAN_SECRET` – dein API-Key
- `FIREPLAN_DIVISION` – Abteilungsname der Fireplan API
- Optional: `FEUERSOFTWARE_API_TOKEN`
- Optional: Nur für Expertenbenutzer - Externe API für eigene Weiterverarbeitung der Fahrzeugstatus:
  - `EXTERNE_API_URL` – z. B. `https://status.fwbs.de/api.php`
  - `EXTERNE_API_TOKEN` – API-Schlüssel für Statusübertragung

4. Änderungen mit dem Button **💾 Speichern** sichern  
→ Die Datei `.env` wird automatisch angepasst

---

## 🔁 ISE → RIC-Zuordnung

Damit dein System weiß, welcher ISE-Code zu welchem RIC gehört:

1. Gehe im Tab **„Einstellungen“** ganz runter zum Abschnitt  
**🔁 ISE - RIC Zuordnung**

2. Klicke auf **📝 Zuordnung bearbeiten**

3. Trage je Zeile ein:
ise1234sys00abcde12300:123456

➤ Nur gültige RICs (7-stellig, numerisch) werden gespeichert
➤ Die ise-Werte bekommt ihr aus dem Alamos System und bezeichnet die eindeutige RIC-Zuordnung im Leitstellenrechner

4. Speichern & Schließen – fertig ✅

---

## ⚙️ Nötige EInstellungen in Alamos (Quelle), Fireplan (Ziel) und Feuersoftware (Ziel)

➤ Alamos:
Es müssen zwei Einheiten angelegt werden Alarmeinheit für die Alarme und eine Statuseinheit für die Fahrzeugstati. 
1. Der Alarmablauf der Alarmeinheit muss folgenden Aufbau haben:
→ JSON-Plugin
   - Modud: JSON in Alarmtext schreiben
   - Version: v2
   - zusätzlicche Parameter:
      alarmState
      city_abbr
      COBRA_DEVICE_alerted_codes
      COBRA_DEVICE_alerted
      COBRA_DEVICE_alerted_semicolon
      COBRA_keyword_diagnosis
      COBRA_comment
   
     → MQTT
        - Broker, Benutezrname und Passwort: siehe Einrichtung Mosquitto
        - Topic: muss mit der Einstellung in Alamos2Fireplan übereinstimmen


2. Der Alarmablauf der Statuseinheit muss folgenden Aufbau haben:
→ JSON-Plugin
   - Modud: JSON in Alarmtext schreiben
   - Version: v2
   
     → MQTT
        - Broker, Benutezrname und Passwort: siehe Einrichtung Mosquitto
        - Topic: muss mit der Einstellung in Alamos2Fireplan übereinstimmen
    
➤ Fireplan:
1. Die RICs in den Optionen müssen mit den RICs aus der 🔁 ISE - RIC Zuordnung übereinstimmen. Inkl. ggf. führender 0. !Achtung! es werden nur A-SubRICS übergeben.
2. Die Fahrzeuge in den Optionen müssen als FMS-Kennung den exakten Aufbau aus Alamos haben. (z.B. FL-BAS 1/10) - ggf. müssen Fahrzeuge ausgeblendet und neu angelegt werden.

 ➤ Feuersoftware:
 1. Die Fahrzeuge in den Optionen müssen als FMS-Kennung eine bereinigte Form haben, da diese per URL übergeben werden. (z.B. FLBAS 110).

## 🔍 Funktionen im Überblick

| System            | Funktion                                                              |
|-------------------|-----------------------------------------------------------------------|
| **MQTT**          | Empfang von Alarmmeldungen im JSON-Format                             |
| **Fireplan**      | Automatische Einsatz- und Fahrzeugstatus-POSTs mit Koordinaten & RICs |
| **Feuersoftware** | Automatische Fahrzeugstatus-POSTs mit Koordinaten & RICs              |
| **Externe API**   | Übergibt Fahrzeugstatusmeldungen an externe API (z. B. Status 1–8)    |

---

## 🧪 Test & Logs

- Logdatei: `logs/app.log`
- Alarme & Statusmeldungen werden lokal in einer SQLite-Datenbank gespeichert
- Im Tab ** EInsätze** kannst du auf einen EInsatz Doppelklickenm, um weitere Details einzusehen und den Alarm neu zu senden
- Im Tab **„📄 Logs“** kannst du die Log-Datei einsehen oder löschen
- Die Logdetails können in den EInstellungen umgestellt werden

---

## 🖼 GUI-Vorschau

![GUI Screenshot](./resources/screenshot.png)  
_Füge bei Bedarf eigene Screenshots hinzu_

---

## 🧹 Tipps

- Wenn du Probleme hast, kannst du `.env` und `ric_map.json` löschen – sie werden neu erstellt
- Die Datenbankdateien (`alarme.db`) kannst du mit einem SQLite-Viewer einsehen

---

## 🧑‍💻 Entwickler

Quellcode & Issues:  
**https://github.com/budofighter/Alamos2Fireplan**

---

## 📜 Lizenz

MIT License  
© Christian Siebold


