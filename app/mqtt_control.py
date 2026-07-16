# mqtt_control.py
from backend.mqtt_handler import MQTTHandler
import os
from dotenv import load_dotenv

load_dotenv(dotenv_path=os.path.join("config", ".env"))

mqtt_handler = None

def start_mqtt():
    global mqtt_handler

    # Schon aktiv verbunden? Nichts tun.
    if mqtt_handler is not None and mqtt_handler.is_connected():
        return False

    # Alten (nicht verbundenen) Handler sauber stoppen, bevor neu verbunden wird.
    if mqtt_handler is not None:
        try:
            mqtt_handler.stop()
        except Exception:
            pass
        mqtt_handler = None

    def handle_alarm(data):
        from backend.main import handle_alarm as main_handle_alarm
        main_handle_alarm(data)

    def handle_status(message):
        from backend.main import handle_status_message as main_handle_status
        main_handle_status(message)

    try:
        port = int(os.getenv("MQTT_PORT") or 1883)
    except (TypeError, ValueError):
        port = 1883

    mqtt_handler = MQTTHandler(
        broker=os.getenv("MQTT_BROKER") or "127.0.0.1",
        port=port,
        topic=os.getenv("MQTT_TOPIC") or "Alarm_Topic",
        status_topic=os.getenv("MQTT_STATUS_TOPIC") or "status",
        username=os.getenv("MQTT_USERNAME"),
        password=os.getenv("MQTT_PASSWORD"),
        on_alarm=handle_alarm,
        on_status=handle_status,
        on_disconnect=lambda: None,
        on_reconnect=lambda: None
    )
    mqtt_handler.start()
    return True

def stop_mqtt():
    global mqtt_handler
    if mqtt_handler:
        mqtt_handler.stop()
        mqtt_handler = None
    return True

def get_status():
    # Spiegelt die ECHTE Broker-Verbindung wider (nicht nur "wurde gestartet"),
    # damit die Anzeige nicht faelschlich gruen bleibt, wenn MQTT abgebrochen ist.
    return mqtt_handler is not None and mqtt_handler.is_connected()
