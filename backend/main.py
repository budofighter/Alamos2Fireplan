import os
import json
from datetime import datetime
from dotenv import load_dotenv
from backend.db_handler import DBHandler
from backend.fireplan_api import Fireplan
from backend.feuersoftware_api import post_fahrzeug_status, post_feuersoftware_alarm
from backend.extern_api import post_externer_status
from backend.log_helper import logger
from concurrent.futures import ThreadPoolExecutor, as_completed


# .env laden
load_dotenv(dotenv_path=os.path.join("config", ".env"))

# Initialisiere Datenbank und Fireplan
db = DBHandler()
fp = Fireplan()

# === ALARMHANDLING ===
def handle_alarm(data):
    try:
        if not data or data.get("type") != "ALARM":
            logger.info("Kein ALARM-Typ oder leere Daten – ignoriert.")
            return

        d = data.get("data")
        if not d:
            logger.warning("ALARM erhalten, aber kein 'data'-Inhalt vorhanden – abgebrochen.")
            return

        external_id = d.get("externalId")
        if not external_id:
            logger.warning("ALARM erhalten, aber ohne 'externalId' – abgebrochen.")
            return

        loc = d.get("location", {})
        if not loc.get("city"):
            loc["city"] = ""
            logger.warning(f"[ALARM] Ort fehlt in Alarm (external_id={external_id}) – 'Unbekannt' verwendet.")

        custom = d.get("custom", {})


        ise_codes_raw = custom.get("COBRA_DEVICE_alerted_codes", "")
        ise_list = [code.strip() for code in ise_codes_raw.split(";") if code.strip()]

        ric_map = load_ric_map()
        translated_rics = {
            ric for code in ise_list
            if (ric := ric_map.get(code))
        }
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

        def _send_fireplan_for_ric(ric: str):
            payload = build_fireplan_payload(data)
            payload["ric"] = ric
            fp.alarm(payload)  # fp.alarm loggt intern Erfolg/Fehler bereits
            return ric

        if new_rics:
            logger.info(f"✅ Neue RICs zu alarmieren: {new_rics}")
            if os.getenv("AUSWERTUNG_FIREPLAN", "False") == "True":
                # Parallel pro RIC senden (I/O-bound)
                max_workers = min(8, max(1, len(new_rics)))  # begrenzen, aber dynamisch
                with ThreadPoolExecutor(max_workers=max_workers) as ex:
                    futures = {ex.submit(_send_fireplan_for_ric, ric): ric for ric in new_rics}

                    for fut in as_completed(futures):
                        ric = futures[fut]
                        try:
                            fut.result()
                            logger.info(f"🚨 Alarm an Fireplan für RIC {ric}")
                        except Exception as e:
                            logger.warning(f"[Fireplan] Fehler bei RIC {ric}: {e}")

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
            "COBRA_LOCATION_property": custom.get("COBRA_LOCATION_property"),
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
        koord = f"{coord[1]},{coord[0]}"

    zusatzinfo_parts = [
        custom.get("COBRA_comment"),
        custom.get("COBRA_keyword_diagnosis")
    ]
    zusatzinfo = " – ".join(filter(None, zusatzinfo_parts))

    return {
        "einsatzstichwort": d.get("keyword_description") or "",
        "strasse": loc.get("street") or "",
        "hausnummer": loc.get("house") or "",
        "ort": loc.get("city") or "",
        "ortsteil": custom.get("city_abbr") or "",
        "objekt": custom.get("COBRA_LOCATION_property") or "",
        "objektname": loc.get("building") or "",
        "zusatzinfo": zusatzinfo or "",
        "einsatznrlst": d.get("externalId") or "",
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
