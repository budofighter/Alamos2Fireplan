import os
import json
import requests
from backend.log_helper import logger
from requests.structures import CaseInsensitiveDict
import config  # noqa: F401  (legt config/.env an und laedt sie)

HTTP_TIMEOUT = (5, 20)  # (Verbindungsaufbau, Antwort) in Sekunden


def post_externer_status(radioid: str, status: int):
    # URL/Token zur Laufzeit lesen, damit Aenderungen in den Einstellungen
    # ohne Dienst-Neustart greifen.
    url = os.getenv("EXTERNE_API_URL", "")
    token = os.getenv("EXTERNE_API_TOKEN", "")
    if not url or not token:
        logger.debug("[Externe API] Kein URL oder Token gesetzt – kein Versand.")
        return

    try:
        opta = radioid.replace(" ", "").replace("/", "")  # clean up

        headers = CaseInsensitiveDict()
        headers["Content-Type"] = "application/json"
        headers["X-Api-Key"] = token

        payload = {
            "opta": opta,
            "status": status
        }

        response = requests.post(url, headers=headers, data=json.dumps(payload), timeout=HTTP_TIMEOUT)

        if response.status_code == 200:
            logger.info(f"[Externe API] Status erfolgreich gesendet: {opta} → {status}")
        else:
            logger.error(f"[Externe API] Fehler ({response.status_code}): {response.text}")

    except Exception as e:
        logger.exception(f"[Externe API] Ausnahme beim Senden: {e}")
