import tkinter as tk
from tkinter import ttk, messagebox
import logging
import threading
import webbrowser
import os
import json
import re
import sys
from tkinter import ttk
import subprocess  
from datetime import datetime
from extern_api import post_externer_status

from config import MQTT_BROKER, MQTT_PORT, MQTT_TOPIC, MQTT_USERNAME, MQTT_PASSWORD, APP_VERSION, MQTT_STATUS_TOPIC, EXTERNE_API_URL, EXTERNE_API_TOKEN
from mqtt_handler import MQTTHandler
from db_handler import DBHandler
from fireplan_api import Fireplan
from log_helper import logger
from feuersoftware_api import post_fahrzeug_status, post_feuersoftware_alarm

from dotenv import set_key, load_dotenv

import ctypes

ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(u'Alamos2Fireplan')

fp = Fireplan()
db = DBHandler()
mqtt_handler = None
is_running = False

def resource_path(relative_path):
    try:
        base_path = sys._MEIPASS  # Wenn als EXE
    except Exception:
        base_path = os.path.abspath(".")

    return os.path.join(base_path, relative_path)

os.makedirs("config", exist_ok=True)

# === RIC-MAPPING ===
def load_ric_map(path=os.path.join("config", "ric_map.json")):
    if not os.path.exists(path):
        logger.info("[RIC MAP] Keine Datei gefunden – lege leere ric_map.json an.")
        with open(path, "w", encoding="utf-8") as f:
            json.dump({}, f, indent=2)
        return {}

    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"[RIC MAP] Fehler beim Laden: {e}")
        return {}


def save_ric_map(mapping, path=os.path.join("config", "ric_map.json")):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(mapping, f, indent=2, ensure_ascii=False)
        logger.info("[RIC MAP] RIC-Zuordnungen gespeichert.")
    except Exception as e:
        logger.error(f"[RIC MAP] Fehler beim Speichern: {e}")


# === ALARMHANDLING ===
def handle_alarm(data):
    try:
        if data.get("type") != "ALARM":
            logger.info("Kein ALARM-Typ – ignoriert.")
            return

        d = data.get("data", {})
        loc = d.get("location", {})
        custom = d.get("custom", {})

        alarmed_vehicles = d.get("vehicles", [])
        alarmed_time = None
        if alarmed_vehicles:
            try:
                raw_time = alarmed_vehicles[0].get("alarmedTime")
                if raw_time:
                    alarmed_time = datetime.fromtimestamp(int(str(raw_time)[:10])).isoformat()
            except Exception as e:
                logger.warning(f"Fehler beim Verarbeiten der alarmedTime: {e}")

        # === Alarm speichern in DB ===
        alarm_data = {
            "timestamp": data.get("timestamp"),
            "externalId": d.get("externalId"),
            "keyword": d.get("keyword"),
            "keyword_description": d.get("keyword_description"),
            "message": " ".join(d.get("message", [])) if d.get("message") else None,
            "building": loc.get("building"),
            "street": loc.get("street"),
            "house": loc.get("house"),
            "postalCode": loc.get("postalCode"),
            "city": loc.get("city"),
            "city_abbr": loc.get("city_abbr"), 
            "units": ", ".join([u.get("address", "") for u in d.get("units", [])]) if d.get("units") else None,
            "vehicles": json.dumps(alarmed_vehicles, ensure_ascii=False),
            "alarmedTime": alarmed_time,
            "coordinate": json.dumps(loc.get("coordinate"), ensure_ascii=False) if loc.get("coordinate") else None,
            "custom_comment": custom.get("COBRA_comment"),
            "custom_diagnosis": custom.get("COBRA_keyword_diagnosis"),
            "custom_alerted": custom.get("COBRA_DEVICE_alerted"),
            "custom_alerted_semicolon": custom.get("COBRA_DEVICE_alerted_semicolon"),
            "custom_alerted_codes": custom.get("COBRA_DEVICE_alerted_codes"),
            "custom_alarm_state": custom.get("alarmState"),
            "raw_json": json.dumps(data, ensure_ascii=False)
        }

        try:
            db.log_alarm(alarm_data)
            update_alarm_list()
            logger.info(f"📥 Alarm gespeichert: {alarm_data.get('keyword_description')} ({alarm_data.get('externalId')})")
        except Exception as e:
            logger.error(f"[DB] Fehler beim Speichern des Alarms: {e}")

        # === Payload für Fireplan vorbereiten
        payload = build_fireplan_payload(data)
        ric_list = [r for r in payload.get("ric", "").split(";") if r.strip()]

        # === Fireplan Alarm
        if os.getenv("AUSWERTUNG_FIREPLAN", "False") == "True":
            for ric in ric_list:
                if not ric:
                    continue
                payload_copy = payload.copy()
                payload_copy["ric"] = ric
                logger.info(f"🚨 Sende Alarm an Fireplan für RIC {ric}")
                try:
                    fp.alarm(payload_copy)
                except Exception as e:
                    logger.warning(f"[Fireplan] Fehler beim Senden des Alarms: {e}")

        # === Feuersoftware Alarm
        if os.getenv("AUSWERTUNG_FEUERSOFTWARE", "False") == "True":
            ise_codes = custom.get("COBRA_DEVICE_alerted_codes", "")
            ise_list = [code.strip() for code in ise_codes.split(";") if code.strip()]
            ric_map = load_ric_map()
            feuersoftware_rics = [ric_map[code] for code in ise_list if code in ric_map]
            custom["COBRA_DEVICE_alerted_codes_translated"] = ";".join(feuersoftware_rics)

            try:
                post_feuersoftware_alarm(data)
            except Exception as e:
                logger.warning(f"[Feuersoftware] Fehler beim Senden des Alarms: {e}")

    except Exception as e:
        logger.error(f"Fehler beim Verarbeiten des Alarms: {e}")

def translate_ise_to_ric(ise_string):
    mapping_raw = os.getenv("RIC_MAP", "")
    if not mapping_raw or not ise_string:
        return ise_string  # Fallback

    mapping = dict(entry.split(":") for entry in mapping_raw.split(",") if ":" in entry)
    ise_list = [code.strip() for code in ise_string.split(";") if code.strip()]
    ric_list = [mapping.get(code, code) for code in ise_list]

    logger.debug(f"[RIC] Übersetze ISE zu RIC: {ise_list} → {ric_list}")
    return ";".join(ric_list)


def build_fireplan_payload(alamos_data):
    d = alamos_data.get("data", {})
    loc = d.get("location", {})
    custom = d.get("custom", {})
    coord = loc.get("coordinate")

    # RIC-Mapping anwenden
    ise_codes = custom.get("COBRA_DEVICE_alerted_codes", "")
    ise_list = ise_codes.split(";")
    ric_map = load_ric_map()
    translated_rics = [ric_map[code] for code in ise_list if code in ric_map]
    ric_string = ";".join(translated_rics)


    koord = None
    if isinstance(coord, (list, tuple)) and len(coord) == 2:
        koord = f"{coord[1]}, {coord[0]}"

    zusatzinfo_parts = [
        custom.get("COBRA_comment"),
        custom.get("COBRA_keyword_diagnosis")
    ]
    zusatzinfo = " – ".join(filter(None, zusatzinfo_parts))

    return {
        "einsatzstichwort": d.get("keyword_description"),   
        "strasse": loc.get("street"),
        "hausnummer": loc.get("house"),
        "ort": loc.get("city"),
        "ortsteil": custom.get("city_abbr"),
        "objektname": loc.get("building"),
        "zusatzinfo": zusatzinfo,
        "einsatznrlst": d.get("externalId"),
        "koordinaten": koord,
        "ric": ric_string,
        "subRIC": "A"
    }



# === Fahrzeugstatus ===
def handle_status_message(message):
    logger.info(f"Statusmeldung empfangen: {message}")

    try:
        match = re.search(r"Status\s+(\d)\s+für\s+(.+)", message)
        if not match:
            logger.warning("Statusmeldung konnte nicht erkannt werden.")
            return

        status = int(match.group(1))
        fahrzeug = match.group(2).strip()
        timestamp = datetime.now().isoformat()

        logger.info(f"Fahrzeug '{fahrzeug}' hat neuen Status: {status}")

        db.cursor.execute(
            "INSERT INTO fahrzeuglog (timestamp, fahrzeug, status) VALUES (?, ?, ?)",
            (timestamp, fahrzeug, status)
        )
        db.conn.commit()

        if os.getenv("AUSWERTUNG_FIREPLAN", "True") == "True":
            try:
                fp.send_fms_status(fahrzeug, status, timestamp)
            except Exception as e:
                logger.warning(f"[Fireplan] Fehler beim Senden des Fahrzeugstatus: {e}")
        if os.getenv("AUSWERTUNG_FEUERSOFTWARE", "False") == "True":
            try:
                post_fahrzeug_status(fahrzeug, status)
            except Exception as e:
                logger.warning(f"[Feuersoftware] Fehler beim Senden des Fahrzeugstatus: {e}")

        if EXTERNE_API_URL and EXTERNE_API_TOKEN:
            try:
                post_externer_status(fahrzeug, status)
            except Exception as e:
                logger.warning(f"[Externe API] Fehler beim Senden: {e}")

        # 👉 Hier direkt Liste aktualisieren
        update_status_list()

    except Exception as e:
        logger.error(f"Fehler beim Verarbeiten der Statusmeldung: {e}")


# === STATUS / VERBINDUNG ===
def draw_status_indicator(color):
    led_canvas.delete("all")
    led_canvas.create_oval(2, 2, 18, 18, fill=color, outline=color)

def update_status(message, color):
    status_label.config(text=message)
    draw_status_indicator(color)

def toggle_connection():
    global mqtt_handler, is_running

    if not is_running:
        update_status("🔄 Verbindungsaufbau...", "yellow")

        def start():
            global is_running, mqtt_handler
            if mqtt_handler:
                mqtt_handler.stop()
            mqtt_handler = MQTTHandler(
                broker=MQTT_BROKER,
                port=MQTT_PORT,
                topic=MQTT_TOPIC,
                status_topic=MQTT_STATUS_TOPIC,
                username=MQTT_USERNAME,
                password=MQTT_PASSWORD,
                on_alarm=handle_alarm,
                on_status=handle_status_message,
                on_disconnect=lambda: update_status("❌ Verbindung verloren", "red"),
                on_reconnect=lambda: update_status("🔄 Wieder verbunden", "green")
            )
            mqtt_handler.start()
            is_running = True
            start_stop_btn.config(text="🛑 Stoppen")
            update_status("✅ Verbunden mit MQTT-Broker", "green")
            update_alarm_list()

        threading.Thread(target=start, daemon=True).start()
    else:
        if mqtt_handler:
            mqtt_handler.stop()
        is_running = False
        start_stop_btn.config(text="▶️ Starten")
        update_status("⛔ Verbindung getrennt", "red")

# === LOGLEVEL
def set_log_level():
    level = os.getenv("LOG_LEVEL", "INFO").upper()
    logger.setLevel(getattr(logging, level, logging.INFO))
    logger.info(f"Log-Level gesetzt: {level}")

# === ALARM LISTE
def update_alarm_list():
    tree.delete(*tree.get_children())
    db.cursor.execute("SELECT timestamp, keyword, city, street, house FROM alarme ORDER BY id DESC LIMIT 100")
    for row in db.cursor.fetchall():
        original_ts = row[0]
        try:
            display_ts = datetime.fromisoformat(original_ts).strftime('%Y-%m-%d %H:%M:%S')
        except Exception:
            display_ts = original_ts
        tree.insert("", "end", values=(display_ts, row[1], row[2], row[3], row[4]), tags=(original_ts,))

    if tree.get_children():
        tree.see(tree.get_children()[-1])

# === Alarmdetails anzeugen lassen
def show_alarm_details(event):
    selected = tree.focus()
    if not selected:
        return
    original_ts = tree.item(selected, "tags")[0]
    db.cursor.execute("SELECT * FROM alarme WHERE timestamp = ?", (original_ts,))
    alarm = db.cursor.fetchone()
    if not alarm:
        return

    columns = [desc[0] for desc in db.cursor.description]
    alarm_dict = dict(zip(columns, alarm))

    win = tk.Toplevel(root)
    win.title("Alarm-Details")
    win.geometry("600x600")
    icon_img = tk.PhotoImage(file=resource_path("resources/fwsignet.png"))
    win.iconphoto(False, icon_img)

    text = tk.Text(win, wrap="word")
    detail_lines = []

    for key, value in alarm_dict.items():
        if not value:
            continue

        if key == "vehicles":
            try:
                vehicles = json.loads(value)
                vehicle_lines = [
                    f"- {v.get('name', '?')} ({v.get('id', '?')}) – {v.get('radioName', '?')} – Alarmzeit: {v.get('alarmedTime')}"
                    for v in vehicles
                ]
                detail_lines.append("Fahrzeuge:\n" + "\n".join(vehicle_lines))
            except Exception as e:
                detail_lines.append(f"{key}: [Fehler beim Parsen: {e}]")

        elif key == "coordinate":
            try:
                coord = json.loads(value) if isinstance(value, str) else value
                if isinstance(coord, list) and len(coord) == 2:
                    detail_lines.append(f"Koordinaten: {coord[1]}, {coord[0]}")
                else:
                    detail_lines.append(f"Koordinaten: {value}")
            except:
                detail_lines.append(f"Koordinaten: {value}")

        elif key == "custom_alerted_semicolon":
            lines = value.split(";")
            detail_lines.append("Alarmierte Einheiten:\n" + "\n".join(f"- {line.strip()}" for line in lines))

        elif key == "raw_json":
            continue  # wird unten gesondert angezeigt

        else:
            label = key.replace("_", " ").capitalize()
            detail_lines.append(f"{label}: {value}")

    text.insert("1.0", "\n\n".join(detail_lines))

    raw_json = alarm_dict.get("raw_json")
    if raw_json:
        try:
            raw_json_formatted = json.dumps(json.loads(raw_json), indent=2, ensure_ascii=False)
        except Exception:
            raw_json_formatted = raw_json
        text.insert(tk.END, "\n\n🔍 Rohdaten (JSON):\n" + raw_json_formatted)

    text.config(state="disabled")
    text.pack(expand=True, fill="both", padx=10, pady=10)

    def resend():
        payload = build_fireplan_payload({
            "data": {
                "externalId": alarm_dict.get("external_id"),
                "keyword": alarm_dict.get("keyword"),
                "keyword_description": alarm_dict.get("keyword_description"),
                "message": [alarm_dict.get("message")],
                "location": {
                    "street": alarm_dict.get("street"),
                    "house": alarm_dict.get("house"),
                    "city": alarm_dict.get("city"),
                    "building": alarm_dict.get("building"),
                    "coordinate": json.loads(alarm_dict.get("coordinate", "null") or "null")
                },
                "custom": {
                    "COBRA_comment": alarm_dict.get("custom_comment"),
                    "COBRA_keyword_diagnosis": alarm_dict.get("custom_diagnosis"),
                    "COBRA_DEVICE_alerted_codes": alarm_dict.get("custom_alerted_codes"),
                    "alarmState": alarm_dict.get("custom_alarm_state")
                }
            }
        })
        try:
            fp.alarm(payload)
            logger.info("Alarm erneut an Fireplan gesendet.")
            messagebox.showinfo("Erfolg", "Alarm wurde erneut gesendet.")
        except Exception as e:
            logger.error(f"Fehler beim Senden: {e}")
            messagebox.showerror("Fehler", str(e))

    tk.Button(win, text="📨 Erneut senden", command=resend).pack(pady=10)




# === LOG VIEWER
def clear_logs():
    if messagebox.askyesno("Logs löschen", "Logdatei wirklich löschen?"):
        open("logs/app.log", "w", encoding="utf-8").close()
        logger.info("Logdatei gelöscht.")
        update_log_text()

def update_log_text():
    try:
        with open("logs/app.log", "r", encoding="utf-8") as f:
            content = f.read()
            log_text.delete("1.0", tk.END)
            log_text.insert("1.0", content)
            log_text.see(tk.END)
    except FileNotFoundError:
        log_text.insert("1.0", "Keine Logdatei gefunden.")

def open_log_file():
    log_path = os.path.join("logs", "app.log")
    if os.path.exists(log_path):
        try:
            if sys.platform.startswith('win'):
                os.startfile(log_path)
            elif sys.platform.startswith('darwin'):
                subprocess.call(["open", log_path])
            else:
                subprocess.call(["xdg-open", log_path])
        except Exception as e:
            messagebox.showerror("Fehler", f"Logdatei konnte nicht geöffnet werden:\n{e}")
    else:
        messagebox.showwarning("Nicht gefunden", "Logdatei wurde nicht gefunden.")

def setup_log_viewer():
    update_log_text()
    log_tab.after(3000, setup_log_viewer)

# === Einstellungen speichern
def save_env(data):
    env_path = os.path.join("config", ".env")
    load_dotenv(env_path)
    for key, value in data.items():
        set_key(env_path, key, value)
    os.environ.update(data)
    logger.info("Einstellungen gespeichert.")
    set_log_level()

# === StatusDB
def clear_status_entries():
    if messagebox.askyesno("Einträge löschen", "Alle Fahrzeugstatus wirklich löschen?"):
        db.cursor.execute("DELETE FROM fahrzeuglog")
        db.conn.commit()
        update_status_list()
        logger.info("[GUI] Fahrzeugstatus gelöscht.")


# === GUI AUFBAU ===
root = tk.Tk()
icon_img = tk.PhotoImage(file=resource_path("resources/fwsignet.png"))
root.iconphoto(False, icon_img)

root.title("Alamos → Fireplan")
root.geometry("600x700")
root.minsize(580, 660)

top = tk.Frame(root, padx=20, pady=10)
top.grid(row=0, column=0, sticky="nsew")
bottom = tk.Frame(root)
bottom.grid(row=1, column=0, sticky="nsew")
branding = tk.Frame(root)
branding.grid(row=2, column=0, sticky="ew", padx=10, pady=5)

root.grid_rowconfigure(1, weight=1)
root.grid_columnconfigure(0, weight=1)
top.grid_columnconfigure(0, weight=1)
top.grid_columnconfigure(1, weight=0)

btn_frame = tk.Frame(top)
btn_frame.grid(row=0, column=0, sticky="nw")

start_stop_btn = tk.Button(btn_frame, text="▶️ Starten", command=toggle_connection, width=20)
start_stop_btn.grid(row=0, column=0, sticky="w", pady=2)

status_frame = tk.Frame(btn_frame)
status_frame.grid(row=1, column=0, sticky="w", pady=(5, 0))
led_canvas = tk.Canvas(status_frame, width=20, height=20, highlightthickness=0)
led_canvas.pack(side="left")
status_label = tk.Label(status_frame, text="🕒 Bereit. Bitte 'Starten' klicken.")
status_label.pack(side="left", padx=(5, 0))
draw_status_indicator("red")

version_label = tk.Label(top, text=f"Version: {APP_VERSION}", font=("Segoe UI", 10, "italic"), fg="gray")
version_label.grid(row=0, column=1, sticky="ne", padx=10)

style = ttk.Style()
style.configure("TNotebook.Tab", padding=[14, 8], font=('Segoe UI', 11))

notebook = ttk.Notebook(bottom)
notebook.pack(expand=True, fill="both")

# Tabs
alarm_tab = tk.Frame(notebook)
status_tab = tk.Frame(notebook)
log_tab = tk.Frame(notebook)
settings_tab = tk.Frame(notebook)

notebook.add(alarm_tab, text="📟 Alarme")
notebook.add(status_tab, text="🚒 FZG-Status")
notebook.add(log_tab, text="📄 Logs")
notebook.add(settings_tab, text="⚙️ Einstellungen")

# Alarm-Tab

global tree
tree_columns = ("timestamp", "keyword", "city", "street", "house")
tree = ttk.Treeview(alarm_tab, columns=tree_columns, show="headings")

# Spaltenüberschriften + Breiten
tree.heading("timestamp", text="Zeit")
tree.column("timestamp", width=150, anchor="w")
tree.heading("keyword", text="Stichwort")
tree.column("keyword", width=130, anchor="w")
tree.heading("city", text="Ort")
tree.column("city", width=100, anchor="w")
tree.heading("street", text="Straße")
tree.column("street", width=160, anchor="w")
tree.heading("house", text="Nr.")
tree.column("house", width=50, anchor="center")
tree.pack(fill="both", expand=True)
tree.bind("<Double-1>", show_alarm_details)

tk.Button(alarm_tab, text="🧹 Alarme löschen", command=lambda: (
    db.cursor.execute("DELETE FROM alarme"), db.conn.commit(), update_alarm_list()), width=25).pack(pady=10)


# Status-Tab
status_table = ttk.Treeview(status_tab, columns=("timestamp", "fahrzeug", "status"), show="headings")
status_table.heading("timestamp", text="Zeit")
status_table.heading("fahrzeug", text="Fahrzeug")
status_table.heading("status", text="Status")
status_table.pack(fill="both", expand=True)
tk.Button(status_tab, text="🧹 FZG-Status löschen", command=clear_status_entries, width=25).pack(pady=10)


def update_status_list():
    status_table.delete(*status_table.get_children())
    db.cursor.execute("SELECT timestamp, fahrzeug, status FROM fahrzeuglog ORDER BY timestamp DESC LIMIT 100")
    for row in db.cursor.fetchall():
        timestamp = datetime.fromisoformat(row[0]).strftime('%Y-%m-%d %H:%M:%S')
        status_table.insert("", "end", values=(timestamp, row[1], row[2]))
    status_tab.after(10000, update_status_list)
    

# Log-Tab
log_text = tk.Text(log_tab, wrap="none")
log_text.pack(fill="both", expand=True)
tk.Button(log_tab, text="🧹 Logs löschen", command=clear_logs, width=25).pack(pady=(10, 5))
tk.Button(log_tab, text="📂 Im Editor öffnen", command=open_log_file, width=25).pack(pady=(0, 10))


# === Einstellungen-Tab (scrollbarfähig) ===
env_fields = {
    "MQTT_BROKER": tk.StringVar(value=os.getenv("MQTT_BROKER", "")),
    "MQTT_PORT": tk.StringVar(value=os.getenv("MQTT_PORT", "")),
    "MQTT_TOPIC": tk.StringVar(value=os.getenv("MQTT_TOPIC", "")),
    "MQTT_STATUS_TOPIC": tk.StringVar(value=os.getenv("MQTT_STATUS_TOPIC", "")),
    "MQTT_USERNAME": tk.StringVar(value=os.getenv("MQTT_USERNAME", "")),
    "MQTT_PASSWORD": tk.StringVar(value=os.getenv("MQTT_PASSWORD", "")),
    "FIREPLAN_SECRET": tk.StringVar(value=os.getenv("FIREPLAN_SECRET", "")),
    "FIREPLAN_DIVISION": tk.StringVar(value=os.getenv("FIREPLAN_DIVISION", "")),
    "FEUERSOFTWARE_ORGA_API_TOKEN": tk.StringVar(value=os.getenv("FEUERSOFTWARE_API_TOKEN", "")),
    "LOG_LEVEL": tk.StringVar(value=os.getenv("LOG_LEVEL", "INFO").upper()),
    "AUSWERTUNG_FIREPLAN": tk.BooleanVar(value=os.getenv("AUSWERTUNG_FIREPLAN", "True") == "True"),
    "AUSWERTUNG_FEUERSOFTWARE": tk.BooleanVar(value=os.getenv("AUSWERTUNG_FEUERSOFTWARE", "False") == "True"),
    "EXTERNE_API_URL": tk.StringVar(value=os.getenv("EXTERNE_API_URL", "")),
    "EXTERNE_API_TOKEN": tk.StringVar(value=os.getenv("EXTERNE_API_TOKEN", ""))
}

# Canvas & Scrollbar
canvas = tk.Canvas(settings_tab, borderwidth=0, highlightthickness=0, background=settings_tab["background"])
scrollbar = ttk.Scrollbar(settings_tab, orient="vertical", command=canvas.yview)
scrollable_frame = ttk.Frame(canvas)

scrollable_frame.bind(
    "<Configure>",
    lambda e: canvas.configure(
        scrollregion=canvas.bbox("all")
    )
)

canvas.create_window((0, 0), window=scrollable_frame, anchor="nw")
canvas.configure(yscrollcommand=scrollbar.set)

canvas.pack(side="left", fill="both", expand=True)
scrollbar.pack(side="right", fill="y")

# Optional: Scroll per Mausrad
def _on_mousewheel(event):
    canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

canvas.bind_all("<MouseWheel>", _on_mousewheel)

# Formular in scrollbarem Bereich
form_frame = ttk.Frame(scrollable_frame, padding=20)
form_frame.pack(fill="x", anchor="n")

row = 0
for key, var in env_fields.items():
    ttk.Label(form_frame, text=key + ":").grid(row=row, column=0, sticky="e", pady=5, padx=5)

    if key == "LOG_LEVEL":
        level_combo = ttk.Combobox(form_frame, textvariable=var, state="readonly", width=37)
        level_combo["values"] = ["DEBUG", "INFO", "WARNING", "ERROR"]
        level_combo.grid(row=row, column=1, pady=5)
    elif key.startswith("AUSWERTUNG_"):
        ttk.Checkbutton(form_frame, variable=var, onvalue=True, offvalue=False).grid(row=row, column=1, sticky="w", pady=5)
    else:
        show_char = "*" if "PASSWORD" in key else ""
        ttk.Entry(form_frame, textvariable=var, width=40, show=show_char).grid(row=row, column=1, pady=5)
    row += 1

def save_env_from_form():
    values = {}
    for key, var in env_fields.items():
        values[key] = str(var.get())
    save_env(values)

tk.Button(
    form_frame,
    text="💾 Speichern",
    command=save_env_from_form,
    width=20
).grid(row=row, column=0, columnspan=2, pady=15)

# === RIC Mapping Editor ===
tk.Label(scrollable_frame, text="🔁 ISE - RIC Zuordnung", font=("Segoe UI", 10, "bold")).pack(anchor="w", padx=20, pady=(30, 5))
ttk.Button(scrollable_frame, text="📝 Zuordnung bearbeiten", command=lambda: open_ric_editor(), width=30).pack(pady=10, padx=20, anchor="w")

def open_ric_editor():
    win = tk.Toplevel(root)
    win.title("ISE:RIC-Zuordnung bearbeiten")
    win.geometry("500x500")
    win.resizable(False, False)

    tk.Label(win, text="🔧 Trage hier die ISE:RIC-Zuordnungen ein (eine pro Zeile)", font=("Segoe UI", 10, "bold")).pack(pady=(10, 5))

    example = "Beispiel:\nise1234sys00abcde12300:0123456\nise1234sys00xyz00xyz00:0654321"
    tk.Label(win, text=example, font=("Segoe UI", 9, "italic"), fg="gray").pack(pady=(0, 10))

    text_frame = tk.Frame(win)
    text_frame.pack(fill="both", expand=True, padx=10)

    text_widget = tk.Text(text_frame, height=18, width=60)
    text_widget.pack(fill="both", expand=True)

    # Vorhandene Einträge laden
    ric_mapping = load_ric_map()
    lines = [f"{ise}:{ric}" for ise, ric in ric_mapping.items()]
    text_widget.insert("1.0", "\n".join(lines))

    def save():
        raw = text_widget.get("1.0", tk.END).strip()
        new_map = {}
        errors = []

        for i, line in enumerate(raw.splitlines(), start=1):
            if ":" not in line:
                continue
            ise, ric = map(str.strip, line.split(":", 1))

            if not ise.startswith("ise"):
                errors.append(f"Zeile {i}: Ungültiger ISE-Code ({ise})")
            if not (ric.isdigit() and len(ric) == 7):
                errors.append(f"Zeile {i}: RIC muss 7 Ziffern sein ({ric})")

            new_map[ise] = ric

        if errors:
            messagebox.showerror("Fehler", "\n".join(errors), parent=win)
            return

        save_ric_map(new_map)
        messagebox.showinfo("Gespeichert", "RIC-Zuordnung gespeichert ✅", parent=win)
        save_btn.config(text="✅ Gespeichert", state="disabled")
        win.after(1000, win.destroy)

    save_btn = tk.Button(win, text="💾 Speichern & Schließen", command=save)
    save_btn.pack(pady=10)

# === Feuersoftware Token-Editor ===
tk.Label(scrollable_frame, text="🔑 Feuersoftware Abteilungs-API-Tokens", font=("Segoe UI", 10, "bold")).pack(anchor="w", padx=20, pady=(30, 5))
ttk.Button(scrollable_frame, text="🔧 Tokens bearbeiten", command=lambda: open_fs_token_editor(), width=30).pack(pady=10, padx=20, anchor="w")

def open_fs_token_editor():
    win = tk.Toplevel(root)
    win.title("Feuersoftware API-Tokens bearbeiten")
    win.geometry("600x500")
    win.resizable(True, True)

    tk.Label(win, text="🔧 Bearbeite hier deine API-Tokens für verschiedene Standorte",
             font=("Segoe UI", 10, "bold")).pack(pady=(10, 5))

    frame = tk.Frame(win)
    frame.pack(fill="both", expand=True, padx=10, pady=10)

    rows = []

    def add_row(name="", token=""):
        row_frame = tk.Frame(frame)
        row_frame.pack(fill="x", pady=3)

        name_var = tk.StringVar(value=name)
        token_var = tk.StringVar(value=token)

        tk.Entry(row_frame, textvariable=name_var, width=20).pack(side="left", padx=5)
        tk.Entry(row_frame, textvariable=token_var, width=50, show="*").pack(side="left", padx=5)
        tk.Button(row_frame, text="🗑", command=lambda: remove_row(row_frame)).pack(side="left", padx=5)

        rows.append((row_frame, name_var, token_var))

    def remove_row(row_frame):
        for r in rows:
            if r[0] == row_frame:
                r[0].destroy()
                rows.remove(r)
                break

    # Tokens laden
    token_path = os.path.join("config", "fs_api_tokens.json")
    try:
        with open(token_path, "r", encoding="utf-8") as f:
            token_data = json.load(f)
            for item in token_data:
                add_row(item.get("name", ""), item.get("token", ""))
    except:
        pass

    tk.Button(win, text="➕ Eintrag hinzufügen", command=lambda: add_row()).pack(pady=5)

    def save():
        token_list = []
        for _, name_var, token_var in rows:
            name = name_var.get().strip()
            token = token_var.get().strip()
            if name and token:
                token_list.append({"name": name, "token": token})
        try:
            with open(token_path, "w", encoding="utf-8") as f:
                json.dump(token_list, f, indent=2)
            messagebox.showinfo("Gespeichert", "Tokens gespeichert ✅", parent=win)
            win.destroy()
        except Exception as e:
            messagebox.showerror("Fehler", f"Speichern fehlgeschlagen:\n{e}", parent=win)

    tk.Button(win, text="💾 Speichern & Schließen", command=save).pack(pady=10)



# Branding
branding.columnconfigure(1, weight=1)
logo = tk.PhotoImage(file=resource_path("resources/logo_fwbs.png"))
tk.Label(branding, image=logo).grid(row=0, column=0, rowspan=4, sticky="nw")

tk.Label(branding, text="Quellcode:", font=("Segoe UI", 9, "bold")).grid(row=0, column=1, sticky="w")
link = tk.Label(branding, text="github.com/budofighter/Alamos2Fireplan", font=("Segoe UI", 9, "underline"),
                fg="blue", cursor="hand2")
link.grid(row=1, column=1, sticky="w")
link.bind("<Button-1>", lambda e: webbrowser.open("https://github.com/budofighter/Alamos2Fireplan"))

tk.Label(branding, text="Überwachung eines MQTT-Brokers, Datenerfassung,\nWeiterleitung an die Fireplan-API",
         font=("Segoe UI", 9), justify="left").grid(row=2, column=1, sticky="w")
tk.Label(branding, text="© by Christian Siebold", font=("Segoe UI", 9, "italic")).grid(row=3, column=1, sticky="w")

set_log_level()
setup_log_viewer()
update_status_list()
toggle_connection()
root.mainloop()
