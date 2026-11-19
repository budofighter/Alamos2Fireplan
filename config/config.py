import os
import json
import secrets
from dotenv import load_dotenv
from backend.log_helper import logger
from werkzeug.security import generate_password_hash


ENV_PATH = os.path.join("config", ".env")

# HINWEIS: Die App-Version liegt bewusst in backend/version.py, NICHT hier.
# config/ wird beim Update nicht ueberschrieben und wuerde sonst eine veraltete
# Versionsnummer behalten.

def create_default_env():
    # Nur erstellen, wenn die Datei NICHT existiert
    if not os.path.isfile(ENV_PATH):
        with open(ENV_PATH, "w", encoding="utf-8") as f:
            f.write(
                "MQTT_BROKER=127.0.0.1\n"
                "MQTT_PORT=1883\n"
                "MQTT_TOPIC=Alarm_Topic\n"
                "MQTT_STATUS_TOPIC=status\n"
                "MQTT_USERNAME=mqtt-user\n"
                "MQTT_PASSWORD=mqtt-password\n"
                "FIREPLAN_API_URL=https://fireplan.example/api/\n"
                "FIREPLAN_SECRET=dein_api_key\n"
                "FIREPLAN_DIVISION=API-Abteilung\n"
                "LOG_LEVEL=INFO\n"
                "AUSWERTUNG_FIREPLAN=True\n"
                "AUSWERTUNG_FEUERSOFTWARE=False\n"
                "FEUERSOFTWARE_API_URL=https://\n"
                "FEUERSOFTWARE_API_TOKEN=\n"
                "EXTERNE_API_URL=\n"
                "EXTERNE_API_TOKEN=\n"
                "ADMIN_PASSWORD=" + generate_password_hash("112112") + "\n"
                "SECRET_KEY=" + secrets.token_hex(32) + "\n"
            )
        logger.info(".env-Datei mit Platzhaltern erstellt.")

def migrate_env():
    """Bringt eine bestehende .env (auch aus sehr alten Versionen) auf den
    aktuellen Stand, OHNE vorhandene Werte zu veraendern:
      - entfernt ein UTF-8-BOM (sonst liest python-dotenv den ersten Schluessel
        nicht, z. B. MQTT_BROKER),
      - ergaenzt fehlende Pflichtschluessel (ADMIN_PASSWORD, SECRET_KEY, ...).
    """
    try:
        with open(ENV_PATH, "rb") as f:
            raw = f.read()
    except OSError as e:
        logger.error(f"[Config] .env konnte nicht gelesen werden: {e}")
        return

    changed = False
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
        changed = True
        logger.warning("[Config] UTF-8-BOM in .env entfernt.")

    text = raw.decode("utf-8", errors="replace")
    present = {
        line.split("=", 1)[0].strip()
        for line in text.splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    }

    defaults = {
        "MQTT_TOPIC": "Alarm_Topic",
        "MQTT_STATUS_TOPIC": "status",
        "LOG_LEVEL": "INFO",
        # AUSWERTUNG_* bewusst NICHT ergaenzen: ein fehlender Schalter bedeutet
        # im Alarmpfad "aus" - automatisches Einschalten waere eine
        # Verhaltensaenderung (z. B. ploetzliche Alarmierung ueber Fireplan).
        "EXTERNE_API_URL": "",
        "EXTERNE_API_TOKEN": "",
    }
    additions = [f"{k}={v}" for k, v in defaults.items() if k not in present]
    if "ADMIN_PASSWORD" not in present:
        additions.append("ADMIN_PASSWORD=" + generate_password_hash("112112"))
        logger.warning("[Config] ADMIN_PASSWORD fehlte - Standardpasswort 112112 gesetzt. Bitte aendern!")
    if "SECRET_KEY" not in present:
        additions.append("SECRET_KEY=" + secrets.token_hex(32))

    if additions:
        if text and not text.endswith("\n"):
            text += "\n"
        text += "\n".join(additions) + "\n"
        changed = True
        logger.info(f"[Config] .env ergaenzt um: {', '.join(a.split('=', 1)[0] for a in additions)}")

    if changed:
        tmp = ENV_PATH + ".tmp"
        # newline="": Zeilenenden (LF/CRLF) der bestehenden Datei unveraendert lassen
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        os.replace(tmp, ENV_PATH)  # atomar: nie eine halb geschriebene .env


os.makedirs("config", exist_ok=True)
# Nur beim allerersten Start: Datei mit Platzhaltern anlegen
create_default_env()
# Bei jedem Start: bestehende .env ohne Datenverlust migrieren
migrate_env()

# === Feuersoftware Tokenliste automatisch anlegen ===
FS_TOKEN_PATH = os.path.join("config", "fs_api_tokens.json")
if not os.path.exists(FS_TOKEN_PATH):
    with open(FS_TOKEN_PATH, "w", encoding="utf-8") as f:
        json.dump([], f, indent=2)
    logger.info("fs_api_tokens.json erstellt (leer).")

# === RIC-Mapping-Datei automatisch anlegen ===
RIC_MAP_PATH = os.path.join("config", "ric_map.json")
if not os.path.exists(RIC_MAP_PATH):
    with open(RIC_MAP_PATH, "w", encoding="utf-8") as f:
        json.dump({}, f, indent=2)
    logger.info("ric_map.json erstellt (leer).")

# Jetzt sicher laden
load_dotenv(dotenv_path=ENV_PATH)

# Variablen laden
MQTT_BROKER = os.getenv("MQTT_BROKER", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", 1883))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "Alarm_Topic")
MQTT_STATUS_TOPIC = os.getenv("MQTT_STATUS_TOPIC", "status")
MQTT_USERNAME = os.getenv("MQTT_USERNAME")
MQTT_PASSWORD = os.getenv("MQTT_PASSWORD")

FIREPLAN_API_URL = os.getenv("FIREPLAN_API_URL")
FIREPLAN_SECRET = os.getenv("FIREPLAN_SECRET")
FIREPLAN_DIVISION = os.getenv("FIREPLAN_DIVISION")

AUSWERTUNG_FIREPLAN = os.getenv("AUSWERTUNG_FIREPLAN", "True")
AUSWERTUNG_FEUERSOFTWARE = os.getenv("AUSWERTUNG_FEUERSOFTWARE", "False")
FEUERSOFTWARE_API_URL = os.getenv("FEUERSOFTWARE_API_URL")
FEUERSOFTWARE_API_TOKEN = os.getenv("FEUERSOFTWARE_API_TOKEN")

EXTERNE_API_URL = os.getenv("EXTERNE_API_URL", "")
EXTERNE_API_TOKEN = os.getenv("EXTERNE_API_TOKEN", "")
