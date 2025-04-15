import tkinter as tk
from tkinter import ttk, messagebox
import logging
import threading
import webbrowser
import os
import paho.mqtt.client as mqtt
import json
import re
import sys
from tkinter import PhotoImage
from datetime import datetime

from config import MQTT_BROKER, MQTT_PORT, MQTT_TOPIC, MQTT_USERNAME, MQTT_PASSWORD, APP_VERSION, MQTT_STATUS_TOPIC
from mqtt_handler import MQTTHandler
from db_handler import DBHandler
from fireplan_api import Fireplan
from log_helper import logger
from feuersoftware_api import post_fahrzeug_status

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


# === ALARMHANDLING ===
def handle_alarm(data):
    try:
        if data.get("type") != "ALARM":
            logger.info("Kein ALARM-Typ – ignoriert.")
            return

        d = data.get("data", {})
        loc = d.get("location", {})

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
            "units": ", ".join([u.get("address", "") for u in d.get("units", [])]) if d.get("units") else None,
            "vehicles": json.dumps(d.get("vehicles", []), ensure_ascii=False) if d.get("vehicles") else None,
            "alarmedTime": str(d.get("vehicles", [{}])[0].get("alarmedTime")) if d.get("vehicles") else None
        }

        db.log_alarm(alarm_data)
        logger.info(f"Alarm verarbeitet: {alarm_data}")
        fp.alarm(build_fireplan_payload(data))
        update_alarm_list()

    except Exception as e:
        logger.error(f"Fehler beim Verarbeiten des Alarms: {e}")

def build_fireplan_payload(alamos_data):
    d = alamos_data.get("data", {})
    loc = d.get("location", {})
    return {
        "einsatzstichwort": d.get("keyword"),
        "strasse": loc.get("street"),
        "hausnummer": loc.get("house"),
        "ort": loc.get("city"),
        "objektname": loc.get("building"),
        "zusatzinfo": " ".join(d.get("message", [])) if d.get("message") else None,
        "einsatznrlst": d.get("externalId"),
        "ortsteil": None, "ric": None, "subRIC": None, "koordinaten": None
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
    db.cursor.execute("SELECT timestamp, keyword, city FROM alarme ORDER BY id DESC LIMIT 100")
    for row in db.cursor.fetchall():
        original_ts = row[0]  # z.B. '2025-04-15T16:41:00.123456'
        try:
            display_ts = datetime.fromisoformat(original_ts).strftime('%Y-%m-%d %H:%M:%S')
        except Exception:
            display_ts = original_ts
        tree.insert("", "end", values=(display_ts, row[1], row[2]), tags=(original_ts,))
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
    win.geometry("500x500")
    icon_img = tk.PhotoImage(file=resource_path("resources/fwsignet.png"))
    win.iconphoto(False, icon_img)


    text = tk.Text(win, wrap="word")
    detail_lines = []

    for key, value in alarm_dict.items():
        if key == "vehicles" and value:
            try:
                vehicles = json.loads(value)
                vehicle_lines = [
                    f"- {v.get('name', '?')} ({v.get('id', '?')}) – {v.get('radioName', '?')} – Alarmzeit: {v.get('alarmedTime')}"
                    for v in vehicles
                ]
                detail_lines.append(f"{key}:\n" + "\n".join(vehicle_lines))
            except Exception as e:
                detail_lines.append(f"{key}: [Fehler beim Parsen: {e}]")
        else:
            detail_lines.append(f"{key}: {value}")

    text.insert("1.0", "\n\n".join(detail_lines))
    text.config(state="disabled")
    text.pack(expand=True, fill="both", padx=10, pady=10)

    def resend():
        payload = build_fireplan_payload({
            "data": {
                "externalId": alarm_dict.get("external_id"),
                "keyword": alarm_dict.get("keyword"),
                "message": [alarm_dict.get("message")],
                "location": {
                    "street": alarm_dict.get("street"),
                    "house": alarm_dict.get("house"),
                    "city": alarm_dict.get("city"),
                    "building": alarm_dict.get("building")
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

def setup_log_viewer():
    update_log_text()
    log_tab.after(3000, setup_log_viewer)

# === Einstellungen speichern
def save_env(data):
    env_path = ".env"
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
tree_columns = ("timestamp", "keyword", "city")
tree = ttk.Treeview(alarm_tab, columns=tree_columns, show="headings")
for col in tree_columns:
    tree.heading(col, text=col.title())
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
tk.Button(log_tab, text="🧹 Logs löschen", command=clear_logs, width=25).pack(pady=10)

# Einstellungen-Tab
env_fields = {
    "MQTT_BROKER": tk.StringVar(value=os.getenv("MQTT_BROKER", "")),
    "MQTT_PORT": tk.StringVar(value=os.getenv("MQTT_PORT", "")),
    "MQTT_TOPIC": tk.StringVar(value=os.getenv("MQTT_TOPIC", "")),
    "MQTT_STATUS_TOPIC": tk.StringVar(value=os.getenv("MQTT_STATUS_TOPIC", "")),
    "MQTT_USERNAME": tk.StringVar(value=os.getenv("MQTT_USERNAME", "")),
    "MQTT_PASSWORD": tk.StringVar(value=os.getenv("MQTT_PASSWORD", "")),
    "FIREPLAN_SECRET": tk.StringVar(value=os.getenv("FIREPLAN_SECRET", "")),
    "FIREPLAN_DIVISION": tk.StringVar(value=os.getenv("FIREPLAN_DIVISION", "")),
    "FEUERSOFTWARE_API_TOKEN": tk.StringVar(value=os.getenv("FEUERSOFTWARE_API_TOKEN", "")),
    "LOG_LEVEL": tk.StringVar(value=os.getenv("LOG_LEVEL", "INFO").upper()),
    "AUSWERTUNG_FIREPLAN": tk.BooleanVar(value=os.getenv("AUSWERTUNG_FIREPLAN", "True") == "True"),
    "AUSWERTUNG_FEUERSOFTWARE": tk.BooleanVar(value=os.getenv("AUSWERTUNG_FEUERSOFTWARE", "False") == "True")
}

form_frame = tk.Frame(settings_tab, padx=20, pady=20)
form_frame.grid(row=0, column=0, sticky="n")

row = 0
for key, var in env_fields.items():
    tk.Label(form_frame, text=key + ":").grid(row=row, column=0, sticky="e", pady=5, padx=5)

    if key == "LOG_LEVEL":
        level_combo = ttk.Combobox(form_frame, textvariable=var, state="readonly", width=37)
        level_combo["values"] = ["DEBUG", "INFO", "WARNING", "ERROR"]
        level_combo.grid(row=row, column=1, pady=5)
    elif key.startswith("AUSWERTUNG_"):
        tk.Checkbutton(form_frame, variable=var, onvalue=True, offvalue=False).grid(row=row, column=1, sticky="w", pady=5)
    else:
        show_char = "*" if "PASSWORD" in key else ""
        tk.Entry(form_frame, textvariable=var, width=40, show=show_char).grid(row=row, column=1, pady=5)
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
