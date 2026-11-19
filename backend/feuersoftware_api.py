import os
import requests
import json
from datetime import datetime
from backend.log_helper import logger

FS_TOKEN_PATH = os.path.join("config", "fs_api_tokens.json")
HTTP_TIMEOUT = (5, 20)  # (Verbindungsaufbau, Antwort) in Sekunden

def load_feuersoftware_tokens(path=FS_TOKEN_PATH):
    if not os.path.exists(path):
        logger.warning("[Feuersoftware] Keine fs_api_tokens.json gefunden.")
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"[Feuersoftware] Fehler beim Laden der Token-Datei: {e}")
        return []

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
        response = requests.post(url, data=json.dumps(data), headers=headers, timeout=HTTP_TIMEOUT)
        if response.status_code in (200, 204):
            logger.info(f"[Feuersoftware] Fahrzeugstatus erfolgreich gesendet: {radioid} → {status}")
        else:
            logger.error(f"[Feuersoftware] Fehler ({response.status_code}): {response.text}")
            logger.debug(f"[Feuersoftware] Payload: {data}")
    except Exception as e:
        logger.exception(f"[Feuersoftware] Ausnahme beim Senden des Fahrzeugstatus: {e}")

def post_feuersoftware_alarm(data: dict):
    if not os.path.exists(FS_TOKEN_PATH):
        logger.warning("[Feuersoftware] Keine fs_api_tokens.json gefunden – Alarm nicht gesendet.")
        return

    try:
        # Eingabedaten vorbereiten
        d = data.get("data", {})
        loc = d.get("location", {})
        custom = d.get("custom", {})
        coord = loc.get("coordinate", [None, None])

        # 🔄 ISE → RIC-Mapping (bereits vorbereitet in main.py)
        ric_raw = custom.get("COBRA_DEVICE_alerted_codes_translated", "")
        ric_list = [r.strip() for r in ric_raw.split(";") if r.strip()]

        if not ric_list:
            logger.warning("[Feuersoftware] Keine gültigen RICs nach Mapping gefunden – kein Alarm gesendet.")
            return

        # 🧾 Zusatzinfos zusammenbauen
        zusatzinfo_parts = [
            custom.get("COBRA_comment"),
            custom.get("COBRA_keyword_diagnosis")
        ]
        zusatzinfo = " – ".join(filter(None, zusatzinfo_parts))

        payload = {
            "Start": datetime.now().isoformat(),
            "Keyword": d.get("keyword_description") or d.get("keyword") or "Alarm",
            "Address": {
                "Street": loc.get("street"),
                "HouseNumber": loc.get("house"),
                "City": loc.get("city")
            },
            "Position": {
                "Latitude": coord[1] if isinstance(coord, list) and len(coord) == 2 else 0,
                "Longitude": coord[0] if isinstance(coord, list) and len(coord) == 2 else 0,
            },
            "Ric": ";".join(ric_list),
            "Number": d.get("externalId"),
            "Facts": zusatzinfo,
            "AlarmEnabled": False
        }

        # 🔁 An alle API-Tokens senden
        tokens = load_feuersoftware_tokens()
        for entry in tokens:
            token = entry.get("token") if isinstance(entry, dict) else entry
            if not token:
                continue

            headers = {
                "authorization": f"bearer {token}",
                "accept": "application/json",
                "content-type": "application/json",
            }

            # Jeder Empfaenger einzeln abgesichert: ein nicht erreichbarer
            # Empfaenger darf die uebrigen Tokens nicht blockieren.
            try:
                response = requests.post(
                    "https://connectapi.feuersoftware.com/interfaces/public/operation",
                    data=json.dumps(payload),
                    headers=headers,
                    timeout=HTTP_TIMEOUT,
                )
            except requests.RequestException as e:
                logger.error(f"[Feuersoftware] Alarm an Token {token[:6]}... nicht zustellbar: {e}")
                continue

            if response.status_code in (200, 204):
                logger.info(f"[Feuersoftware] Alarm erfolgreich gesendet (Token gekürzt: {token[:6]}...).")
            else:
                logger.error(f"[Feuersoftware] Fehler ({response.status_code}): {response.text}")
                logger.debug(f"[Feuersoftware] Payload: {json.dumps(payload, indent=2, ensure_ascii=False)}")

    except Exception as e:
        logger.exception(f"[Feuersoftware] Ausnahme beim Alarm-POST: {e}")
