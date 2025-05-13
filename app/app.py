from flask import Flask, render_template, request, redirect, url_for, flash, send_file
from app.mqtt_control import start_mqtt, stop_mqtt, get_status
import os
import json
import logging
from dotenv import load_dotenv, set_key
from backend.db_handler import DBHandler
from backend.main import handle_alarm
from backend.log_helper import logger, LOG_PATH
from dotenv import set_key
from datetime import datetime

from backend import log_helper
logger = log_helper.logger
logger.debug("Flask-App startet...")


app = Flask(__name__)
app.secret_key = os.urandom(24)
db = DBHandler()
load_dotenv(dotenv_path=os.path.join("config", ".env"))




# === Alarme ===
@app.route("/")
def alarms():
    db.cursor.execute("SELECT id, timestamp, keyword, city, street, house FROM alarme ORDER BY id DESC LIMIT 100")
    alarms = db.cursor.fetchall()
    return render_template("alarms.html", alarms=alarms, mqtt_running=get_status())

@app.route("/alarm/<int:alarm_id>")
def alarm_detail(alarm_id):
    db.cursor.execute("SELECT * FROM alarme WHERE id = ?", (alarm_id,))
    alarm = db.cursor.fetchone()
    if not alarm:
        flash("Alarm nicht gefunden", "danger")
        return redirect(url_for("alarms"))
    
    alarm_dict = dict(alarm)

    # Formatierte JSON-Strings erzeugen
    for key in ["raw_json", "update_log"]:
        if key in alarm_dict and alarm_dict[key]:
            try:
                parsed = json.loads(alarm_dict[key])
                alarm_dict[key] = json.dumps(parsed, indent=2, ensure_ascii=False)
            except Exception:
                pass 

    return render_template("alarm_detail.html", alarm=alarm_dict, mqtt_running=get_status())


@app.route("/alarm/<int:alarm_id>/repeat", methods=["POST"])
def alarm_repeat(alarm_id):
    db.cursor.execute("SELECT raw_json FROM alarme WHERE id = ?", (alarm_id,))
    row = db.cursor.fetchone()
    if not row:
        flash("Alarm nicht gefunden", "danger")
        return redirect(url_for("alarms"))
    raw_json = json.loads(row["raw_json"])
    handle_alarm(raw_json)
    flash("Alarm wurde erneut gesendet!", "success")
    return redirect(url_for("alarm_detail", alarm_id=alarm_id))

@app.route("/clear_alarms", methods=["POST"])
def clear_alarms():
    db.cursor.execute("DELETE FROM alarme")
    db.conn.commit()
    flash("Alle Alarme wurden gelöscht.", "success")
    return redirect(url_for("alarms"))

@app.template_filter('format_datetime')
def format_datetime(value, format="%d.%m.%Y %H:%M:%S"):
    try:
        dt = datetime.fromisoformat(value)
        return dt.strftime(format)
    except Exception:
        return value  # falls es kein ISO-Format ist, Original zurückgeben

@app.route("/api/alarms")
def api_alarms():
    db.cursor.execute("SELECT id, timestamp, keyword, city, street, house FROM alarme ORDER BY id DESC LIMIT 100")
    alarms = db.cursor.fetchall()
    return {"alarms": [dict(row) for row in alarms]}

# === Logs ===
@app.route("/logs")
def logs_page():
    if os.path.exists(LOG_PATH):
        with open(LOG_PATH, "r", encoding="utf-8") as f:
            log_content = f.read()
    else:
        log_content = "Keine Logdatei gefunden."

    current_level = os.getenv("LOG_LEVEL", "INFO").upper()
    return render_template("logs.html", log_content=log_content, current_level=current_level)

@app.route("/clear_logs", methods=["POST"])
def clear_logs():
    open(LOG_PATH, "w", encoding="utf-8").close()
    return redirect(url_for("logs_page"))

@app.route("/api/logs")
def api_logs():
    if os.path.exists(LOG_PATH):
        with open(LOG_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()
        lines.reverse()  # neueste zuerst
        return "".join(lines)
    else:
        return "Keine Logdatei gefunden."

@app.route("/set_log_level", methods=["POST"])
def set_log_level():
    level = request.form.get("log_level", "INFO").upper()
    env_path = os.path.join("config", ".env")
    set_key(env_path, "LOG_LEVEL", level)
    os.environ["LOG_LEVEL"] = level

    # Logger live neu konfigurieren
    logger.setLevel(getattr(logging, level, logging.INFO))
    flash(f"Log-Level auf {level} gesetzt", "success")
    return redirect(url_for("logs_page"))

@app.route("/download_logs")
def download_logs():
    if os.path.exists(LOG_PATH):
        return send_file(LOG_PATH, as_attachment=True, download_name="app.log")
    else:
        flash("Logdatei nicht gefunden.", "danger")
        return redirect(url_for("logs_page"))


# === Fahrzeugstatus ===
@app.route("/status")
def status():
    db.cursor.execute("SELECT timestamp, fahrzeug, status FROM fahrzeuglog ORDER BY timestamp DESC LIMIT 100")
    statuses = [{"timestamp": row[0], "fahrzeug": row[1], "status": row[2]} for row in db.cursor.fetchall()]
    return render_template("status.html", statuses=statuses, mqtt_running=get_status())

@app.route("/clear_status", methods=["POST"])
def clear_status():
    db.cursor.execute("DELETE FROM fahrzeuglog")
    db.conn.commit()
    flash("Alle Fahrzeugstatus wurden gelöscht.", "success")
    return redirect(url_for("status"))

@app.route("/api/status")
def api_status():
    db.cursor.execute("SELECT timestamp, fahrzeug, status FROM fahrzeuglog ORDER BY timestamp DESC LIMIT 100")
    rows = db.cursor.fetchall()
    return {"statuses": [dict(timestamp=row[0], fahrzeug=row[1], status=row[2]) for row in rows]}

# === Einstellungen ===
@app.route("/settings", methods=["GET"])
def settings():
    env_path = os.path.join("config", ".env")
    load_dotenv(dotenv_path=env_path)
    settings = {k: os.getenv(k, "") for k in [
        "MQTT_BROKER", "MQTT_PORT", "MQTT_TOPIC", "MQTT_STATUS_TOPIC",
        "MQTT_USERNAME", "MQTT_PASSWORD", "FIREPLAN_SECRET", "FIREPLAN_DIVISION",
        "FEUERSOFTWARE_API_TOKEN", "LOG_LEVEL", "AUSWERTUNG_FIREPLAN",
        "AUSWERTUNG_FEUERSOFTWARE", "EXTERNE_API_URL", "EXTERNE_API_TOKEN"
    ]}
    return render_template("settings.html", settings=settings, mqtt_running=get_status())

@app.route("/save_settings", methods=["POST"])
def save_settings():
    env_path = os.path.join("config", ".env")
    all_keys = [
        "MQTT_BROKER", "MQTT_PORT", "MQTT_TOPIC", "MQTT_STATUS_TOPIC",
        "MQTT_USERNAME", "MQTT_PASSWORD", "FIREPLAN_SECRET", "FIREPLAN_DIVISION",
        "FEUERSOFTWARE_API_TOKEN", "AUSWERTUNG_FIREPLAN",
        "AUSWERTUNG_FEUERSOFTWARE", "EXTERNE_API_URL", "EXTERNE_API_TOKEN"
    ]

    for key in all_keys:
        value = request.form.get(key)
        if key.startswith("AUSWERTUNG_"):
            value = "True" if value == "True" else "False"
        if value is not None:
            set_key(env_path, key, value)
            os.environ[key] = value

    flash("Einstellungen gespeichert", "success")
    return redirect(url_for("settings"))

SETTING_LABELS = {
    "MQTT_BROKER": "MQTT-Broker-Adresse",
    "MQTT_PORT": "MQTT-Port",
    "MQTT_TOPIC": "MQTT-Alarm-Topic",
    "MQTT_STATUS_TOPIC": "MQTT-Status-Topic",
    "MQTT_USERNAME": "MQTT-Benutzername",
    "MQTT_PASSWORD": "MQTT-Passwort",
    "FIREPLAN_SECRET": "Fireplan-API-Secret",
    "FIREPLAN_DIVISION": "Fireplan-Division",
    "FEUERSOFTWARE_API_TOKEN": "Feuersoftware API-Token",
    "EXTERNE_API_URL": "Externe API-URL",
    "EXTERNE_API_TOKEN": "Externe API-Token",
    "AUSWERTUNG_FIREPLAN": "Fireplan-Auswertung aktivieren",
    "AUSWERTUNG_FEUERSOFTWARE": "Feuersoftware-Auswertung aktivieren"
}

# === MQTT Steuerung ===
@app.route("/mqtt/start", methods=["POST"])
def mqtt_start():
    start_mqtt()
    return redirect(url_for("alarms"))

@app.route("/mqtt/stop", methods=["POST"])
def mqtt_stop():
    stop_mqtt()
    return redirect(url_for("alarms"))

@app.route("/api/mqtt_status")
def api_mqtt_status():
    return {"running": get_status()}


# === Tokens Editor ===
@app.route("/tokens")
def tokens():
    with open("config/fs_api_tokens.json", "r", encoding="utf-8") as f:
        tokens = json.load(f)
    return render_template("token.html", tokens=tokens, mqtt_running=get_status())

@app.route("/save_tokens", methods=["POST"])
def save_tokens():
    token_list = []
    index = 1
    while f"name_{index}" in request.form:
        name = request.form.get(f"name_{index}")
        token = request.form.get(f"token_{index}")
        if name and token:
            token_list.append({"name": name, "token": token})
        index += 1
    with open("config/fs_api_tokens.json", "w", encoding="utf-8") as f:
        json.dump(token_list, f, indent=2)
    flash("Tokens erfolgreich gespeichert.", "success")
    return redirect(url_for("tokens"))
    

@app.route("/add_token", methods=["POST"])
def add_token():
    with open("config/fs_api_tokens.json", "r", encoding="utf-8") as f:
        tokens = json.load(f)
    tokens.append({"name": "", "token": ""})
    with open("config/fs_api_tokens.json", "w", encoding="utf-8") as f:
        json.dump(tokens, f, indent=2)
    return redirect(url_for("tokens"))

@app.route("/delete_token", methods=["POST"])
def delete_token():
    index = int(request.form.get("index", -1))
    try:
        with open("config/fs_api_tokens.json", "r", encoding="utf-8") as f:
            tokens = json.load(f)

        if 0 <= index < len(tokens):
            del tokens[index]
            with open("config/fs_api_tokens.json", "w", encoding="utf-8") as f:
                json.dump(tokens, f, indent=2)
            flash("Token wurde gelöscht.", "success")
        else:
            flash("Ungültiger Index.", "danger")

    except Exception as e:
        flash(f"Fehler beim Löschen: {e}", "danger")

    return redirect(url_for("tokens"))


# === RIC Editor ===
@app.route("/ric_editor")
def ric_editor():
    with open("config/ric_map.json", "r", encoding="utf-8") as f:
        ric_map = json.load(f)
    ric_map_content = "\n".join(f"{k}:{v}" for k, v in ric_map.items())
    return render_template("ric_editor.html", ric_map_content=ric_map_content, mqtt_running=get_status())

@app.route("/save_ric_map", methods=["POST"])
def save_ric_map():
    raw_content = request.form.get("ric_map", "")
    ric_map = {}
    for line in raw_content.strip().splitlines():
        if ":" in line:
            ise, ric = map(str.strip, line.split(":", 1))
            ric_map[ise] = ric
    with open("config/ric_map.json", "w", encoding="utf-8") as f:
        json.dump(ric_map, f, indent=2, ensure_ascii=False)
    flash("RIC-Zuordnung erfolgreich gespeichert.", "success")
    return redirect(url_for("ric_editor"))

# === MQTT beim Start automatisch aktivieren ===
try:
    if not get_status():
        start_mqtt()
except Exception as e:
    print(f"Fehler beim Starten von MQTT: {e}")

# === Start App ===
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
