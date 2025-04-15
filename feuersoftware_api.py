import os
import requests
import json
from log_helper import logger
from dotenv import load_dotenv

load_dotenv()

def post_fahrzeug_status(radioid, status):
    radioid = radioid.replace(" ", "").replace("/", "")

    token = os.getenv("FEUERSOFTWARE_API_TOKEN")
    if not token:
        logger.error("[Feuersoftware] Kein API-Token gesetzt! Bitte .env prüfen.")
        return

    headers = {
        "authorization": f"bearer {token}",
        "accept": "application/json",
        "content-type": "application/json",
    }

    url = f"https://connectapi.feuersoftware.com/interfaces/public/vehicle/{radioid}/status"
    data = {"status": status}

    try:
        response = requests.post(url, data=json.dumps(data), headers=headers)
        if response.status_code == 200 or response.status_code == 204:
            logger.info(f"[Feuersoftware] Fahrzeugstatus erfolgreich gesendet: {radioid} → {status}")
        else:
            logger.error(f"[Feuersoftware] Fehler ({response.status_code}): {response.text}")
            logger.debug(f"[Feuersoftware] Payload: {data}")
    except Exception as e:
        logger.exception(f"[Feuersoftware] Ausnahme beim Senden des Fahrzeugstatus: {e}")
