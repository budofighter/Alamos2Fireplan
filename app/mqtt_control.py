# mqtt_control.py
from backend.mqtt_handler import MQTTHandler
import os
from dotenv import load_dotenv
from backend.fireplan_api import Fireplan
from backend.db_handler import DBHandler

load_dotenv(dotenv_path=os.path.join("config", ".env"))

mqtt_handler = None
is_running = False

def start_mqtt():
    global mqtt_handler, is_running
    if is_running:
        return False

    db = DBHandler()
    fp = Fireplan()

    def handle_alarm(data):
        from backend.main import handle_alarm as main_handle_alarm
        main_handle_alarm(data)

    def handle_status(message):
        from backend.main import handle_status_message as main_handle_status
        main_handle_status(message)

    mqtt_handler = MQTTHandler(
        broker=os.getenv("MQTT_BROKER"),
        port=int(os.getenv("MQTT_PORT")),
        topic=os.getenv("MQTT_TOPIC"),
        status_topic=os.getenv("MQTT_STATUS_TOPIC"),
        username=os.getenv("MQTT_USERNAME"),
        password=os.getenv("MQTT_PASSWORD"),
        on_alarm=handle_alarm,
        on_status=handle_status,
        on_disconnect=lambda: None,
        on_reconnect=lambda: None
    )
    mqtt_handler.start()
    is_running = True
    return True

def stop_mqtt():
    global mqtt_handler, is_running
    if mqtt_handler:
        mqtt_handler.stop()
        mqtt_handler = None
    is_running = False
    return True

def get_status():
    return is_running
