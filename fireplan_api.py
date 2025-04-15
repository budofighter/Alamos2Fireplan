import requests
import cerberus
import sys
import os
import pytz
from datetime import datetime
from urllib.parse import quote
from config import FIREPLAN_SECRET, FIREPLAN_DIVISION
from log_helper import logger  # zentraler Logger

# Schema Definition
ALARM_SCHEMA = {
    "ric": {"type": "string", "nullable": True},
    "subRIC": {"type": "string", "nullable": True},
    "einsatznrlst": {"type": "string", "nullable": True},
    "strasse": {"type": "string", "nullable": True},
    "hausnummer": {"type": "string", "nullable": True},
    "ort": {"type": "string", "nullable": True},
    "ortsteil": {"type": "string", "nullable": True},
    "objektname": {"type": "string", "nullable": True},
    "koordinaten": {"type": "string", "nullable": True},
    "einsatzstichwort": {"type": "string", "nullable": True},
    "zusatzinfo": {"type": "string", "nullable": True}
}


class Fireplan:
    BASE_URL = "https://data.fireplan.de/api/"

    def __init__(self, secret=None, division=None):
        self._secret = secret or FIREPLAN_SECRET
        self._division = division or FIREPLAN_DIVISION
        logger.debug(f"Initialisierung mit Registration ID {self._secret} und Abteilung {self._division}")
        self.headers = {
            "accept": "application/json",
            "content-type": "application/json",
        }
        self._get_token(self._secret)
        self.validator = cerberus.Validator(ALARM_SCHEMA, purge_unknown=True)

    def _get_token(self, secret):
        encoded_division = quote(self._division)  # z. B. „Bad Säckingen“ → „Bad%20S%C3%A4ckingen“
        url = f"{self.BASE_URL}Register/{encoded_division}"
        headers = {
            "accept": "application/json",
            "API-Key": secret
        }

        try:
            logger.debug(f"[Fireplan] Token-Anfrage an: {url}")
            response = requests.get(url, headers=headers)

            logger.debug(f"[Fireplan] Antwortcode: {response.status_code}")
            logger.debug(f"[Fireplan] Antworttext: {response.text}")

            if response.status_code == 200:
                response_json = response.json()
                token = response_json.get("utoken")

                if token:
                    self.headers["API-Token"] = token
                    logger.info("[Fireplan] API-Token erfolgreich gespeichert.")
                else:
                    logger.error("[Fireplan] Kein 'utoken' in der Antwort erhalten.")
            else:
                logger.error(f"[Fireplan] Registrierung fehlgeschlagen. Code: {response.status_code}")
                logger.error(response.text)

        except Exception as e:
            logger.error(f"[Fireplan] Fehler beim Abrufen des Tokens: {e}")


    def alarm(self, data):
        url = f"{self.BASE_URL}Alarmierung"
        headers = self.headers

        try:
            response = requests.post(url, headers=headers, json=data)

            if response.status_code == 200:
                logger.info("Neue Alarmmeldung an Fireplan gesendet.")
                if "SUCCESS" in response.text:
                    logger.info(f"Alarm erfolgreich angelegt. Antwort: {response.text}")
                else:
                    logger.warning(f"Alarm NICHT angelegt. Antwort: {response.text}")
            else:
                logger.error(f"Fehler beim Senden des Alarms. Code: {response.status_code}")
                logger.error(response.text)

            logger.debug(f"Gesendete Daten: {data}")
        except Exception as e:
            logger.error(f"Fehler beim Senden des Alarms an Fireplan: {e}")

    def send_fms_status(self, kennung, status, timestamp=None):
        url = f"{self.BASE_URL}FMSStatus"
        headers = self.headers

        if 'API-Token' not in self.headers or not self.headers['API-Token']:
            logger.error("[Fireplan] Kein API-Token vorhanden – Registrierung war nicht erfolgreich.")
            return

        try:
            if not kennung or not str(status).isdigit():
                logger.warning(f"[Fireplan] Ungültige FMS-Daten: kennung={kennung}, status={status}")
                return

            if timestamp:
                try:
                    dt = datetime.fromtimestamp(int(str(timestamp)[:10]), pytz.timezone("Europe/Berlin"))
                except Exception:
                    logger.warning("[Fireplan] Timestamp konnte nicht geparst werden – aktuelle Zeit wird verwendet.")
                    dt = datetime.now(pytz.timezone("Europe/Berlin"))
            else:
                dt = datetime.now(pytz.timezone("Europe/Berlin"))

            status_time = dt.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'

            payload = {
                "fzkennung": kennung,
                "status": str(status),  # ✅ Jetzt als String!
                "statusTime": status_time
            }

            logger.debug(f"[Fireplan] Header bei FMS-Status: {headers}")
            response = requests.post(url, headers=headers, json=payload)

            if response.status_code == 200:
                logger.info(f"[Fireplan] FMS-Status gesendet: {kennung} → {status} ({status_time})")
            else:
                logger.error(f"[Fireplan] Fehler bei FMS-Status-Übermittlung ({response.status_code}): {response.text}")
                logger.debug(f"[Fireplan] Payload war: {payload}")

        except Exception as e:
            logger.error(f"[Fireplan] Fehler bei FMS-Statusmeldung: {e}")
