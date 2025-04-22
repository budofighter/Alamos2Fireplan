# 🚨 Alamos2Fireplan

**Einsatzdaten-Verarbeitung vom MQTT-Broker**  
➡ Weiterleitung von Alarm- und Fahrzeugdaten an **Fireplan**, **Feuersoftware** und eine **externe Status-API**

---

## 🛠 Voraussetzungen

Einen funktionierenden MQTT-Broker, welcher die Daten von Alamos empfangen kann.

➡ [📘 Anleitung zur Einrichtung von Mosquitto (MQTT-Broker)](https://github.com/budofighter/Alamos2Fireplan/wiki/Mosquitto-MQTT%E2%80%90Broker-%E2%80%93-Installation-&-Konfiguration-(Windows))

---

## 💾 Installationsanleitung
➡ [Installationsanleitung](https://github.com/budofighter/Alamos2Fireplan/wiki/Installationsanleitung)

---

## ⚙️ Konfiguration von Alamos, Fireplan & Feuersoftware
➡ [Konfiguration](https://github.com/budofighter/Alamos2Fireplan/wiki/Konfiguration)

---

## 🧪 Test & Logs

- Logdatei: `logs/app.log`
- Lokale Datenbank: `alarme.db` (SQLite-basiert)
- Tab **„📟 Einsätze“** → Doppelklick für Details & erneutes Senden
- Tab **„📄 Logs“** → Log einsehen oder löschen
- Log-Level über die Einstellungen konfigurierbar
- Über das Tool MQTT-Explorer [MQTT-Explorer](https://mqtt-explorer.com/) kann sehr einfach die MQTT Meldungen überwacht werden, falls es zu einem Problem kommt.

---

## 🖼 GUI-Vorschau

![GUI Screenshot 1](./resources/Screenshot1.png)  
![GUI Screenshot 2](./resources/Screenshot2.png)  

---

## 👨‍💻 Entwickler

📦 GitHub Repository & Quellcode:  
**[https://github.com/budofighter/Alamos2Fireplan](https://github.com/budofighter/Alamos2Fireplan)**

---

## 📜 Lizenz

MIT License  
© 2025 Christian Siebold

