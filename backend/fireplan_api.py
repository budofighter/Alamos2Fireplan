import os
import requests
import cerberus
import json
import pytz
from datetime import datetime
from urllib.parse import quote
import config  # noqa: F401  (legt config/.env an und laedt sie)
from backend.log_helper import logger  # zentraler Logger

# (Verbindungsaufbau, Antwort) in Sekunden. Ohne Timeout kann ein haengender
# Fireplan-Server den MQTT-Verarbeitungs-Thread unbegrenzt blockieren.
HTTP_TIMEOUT = (5, 20)

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
        # Werte zur Laufzeit aus der Umgebung lesen (nicht beim Import einfrieren),
        # damit geaenderte Einstellungen nach reload_runtime_config() greifen.
        self._secret = secret or os.getenv("FIREPLAN_SECRET") or ""
        self._division = division or os.getenv("FIREPLAN_DIVISION") or ""
        logger.debug(f"[Fireplan] Initialisierung fuer Abteilung {self._division}")
        self.headers = {
            "accept": "application/json",
            "content-type": "application/json",
        }
        self._get_token(self._secret)
        self.validator = cerberus.Validator(ALARM_SCHEMA, purge_unknown=True)

    def _get_token(self, secret):
        if not secret or not self._division:
            logger.warning("[Fireplan] FIREPLAN_SECRET/FIREPLAN_DIVISION nicht gesetzt - keine Registrierung.")
            return
        encoded_division = quote(self._division)  # z. B. „Bad Säckingen“ → „Bad%20S%C3%A4ckingen“
        url = f"{self.BASE_URL}Register/{encoded_division}"
        headers = {
            "accept": "application/json",
            "API-Key": secret
        }

        try:
            logger.debug(f"[Fireplan] Token-Anfrage an: {url}")
            response = requests.get(url, headers=headers, timeout=HTTP_TIMEOUT)

            logger.debug(f"[Fireplan] Antwortcode: {response.status_code}")
            logger.debug(f"[Fireplan] Antworttext: {response.text[:500]}")

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


    def _ensure_token(self):
        # War die Registrierung beim Start nicht moeglich (z. B. kein Internet
        # beim Booten), hier erneut versuchen statt dauerhaft ohne Token zu laufen.
        if not self.headers.get("API-Token"):
            logger.info("[Fireplan] Kein API-Token vorhanden - versuche erneute Registrierung.")
            self._get_token(self._secret)
        return bool(self.headers.get("API-Token"))

    def alarm(self, data):
        url = f"{self.BASE_URL}Alarmierung"
        if not self._ensure_token():
            logger.error("[Fireplan] Alarm nicht gesendet - keine gueltige Registrierung (API-Key/Abteilung pruefen).")
            return
        headers = self.headers

        data["koordinaten"] = self._format_coordinates(data.get("koordinaten"))

        # Nur gültige Felder behalten
        validator = cerberus.Validator(ALARM_SCHEMA, purge_unknown=True)
        valid = validator.validated(data)

        if not valid:
            logger.error("[Fireplan] Ungültige Alarmdaten – Validierung fehlgeschlagen:")
            logger.error(validator.errors)
            return
        else:
            logger.debug("[Fireplan] Alarmdaten erfolgreich validiert.")
            logger.debug(f"[Fireplan] Validierte Payload:\n{json.dumps(valid, indent=2, ensure_ascii=False)}")


        try:
            logger.debug(f"[Fireplan] Sende Alarmdaten an Fireplan:\n{json.dumps(valid, indent=2, ensure_ascii=False)}")
            response = requests.post(url, headers=headers, json=valid, timeout=HTTP_TIMEOUT)

            # Token abgelaufen/ungueltig -> einmal neu registrieren und wiederholen
            if response.status_code in (401, 403):
                logger.warning(f"[Fireplan] Auth fehlgeschlagen (Code {response.status_code}) - hole neues Token und wiederhole.")
                self._get_token(self._secret)
                response = requests.post(url, headers=self.headers, json=valid, timeout=HTTP_TIMEOUT)

            if response.status_code == 200:
                logger.info("✅ Alarm erfolgreich an Fireplan übermittelt.")
                if "SUCCESS" in response.text:
                    logger.info(f"[Fireplan] Antwort: {response.text}")
                else:
                    logger.warning(f"[Fireplan] Antwort enthält kein 'SUCCESS': {response.text}")
            else:
                logger.error(f"❌ Fehler beim Senden des Alarms an Fireplan (HTTP {response.status_code})")
                logger.error(response.text)

        except Exception as e:
            logger.error(f"[Fireplan] Ausnahme beim Senden des Alarms: {e}")


    def send_fms_status(self, kennung, status, timestamp=None):
        url = f"{self.BASE_URL}FMSStatus"
        headers = self.headers

        if not self._ensure_token():
            logger.error("[Fireplan] Kein API-Token vorhanden – Registrierung war nicht erfolgreich.")
            return

        try:
            if not kennung or not str(status).isdigit():
                logger.warning(f"[Fireplan] Ungültige FMS-Daten: kennung={kennung}, status={status}")
                return

            dt = datetime.now(pytz.timezone("Europe/Berlin"))

            status_time = dt.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'

            payload = {
                "fzkennung": kennung,
                "status": str(status),  # ✅ Jetzt als String!
                "statusTime": status_time
            }

            response = requests.post(url, headers=headers, json=payload, timeout=HTTP_TIMEOUT)

            # Token abgelaufen/ungueltig -> einmal neu registrieren und wiederholen
            if response.status_code in (401, 403):
                logger.warning(f"[Fireplan] Auth fehlgeschlagen (Code {response.status_code}) - hole neues Token und wiederhole.")
                self._get_token(self._secret)
                response = requests.post(url, headers=self.headers, json=payload, timeout=HTTP_TIMEOUT)

            if response.status_code == 200:
                logger.info(f"[Fireplan] FMS-Status gesendet: {kennung} → {status} ({status_time})")
            else:
                logger.error(f"[Fireplan] Fehler bei FMS-Status-Übermittlung ({response.status_code}): {response.text}")
                logger.debug(f"[Fireplan] Payload war: {payload}")

        except Exception as e:
            logger.error(f"[Fireplan] Fehler bei FMS-Statusmeldung: {e}")


    def _format_coordinates(self, coord_raw):
        if isinstance(coord_raw, (list, tuple)) and len(coord_raw) == 2:
            return f"{coord_raw[1]}, {coord_raw[0]}"
        if isinstance(coord_raw, str):
            return coord_raw
        return None

