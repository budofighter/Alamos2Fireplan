import json
import time
import threading
import paho.mqtt.client as mqtt
from backend.log_helper import logger


class MQTTHandler:
    def __init__(
        self,
        broker='localhost',
        port=1883,
        topic='Alarm_Topic',
        status_topic='status',
        username=None,
        password=None,
        client_id="alamos2fireplan",
        on_alarm=None,
        on_status=None,
        on_disconnect=None,
        on_reconnect=None
    ):
        self.broker = broker
        self.port = port
        self.topic = topic
        self.status_topic = status_topic
        self.username = username
        self.password = password
        self.client_id = client_id
        self.on_alarm = on_alarm
        self.on_status = on_status
        self.on_disconnect_callback = on_disconnect
        self.on_reconnect_callback = on_reconnect

        self.client = mqtt.Client(client_id=self.client_id, protocol=mqtt.MQTTv311)

        if self.username and self.password:
            self.client.username_pw_set(self.username, self.password)

        self.client.on_connect = self.on_connect
        self.client.on_message = self.on_message
        self.client.on_disconnect = self.on_disconnect

        self._running = False

    def on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            logger.info(f"[MQTT] Erfolgreich verbunden mit {self.broker}:{self.port}")
            self.client.subscribe(self.topic)
            logger.info(f"[MQTT] Abonniert: {self.topic}")

            if self.status_topic:
                self.client.subscribe(self.status_topic)
                logger.info(f"[MQTT] Abonniert: {self.status_topic}")

            if self.on_reconnect_callback:
                self.on_reconnect_callback()
        else:
            logger.error(f"[MQTT] Verbindungsfehler (rc={rc})")

    def on_disconnect(self, client, userdata, rc):
        if rc != 0:
            logger.warning("[MQTT] Verbindung unerwartet verloren – versuche Reconnect...")
            if self.on_disconnect_callback:
                self.on_disconnect_callback()
            self._start_reconnect_loop()

    def _start_reconnect_loop(self):
        def loop():
            while self._running:
                try:
                    logger.debug("[MQTT] Reconnect-Versuch...")
                    self.client.reconnect()
                    logger.info("[MQTT] Reconnect erfolgreich.")
                    break
                except Exception as e:
                    logger.debug(f"[MQTT] Reconnect fehlgeschlagen: {e}")
                    time.sleep(5)

        threading.Thread(target=loop, daemon=True).start()

    def on_message(self, client, userdata, message):
        try:
            payload_str = message.payload.decode('utf-8')
            logger.debug(f"[MQTT] Nachricht empfangen auf Topic '{message.topic}': {payload_str}")

            # Alarm-Topic → JSON erwartet
            if message.topic == self.topic:
                data = json.loads(payload_str)
                if self.on_alarm:
                    self.on_alarm(data)

            # Status-Topic → Klartext erwartet
            elif message.topic == self.status_topic:
                if self.on_status:
                    self.on_status(payload_str)

        except json.JSONDecodeError:
            logger.error("[MQTT] Fehler beim Parsen der JSON-Daten.")
        except Exception as e:
            logger.error(f"[MQTT] Fehler beim Empfangen der Nachricht: {e}")

    def start(self):
        try:
            self._running = True
            logger.info(f"[MQTT] Verbinde zu {self.broker}:{self.port}...")
            self.client.connect(self.broker, self.port)
            self.client.loop_start()
        except Exception as e:
            logger.error(f"[MQTT] Fehler beim Start: {e}")
            self._running = False 


    def stop(self):
        self._running = False
        self.client.loop_stop()
        self.client.disconnect()
        logger.info("[MQTT] Verbindung beendet.")
