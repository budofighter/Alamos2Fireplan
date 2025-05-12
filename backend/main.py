import os
import json
from datetime import datetime
from dotenv import load_dotenv
from backend.db_handler import DBHandler
from backend.fireplan_api import Fireplan
from backend.feuersoftware_api import post_fahrzeug_status, post_feuersoftware_alarm
from backend.extern_api import post_externer_status
from backend.log_helper import logger

# .env laden
load_dotenv(dotenv_path=os.path.join("config", ".env"))

# Initialisiere Datenbank und Fireplan
db = DBHandler()
fp = Fireplan()

# === ALARMHANDLING ===
def handle_alarm(data):
    try:
        if data.get("type") != "ALARM":
            logger.info("Kein ALARM-Typ – ignoriert.")
            return

        d = data.get("data", {})
        loc = d.get("location", {})
        custom = d.get("custom", {})

        external_id = d.get("externalId")
        ise_codes_raw = custom.get("COBRA_DEVICE_alerted_codes", "")
        ise_list = [code.strip() for code in ise_codes_raw.split(";") if code.strip()]

        ric_map = load_ric_map()
        translated_rics = set(ric_map.get(code) for code in ise_list if code in ric_map)

        db.cursor.execute("SELECT custom_alerted_rics, update_log FROM alarme WHERE external_id = ?", (external_id,))
        row = db.cursor.fetchone()

        if row:
            logger.info(f"🔄 Bestehender Alarm gefunden (external_id={external_id})")
            existing_rics = set(row[0].split(";")) if row[0] else set()
            new_rics = translated_rics - existing_rics
        else:
            logger.info(f"🆕 Neuer Alarm (external_id={external_id})")
            existing_rics = set()
            new_rics = translated_rics

        if new_rics:
            logger.info(f"✅ Neue RICs zu alarmieren: {new_rics}")
            if os.getenv("AUSWERTUNG_FIREPLAN", "False") == "True":
                for ric in new_rics:
                    payload_copy = build_fireplan_payload(data)
                    payload_copy["ric"] = ric
                    try:
                        fp.alarm(payload_copy)
                        logger.info(f"🚨 Alarm an Fireplan für RIC {ric}")
                    except Exception as e:
                        logger.warning(f"[Fireplan] Fehler: {e}")

            if os.getenv("AUSWERTUNG_FEUERSOFTWARE", "False") == "True":
                custom["COBRA_DEVICE_alerted_codes_translated"] = ";".join(new_rics)
                try:
                    post_feuersoftware_alarm(data)
                except Exception as e:
                    logger.warning(f"[Feuersoftware] Fehler: {e}")

        update_log = []
        if row and row[1]:
            try:
                update_log = json.loads(row[1])
            except Exception:
                logger.warning(f"[DB] Update-Log konnte nicht geparst werden")

        update_log.append({
            "timestamp": datetime.now().isoformat(),
            "new_rics": sorted(list(new_rics))
        })

        alarm_data = {
            "timestamp": data.get("timestamp"),
            "externalId": external_id,
            "keyword": d.get("keyword"),
            "keyword_description": d.get("keyword_description"),
            "message": " ".join(d.get("message", [])) if d.get("message") else None,
            "building": loc.get("building"),
            "street": loc.get("street"),
            "house": loc.get("house"),
            "postalCode": loc.get("postalCode"),
            "city": loc.get("city"),
            "city_abbr": loc.get("city_abbr"),
            "units": ", ".join([u.get("address", "") for u in d.get("units", [])]) if d.get("units") else None,
            "vehicles": json.dumps(d.get("vehicles", []), ensure_ascii=False),
            "alarmedTime": datetime.now().isoformat(),
            "coordinate": json.dumps(loc.get("coordinate"), ensure_ascii=False) if loc.get("coordinate") else None,
            "custom_comment": custom.get("COBRA_comment"),
            "custom_diagnosis": custom.get("COBRA_keyword_diagnosis"),
            "custom_alerted": custom.get("COBRA_DEVICE_alerted"),
            "custom_alerted_semicolon": custom.get("COBRA_DEVICE_alerted_semicolon"),
            "custom_alerted_codes": ise_codes_raw,
            "custom_alerted_rics": ";".join(sorted(existing_rics.union(translated_rics))),
            "custom_alarm_state": custom.get("alarmState"),
            "update_log": json.dumps(update_log, ensure_ascii=False),
            "raw_json": json.dumps(data, ensure_ascii=False)
        }

        db.log_alarm(alarm_data)

    except Exception as e:
        logger.error(f"Fehler in handle_alarm: {e}")

# === Fahrzeugstatus ===
def handle_status_message(message):
    logger.info(f"Statusmeldung empfangen: {message}")
    try:
        import re
        match = re.search(r"Status\s+(\d)\s+für\s+(.+)", message)
        if not match:
            logger.warning("Statusmeldung konnte nicht erkannt werden.")
            return

        status = int(match.group(1))
        fahrzeug = match.group(2).strip()
        timestamp = datetime.now().isoformat()

        logger.info(f"Fahrzeug '{fahrzeug}' hat neuen Status: {status}")
        db.cursor.execute(
            "INSERT INTO fahrzeuglog (timestamp, fahrzeug, status) VALUES (?, ?, ?)",
            (timestamp, fahrzeug, status)
        )
        db.conn.commit()

        if os.getenv("AUSWERTUNG_FIREPLAN", "True") == "True":
            try:
                fp.send_fms_status(fahrzeug, status, timestamp)
            except Exception as e:
                logger.warning(f"[Fireplan] Fehler beim Senden des Fahrzeugstatus: {e}")
        if os.getenv("AUSWERTUNG_FEUERSOFTWARE", "False") == "True":
            try:
                post_fahrzeug_status(fahrzeug, status)
            except Exception as e:
                logger.warning(f"[Feuersoftware] Fehler beim Senden des Fahrzeugstatus: {e}")

        if os.getenv("EXTERNE_API_URL") and os.getenv("EXTERNE_API_TOKEN"):
            try:
                post_externer_status(fahrzeug, status)
            except Exception as e:
                logger.warning(f"[Externe API] Fehler beim Senden: {e}")

    except Exception as e:
        logger.error(f"Fehler beim Verarbeiten der Statusmeldung: {e}")

# === Helper-Tools ===
def load_ric_map(path=os.path.join("config", "ric_map.json")):
    if not os.path.exists(path):
        logger.info("[RIC MAP] Keine Datei gefunden – lege leere ric_map.json an.")
        with open(path, "w", encoding="utf-8") as f:
            json.dump({}, f, indent=2)
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        logger.error(f"[RIC MAP] Fehler beim Laden: {e}")
        return {}

def build_fireplan_payload(alamos_data):
    d = alamos_data.get("data", {})
    loc = d.get("location", {})
    custom = d.get("custom", {})
    coord = loc.get("coordinate")

    ise_codes = custom.get("COBRA_DEVICE_alerted_codes", "")
    ise_list = ise_codes.split(";")
    ric_map = load_ric_map()
    translated_rics = [ric_map[code] for code in ise_list if code in ric_map]
    ric_string = ";".join(translated_rics)

    koord = None
    if isinstance(coord, (list, tuple)) and len(coord) == 2:
        koord = f"{coord[1]}, {coord[0]}"

    zusatzinfo_parts = [
        custom.get("COBRA_comment"),
        custom.get("COBRA_keyword_diagnosis")
    ]
    zusatzinfo = " – ".join(filter(None, zusatzinfo_parts))

    return {
        "einsatzstichwort": d.get("keyword_description"),
        "strasse": loc.get("street"),
        "hausnummer": loc.get("house"),
        "ort": loc.get("city"),
        "ortsteil": custom.get("city_abbr"),
        "objektname": loc.get("building"),
        "zusatzinfo": zusatzinfo,
        "einsatznrlst": d.get("externalId"),
        "koordinaten": koord,
        "ric": ric_string,
        "subRIC": "A"
    }

def reload_runtime_config():
    logger.info("🔄 Laufzeitkonfiguration wird neu geladen...")
    load_dotenv(dotenv_path=os.path.join("config", ".env"), override=True)
    global fp
    fp = Fireplan()
    logger.info("✅ Fireplan-API wurde mit neuen Einstellungen neu initialisiert.")
