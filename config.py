import os
from dotenv import load_dotenv
from log_helper import logger

ENV_PATH = ".env"

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
                "APP_VERSION=1.0.0\n"
                "AUSWERTUNG_FIREPLAN=True\n"
                "AUSWERTUNG_FEUERSOFTWARE=False\n"
                "FEUERSOFTWARE_API_URL=https://\n"
                "FEUERSOFTWARE_API_TOKEN=\n"
            )
        logger.info("🆕 .env-Datei mit Platzhaltern erstellt.")

# Nur beim allerersten Start ausführen
create_default_env()

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
APP_VERSION = os.getenv("APP_VERSION", "0.9.5")

AUSWERTUNG_FIREPLAN = os.getenv("AUSWERTUNG_FIREPLAN", "True")
AUSWERTUNG_FEUERSOFTWARE = os.getenv("AUSWERTUNG_FEUERSOFTWARE", "False")
FEUERSOFTWARE_API_URL = os.getenv("FEUERSOFTWARE_API_URL")
FEUERSOFTWARE_API_TOKEN = os.getenv("FEUERSOFTWARE_API_TOKEN")
