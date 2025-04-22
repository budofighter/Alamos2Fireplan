import requests
import json
from log_helper import logger
from requests.structures import CaseInsensitiveDict
from config import EXTERNE_API_URL, EXTERNE_API_TOKEN


def post_externer_status(radioid: str, status: int):
    if not EXTERNE_API_URL or not EXTERNE_API_TOKEN:
        logger.debug("[Externe API] Kein URL oder Token gesetzt – kein Versand.")
        return

    try:
        opta = radioid.replace(" ", "").replace("/", "")  # clean up

        headers = CaseInsensitiveDict()
        headers["Content-Type"] = "application/json"
        headers["X-Api-Key"] = EXTERNE_API_TOKEN

        payload = {
            "opta": opta,
            "status": status
        }

        response = requests.post(EXTERNE_API_URL, headers=headers, data=json.dumps(payload))

        if response.status_code == 200:
            logger.info(f"[Externe API] Status erfolgreich gesendet: {opta} → {status}")
        else:
            logger.error(f"[Externe API] Fehler ({response.status_code}): {response.text}")

    except Exception as e:
        logger.exception(f"[Externe API] Ausnahme beim Senden: {e}")
