
from flask import Flask, render_template, request, redirect, url_for, flash, send_file, session
from app.mqtt_control import start_mqtt, stop_mqtt, get_status
import os
import json
import logging
from functools import wraps
from dotenv import load_dotenv, set_key
from backend.db_handler import DBHandler
from backend.main import handle_alarm
from backend.log_helper import logger, LOG_PATH
from datetime import datetime
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = os.urandom(24)
db = DBHandler()
ENV_PATH = os.path.join("config", ".env")
load_dotenv(dotenv_path=ENV_PATH)
logger.debug("Flask-App startet...")

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated_function

@app.route("/login", methods=["GET", "POST"])
def login():
    load_dotenv(dotenv_path=ENV_PATH)
    if request.method == "POST":
        password = request.form.get("password", "")
        stored_hash = os.getenv("ADMIN_PASSWORD")
        if not stored_hash:
            flash("Admin-Passwort nicht gesetzt. Bitte .env prüfen.", "danger")
            return redirect(url_for("login"))
        if check_password_hash(stored_hash, password):
            session["logged_in"] = True
            return redirect(url_for("alarms"))
        else:
            flash("Falsches Passwort", "danger")
    return render_template("login.html")

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/")
@login_required
def alarms():
    db.cursor.execute("SELECT id, timestamp, keyword, city, street, house FROM alarme ORDER BY id DESC LIMIT 100")
    alarms = db.cursor.fetchall()
    return render_template("alarms.html", alarms=alarms, mqtt_running=get_status())

@app.route("/alarm/<int:alarm_id>")
@login_required
def alarm_detail(alarm_id):
    db.cursor.execute("SELECT * FROM alarme WHERE id = ?", (alarm_id,))
    alarm = db.cursor.fetchone()
    if not alarm:
        flash("Alarm nicht gefunden", "danger")
        return redirect(url_for("alarms"))
    alarm_dict = dict(alarm)
    for key in ["raw_json", "update_log"]:
        if key in alarm_dict and alarm_dict[key]:
            try:
                parsed = json.loads(alarm_dict[key])
                alarm_dict[key] = json.dumps(parsed, indent=2, ensure_ascii=False)
            except Exception:
                pass
    return render_template("alarm_detail.html", alarm=alarm_dict, mqtt_running=get_status())

@app.route("/alarm/<int:alarm_id>/repeat", methods=["POST"])
@login_required
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
@login_required
def clear_alarms():
    db.cursor.execute("DELETE FROM alarme")
    db.conn.commit()
    flash("Alle Alarme wurden gelöscht.", "success")
    return redirect(url_for("alarms"))

@app.template_filter("format_datetime")
def format_datetime(value, format="%d.%m.%Y %H:%M:%S"):
    try:
        dt = datetime.fromisoformat(value)
        return dt.strftime(format)
    except Exception:
        return value

@app.route("/api/alarms")
def api_alarms():
    db.cursor.execute("SELECT id, timestamp, keyword, city, street, house FROM alarme ORDER BY id DESC LIMIT 100")
    alarms = db.cursor.fetchall()
    return {"alarms": [dict(row) for row in alarms]}

@app.route("/logs")
@login_required
def logs_page():
    if os.path.exists(LOG_PATH):
        with open(LOG_PATH, "r", encoding="utf-8") as f:
            log_content = f.read()
    else:
        log_content = "Keine Logdatei gefunden."
    current_level = os.getenv("LOG_LEVEL", "INFO").upper()
    return render_template("logs.html", log_content=log_content, current_level=current_level)

@app.route("/clear_logs", methods=["POST"])
@login_required
def clear_logs():
    open(LOG_PATH, "w", encoding="utf-8").close()
    return redirect(url_for("logs_page"))

@app.route("/api/logs")
def api_logs():
    if os.path.exists(LOG_PATH):
        with open(LOG_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()
        lines.reverse()
        return "".join(lines)
    return "Keine Logdatei gefunden."

@app.route("/set_log_level", methods=["POST"])
def set_log_level():
    level = request.form.get("log_level", "INFO").upper()
    set_key(ENV_PATH, "LOG_LEVEL", level)
    os.environ["LOG_LEVEL"] = level
    logger.setLevel(getattr(logging, level, logging.INFO))
    flash(f"Log-Level auf {level} gesetzt", "success")
    return redirect(url_for("logs_page"))

@app.route("/download_logs")
@login_required
def download_logs():
    if os.path.exists(LOG_PATH):
        return send_file(LOG_PATH, as_attachment=True, download_name="app.log")
    flash("Logdatei nicht gefunden.", "danger")
    return redirect(url_for("logs_page"))

@app.route("/status")
@login_required
def status():
    db.cursor.execute("SELECT timestamp, fahrzeug, status FROM fahrzeuglog ORDER BY timestamp DESC LIMIT 100")
    statuses = [{"timestamp": row[0], "fahrzeug": row[1], "status": row[2]} for row in db.cursor.fetchall()]
    return render_template("status.html", statuses=statuses, mqtt_running=get_status())

@app.route("/clear_status", methods=["POST"])
@login_required
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

@app.route("/settings", methods=["GET"])
@login_required
def settings():
    load_dotenv(dotenv_path=ENV_PATH)
    settings = {k: os.getenv(k, "") for k in [
        "MQTT_BROKER", "MQTT_PORT", "MQTT_TOPIC", "MQTT_STATUS_TOPIC",
        "MQTT_USERNAME", "MQTT_PASSWORD", "FIREPLAN_SECRET", "FIREPLAN_DIVISION",
        "FEUERSOFTWARE_API_TOKEN", "LOG_LEVEL", "AUSWERTUNG_FIREPLAN",
        "AUSWERTUNG_FEUERSOFTWARE", "EXTERNE_API_URL", "EXTERNE_API_TOKEN"
    ]}
    return render_template("settings.html", settings=settings, mqtt_running=get_status())

@app.route("/save_settings", methods=["POST"])
@login_required
def save_settings():
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
            set_key(ENV_PATH, key, value)
            os.environ[key] = value
    new_pw = request.form.get("ADMIN_PASSWORD")
    if new_pw:
        hashed = generate_password_hash(new_pw)
        set_key(ENV_PATH, "ADMIN_PASSWORD", hashed)
        os.environ["ADMIN_PASSWORD"] = hashed
        flash("Admin-Passwort aktualisiert", "success")
    else:
        flash("Einstellungen gespeichert", "success")
    return redirect(url_for("settings"))

@app.route("/tokens")
@login_required
def tokens():
    try:
        with open("config/fs_api_tokens.json", "r", encoding="utf-8") as f:
            tokens = json.load(f)
    except FileNotFoundError:
        tokens = []
    return render_template("token.html", tokens=tokens, mqtt_running=get_status())

@app.route("/save_tokens", methods=["POST"])
@login_required
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
@login_required
def add_token():
    with open("config/fs_api_tokens.json", "r", encoding="utf-8") as f:
        tokens = json.load(f)
    tokens.append({"name": "", "token": ""})
    with open("config/fs_api_tokens.json", "w", encoding="utf-8") as f:
        json.dump(tokens, f, indent=2)
    return redirect(url_for("tokens"))

@app.route("/delete_token", methods=["POST"])
@login_required
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

@app.route("/ric_editor")
@login_required
def ric_editor():
    with open("config/ric_map.json", "r", encoding="utf-8") as f:
        ric_map = json.load(f)
    ric_map_content = "\n".join(f"{k}:{v}" for k, v in ric_map.items())
    return render_template("ric_editor.html", ric_map_content=ric_map_content, mqtt_running=get_status())

@app.route("/save_ric_map", methods=["POST"])
@login_required
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

# === MQTT beim Start automatisch aktivieren ===
try:
    if not get_status():
        start_mqtt()
except Exception as e:
    print(f"Fehler beim Starten von MQTT: {e}")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
