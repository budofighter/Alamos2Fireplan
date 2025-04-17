# 📘 Mosquitto MQTT-Broker – Installation & Konfiguration (Windows)

**Diese Anleitung beschreibt, wie du einen lokalen Mosquitto-Broker unter Windows einrichtest.**  
➡ Er wird für die Kommunikation zwischen Alamos2Fireplan und dem Alamos-System benötigt.

---

## 📦 1. Mosquitto herunterladen

1. Besuche die offizielle Webseite:  
   👉 https://mosquitto.org/download

2. Lade die **Windows-Installer-Version** herunter, z. B.:  
   `mosquitto-2.0.x-install-windows-x64.exe`

3. Führe die Installation aus  
   ✅ Aktiviere bei der Installation die Option **„Service installieren“**  
   Damit wird Mosquitto beim Systemstart automatisch ausgeführt.

---

## 🗂 2. Konfigurationsdatei anlegen oder bearbeiten

1. Öffne den Installationsordner:  
   Standard: `C:\Program Files\mosquitto`

2. Bearbeite die Datei `mosquitto.conf`  
   ➤ Falls sie nicht existiert, erstelle eine neue Textdatei mit diesem Namen.

3. Füge folgenden Inhalt ein:

```conf
# mosquitto.conf – minimale Konfiguration

allow_anonymous false
password_file C:\Users\BENUTZER\Documents\pwfile.txt
listener 1883
```
🔒 Diese Konfiguration deaktiviert anonymen Zugriff und sichert den Zugang mit einem Passwort.
❗Achtung! der Pfad darf kein Leerzeichen enthalten (wie z.B. in `C:\Program Files\mosquitto`), daher muss die Datei ggf. an einen anderen Ort kopiert werden.
---

## 🔑 3. Benutzer für MQTT-Zugriff anlegen

1. Öffne die Eingabeaufforderung (CMD) **als Administrator**

2. Wechsle in den Mosquitto-Installationsordner:

```cmd
cd "C:\Program Files\mosquitto"
```

3. Erstelle einen Benutzer mit Passwort:

```cmd
mosquitto_passwd -c passwd.txt deinBenutzername
```

➡ Gib dann das gewünschte Passwort zweimal ein.  
➡ Diese Zugangsdaten musst du in **Alamos2Fireplan** in den Einstellungen eintragen.

---

## ▶ 4. Mosquitto-Dienst starten (einmalig)

1. Öffne das Windows-Startmenü → gib ein: `services.msc`

2. Öffne **Dienste**

3. Suche den Eintrag **Mosquitto Broker**

4. Rechtsklick → **Starten**

✅ Mosquitto läuft nun im Hintergrund auf Port `1883`.

---

## 🧪 Test & Hinweise

- Du kannst mit Tools wie **MQTT Explorer** oder `mosquitto_pub` / `mosquitto_sub` testen, ob dein Broker läuft und Nachrichten entgegennimmt.
- Falls du Alamos oder Alamos2Fireplan auf einem **anderen Rechner** nutzt, achte darauf, dass **Port 1883 in der Windows-Firewall freigegeben** ist.
- Bei Problemen prüfe die Logdatei:  
  `C:\Program Files\mosquitto\mosquitto.log`
