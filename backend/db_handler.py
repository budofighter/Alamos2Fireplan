import sqlite3
import threading
from backend.log_helper import logger

class DBHandler:
    def __init__(self, db_file='alarme.db'):
        # timeout=30: wartet bei gesperrter DB bis zu 30s, statt sofort
        # "database is locked" zu werfen (mehrere Verbindungen: Web + MQTT-Thread).
        self.conn = sqlite3.connect(db_file, check_same_thread=False, timeout=30)
        self.conn.row_factory = sqlite3.Row  # WICHTIG: ermöglicht Zugriff mit row['id']
        # WAL erlaubt gleichzeitige Leser + einen Schreiber ohne gegenseitiges Blockieren.
        try:
            self.conn.execute("PRAGMA journal_mode=WAL")
        except Exception as e:
            logger.warning(f"[DB] WAL-Modus konnte nicht aktiviert werden: {e}")
        self.cursor = self.conn.cursor()
        # Serialisiert alle DB-Zugriffe dieser Verbindung (Cursor ist nicht thread-safe).
        self._lock = threading.RLock()
        self._ensure_table()
        self._ensure_status_table()
        logger.info("SQLite-Verbindung hergestellt und Tabellen vorbereitet.")

    # ---- Thread-sichere Zugriffshelfer (eigener Cursor je Aufruf, unter Lock) ----
    def query_all(self, sql, params=()):
        with self._lock:
            cur = self.conn.cursor()
            cur.execute(sql, params)
            return cur.fetchall()

    def query_one(self, sql, params=()):
        with self._lock:
            cur = self.conn.cursor()
            cur.execute(sql, params)
            return cur.fetchone()

    def execute(self, sql, params=()):
        with self._lock:
            cur = self.conn.cursor()
            cur.execute(sql, params)
            self.conn.commit()
            return cur.rowcount

    def _ensure_table(self):
        self.cursor.execute('''
            CREATE TABLE IF NOT EXISTS alarme (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT
            )
        ''')
        self.conn.commit()

        required_columns = {
            "external_id": "TEXT",
            "keyword": "TEXT",
            "keyword_description": "TEXT",
            "message": "TEXT",
            "building": "TEXT",
            "street": "TEXT",
            "house": "TEXT",
            "postal_code": "TEXT",
            "city": "TEXT",
            "city_abbr": "TEXT",
            "COBRA_LOCATION_property": "TEXT",
            "units": "TEXT",
            "vehicles": "TEXT",
            "alarmed_time": "TEXT",
            "coordinate": "TEXT",
            "custom_comment": "TEXT",
            "custom_diagnosis": "TEXT",
            "custom_alerted": "TEXT",
            "custom_alerted_semicolon": "TEXT",
            "custom_alerted_codes": "TEXT",
            "custom_alerted_rics": "TEXT",
            "custom_alarm_state": "TEXT",
            "update_log": "TEXT",
            "raw_json": "TEXT"
        }

        self.cursor.execute("PRAGMA table_info(alarme)")
        existing_columns = [col[1] for col in self.cursor.fetchall()]

        for column, column_type in required_columns.items():
            if column not in existing_columns:
                self.cursor.execute(f"ALTER TABLE alarme ADD COLUMN {column} {column_type}")
                logger.info(f"[DB] Neue Spalte hinzugefügt: {column} ({column_type})")

        self.conn.commit()

        # Index auf external_id: die Alarmverarbeitung sucht bei JEDEM Alarm per
        # external_id (handle_alarm + log_alarm). Ohne Index = Full-Table-Scan,
        # der mit wachsender Alarmzahl langsamer wird.
        self.cursor.execute("CREATE INDEX IF NOT EXISTS idx_alarme_external_id ON alarme(external_id)")
        self.conn.commit()

    def _ensure_status_table(self):
        self.cursor.execute('''
            CREATE TABLE IF NOT EXISTS fahrzeuglog (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT,
                fahrzeug TEXT,
                status INTEGER
            )
        ''')
        self.conn.commit()
        # Index fuer die Status-Abfragen (ORDER BY timestamp DESC LIMIT 100).
        self.cursor.execute("CREATE INDEX IF NOT EXISTS idx_fahrzeuglog_timestamp ON fahrzeuglog(timestamp)")
        self.conn.commit()
        logger.info("[DB] Tabelle 'fahrzeuglog' geprüft/erstellt.")

    def log_alarm(self, alarm_data):
        self._lock.acquire()
        try:
            external_id = alarm_data.get("externalId")
            self.cursor.execute("SELECT id FROM alarme WHERE external_id = ?", (external_id,))
            existing = self.cursor.fetchone()

            if existing:
                self.cursor.execute('''
                    UPDATE alarme SET
                        timestamp=?, keyword=?, keyword_description=?, message=?,
                        building=?, street=?, house=?, postal_code=?, city=?, city_abbr=?, COBRA_LOCATION_property=?,
                        units=?, vehicles=?, alarmed_time=?, coordinate=?,
                        custom_comment=?, custom_diagnosis=?, custom_alerted=?, custom_alerted_semicolon=?,
                        custom_alerted_codes=?, custom_alerted_rics=?, custom_alarm_state=?,
                        update_log=?, raw_json=?
                    WHERE external_id=?
                ''', (
                    alarm_data.get("timestamp"),
                    alarm_data.get("keyword"),
                    alarm_data.get("keyword_description"),
                    alarm_data.get("message"),
                    alarm_data.get("building"),
                    alarm_data.get("street"),
                    alarm_data.get("house"),
                    alarm_data.get("postalCode"),
                    alarm_data.get("city"),
                    alarm_data.get("city_abbr"),
                    alarm_data.get("COBRA_LOCATION_property"),
                    alarm_data.get("units"),
                    alarm_data.get("vehicles"),
                    alarm_data.get("alarmedTime"),
                    alarm_data.get("coordinate"),
                    alarm_data.get("custom_comment"),
                    alarm_data.get("custom_diagnosis"),
                    alarm_data.get("custom_alerted"),
                    alarm_data.get("custom_alerted_semicolon"),
                    alarm_data.get("custom_alerted_codes"),
                    alarm_data.get("custom_alerted_rics"),
                    alarm_data.get("custom_alarm_state"),
                    alarm_data.get("update_log"),
                    alarm_data.get("raw_json"),
                    external_id
                ))
                logger.info(f"[DB] Alarm aktualisiert: {external_id}")
            else:
                self.cursor.execute('''
                    INSERT INTO alarme (
                        timestamp, external_id, keyword, keyword_description, message,
                        building, street, house, postal_code, city, city_abbr, COBRA_LOCATION_property,
                        units, vehicles, alarmed_time, coordinate,
                        custom_comment, custom_diagnosis, custom_alerted, custom_alerted_semicolon,
                        custom_alerted_codes, custom_alerted_rics, custom_alarm_state,
                        update_log, raw_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ''', (
                    alarm_data.get("timestamp"),
                    external_id,
                    alarm_data.get("keyword"),
                    alarm_data.get("keyword_description"),
                    alarm_data.get("message"),
                    alarm_data.get("building"),
                    alarm_data.get("street"),
                    alarm_data.get("house"),
                    alarm_data.get("postalCode"),
                    alarm_data.get("city"),
                    alarm_data.get("city_abbr"),
                    alarm_data.get("COBRA_LOCATION_property"),
                    alarm_data.get("units"),
                    alarm_data.get("vehicles"),
                    alarm_data.get("alarmedTime"),
                    alarm_data.get("coordinate"),
                    alarm_data.get("custom_comment"),
                    alarm_data.get("custom_diagnosis"),
                    alarm_data.get("custom_alerted"),
                    alarm_data.get("custom_alerted_semicolon"),
                    alarm_data.get("custom_alerted_codes"),
                    alarm_data.get("custom_alerted_rics"),
                    alarm_data.get("custom_alarm_state"),
                    alarm_data.get("update_log"),
                    alarm_data.get("raw_json")
                ))
                logger.info(f"[DB] Neuer Alarm gespeichert: {external_id}")

            self.conn.commit()
        except Exception as e:
            logger.error(f"[DB] Fehler beim Speichern/Aktualisieren des Alarms: {e}")
        finally:
            self._lock.release()

    def log_fahrzeugstatus(self, timestamp, fahrzeug, status):
        self._lock.acquire()
        try:
            self.cursor.execute(
                "INSERT INTO fahrzeuglog (timestamp, fahrzeug, status) VALUES (?, ?, ?)",
                (timestamp, fahrzeug, status)
            )
            self.conn.commit()
            logger.info(f"[DB] Fahrzeugstatus gespeichert: {fahrzeug} -> {status}")
        except Exception as e:
            logger.error(f"[DB] Fehler beim Speichern des Fahrzeugstatus: {e}")
        finally:
            self._lock.release()

    def get_alerted_rics_for_external_id(self, external_id):
        row = self.query_one("SELECT custom_alerted_rics FROM alarme WHERE external_id = ?", (external_id,))
        if row and row["custom_alerted_rics"]:
            return set(ric.strip() for ric in row["custom_alerted_rics"].split(";") if ric.strip())
        return set()
