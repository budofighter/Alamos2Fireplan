import json
from concurrent.futures import ThreadPoolExecutor
import paho.mqtt.client as mqtt
from backend.log_helper import logger


class MQTTHandler:
    """MQTT-Anbindung mit automatischem Wiederverbinden.

    Robustheits-Eigenschaften:
      * connect_async + loop_start: paho baut die Verbindung im Hintergrund auf
        und versucht es selbststaendig erneut (auch wenn der Broker beim
        Systemstart noch nicht laeuft). Kein eigener Reconnect-Thread noetig.
      * Persistente Sitzung (clean_session=False) + QoS 1: der Broker puffert
        Alarme, die waehrend eines Neustarts/Updates eintreffen, und liefert sie
        nach dem Wiederverbinden nach (sofern Alamos mit QoS >= 1 sendet).
      * Verarbeitung in einem eigenen Worker-Thread: langsame HTTP-Aufrufe
        (Fireplan/Feuersoftware) blockieren nicht den MQTT-Netzwerk-Thread
        (sonst Keepalive-Abbrueche). max_workers=1 erhaelt die Reihenfolge.
    """

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

        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=self.client_id,
            protocol=mqtt.MQTTv311,
            clean_session=False,
        )

        if self.username and self.password:
            self.client.username_pw_set(self.username, self.password)

        # Wiederverbinden mit wachsender Wartezeit (1 s ... 60 s)
        self.client.reconnect_delay_set(min_delay=1, max_delay=60)

        self.client.on_connect = self.on_connect
        self.client.on_message = self.on_message
        self.client.on_disconnect = self.on_disconnect
        self.client.on_connect_fail = self.on_connect_fail

        self._fail_logged = False
        self._executor = None
        self._running = False

    # ---- paho-Callbacks (CallbackAPIVersion.VERSION2) ----
    def on_connect(self, client, userdata, flags, reason_code, properties=None):
        if not reason_code.is_failure:
            self._fail_logged = False
            logger.info(f"[MQTT] Erfolgreich verbunden mit {self.broker}:{self.port}")
            # Bei jeder (Neu-)Verbindung abonnieren - noetig, falls der Broker
            # die Sitzung verloren hat (z. B. Broker-Neustart).
            self.client.subscribe(self.topic, qos=1)
            logger.info(f"[MQTT] Abonniert: {self.topic}")

            if self.status_topic:
                self.client.subscribe(self.status_topic, qos=1)
                logger.info(f"[MQTT] Abonniert: {self.status_topic}")

            if self.on_reconnect_callback:
                self.on_reconnect_callback()
        else:
            logger.error(f"[MQTT] Verbindungsfehler: {reason_code} - neuer Versuch folgt automatisch.")

    def on_connect_fail(self, client, userdata):
        # Broker (noch) nicht erreichbar. Nur einmal pro Ausfall loggen, damit
        # das Log bei laengerem Ausfall nicht vollaeuft; paho versucht weiter.
        if not self._fail_logged:
            self._fail_logged = True
            logger.warning(f"[MQTT] Broker {self.broker}:{self.port} nicht erreichbar - versuche es automatisch weiter.")

    def on_disconnect(self, client, userdata, disconnect_flags, reason_code, properties=None):
        if self._running:
            logger.warning(f"[MQTT] Verbindung verloren ({reason_code}) - automatischer Reconnect laeuft...")
            if self.on_disconnect_callback:
                self.on_disconnect_callback()

    def on_message(self, client, userdata, message):
        # Nur annehmen und an den Worker uebergeben - nie im Netzwerk-Thread blockieren.
        try:
            executor = self._executor
            if executor is None:
                return
            executor.submit(self._process_message, message.topic, message.payload)
        except Exception as e:
            logger.error(f"[MQTT] Nachricht konnte nicht zur Verarbeitung uebergeben werden: {e}")

    def _process_message(self, topic, payload):
        try:
            payload_str = payload.decode('utf-8', errors='replace')
            logger.debug(f"[MQTT] Nachricht empfangen auf Topic '{topic}': {payload_str}")

            # Alarm-Topic → JSON erwartet
            if topic == self.topic:
                data = json.loads(payload_str)
                if self.on_alarm:
                    self.on_alarm(data)

            # Status-Topic → Klartext erwartet
            elif topic == self.status_topic:
                if self.on_status:
                    self.on_status(payload_str)

        except json.JSONDecodeError:
            logger.error("[MQTT] Fehler beim Parsen der JSON-Daten.")
        except Exception as e:
            logger.exception(f"[MQTT] Fehler beim Verarbeiten der Nachricht: {e}")

    # ---- Steuerung ----
    def start(self):
        try:
            self._running = True
            self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mqtt-worker")
            logger.info(f"[MQTT] Verbinde zu {self.broker}:{self.port}...")
            # connect_async: kein Abbruch, wenn der Broker (noch) nicht erreichbar
            # ist - der Netzwerk-Thread versucht es selbststaendig weiter.
            self.client.connect_async(self.broker, self.port, keepalive=60)
            self.client.loop_start()
        except Exception as e:
            logger.error(f"[MQTT] Fehler beim Start: {e}")
            self._running = False

    def stop(self):
        self._running = False
        try:
            self.client.disconnect()
        except Exception:
            pass
        try:
            self.client.loop_stop()
        except Exception:
            pass
        if self._executor is not None:
            # Laufende Verarbeitung (z. B. Alarm an Fireplan) noch beenden lassen
            self._executor.shutdown(wait=True, cancel_futures=False)
            self._executor = None
        logger.info("[MQTT] Verbindung beendet.")

    def is_running(self):
        return self._running

    def is_connected(self):
        # Echte, aktuelle Verbindung zum Broker (nicht nur "wurde gestartet").
        try:
            return bool(self.client.is_connected())
        except Exception:
            return False
