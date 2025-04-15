import sqlite3
import json
from log_helper import logger

class DBHandler:
    def __init__(self, db_file='alarme.db'):
        self.conn = sqlite3.connect(db_file, check_same_thread=False)
        self.cursor = self.conn.cursor()
        self._ensure_table()
        self._ensure_status_table()
        logger.info("SQLite-Verbindung hergestellt und Tabellen vorbereitet.")

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
            "units": "TEXT",
            "vehicles": "TEXT",
            "alarmed_time": "TEXT",
            "raw_json": "TEXT"
        }

        self.cursor.execute("PRAGMA table_info(alarme)")
        existing_columns = [col[1] for col in self.cursor.fetchall()]

        for column, column_type in required_columns.items():
            if column not in existing_columns:
                self.cursor.execute(f"ALTER TABLE alarme ADD COLUMN {column} {column_type}")
                logger.info(f"[DB] Neue Spalte hinzugefügt: {column} ({column_type})")

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
        logger.info("[DB] Tabelle 'fahrzeuglog' geprüft/erstellt.")

    def log_alarm(self, alarm_data):
        try:
            self.cursor.execute('''
                INSERT INTO alarme (
                    timestamp, external_id, keyword, keyword_description, message,
                    building, street, house, postal_code, city,
                    units, vehicles, alarmed_time, raw_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                alarm_data.get("timestamp"),
                alarm_data.get("externalId"),
                alarm_data.get("keyword"),
                alarm_data.get("keyword_description"),
                alarm_data.get("message"),
                alarm_data.get("building"),
                alarm_data.get("street"),
                alarm_data.get("house"),
                alarm_data.get("postalCode"),
                alarm_data.get("city"),
                alarm_data.get("units"),
                alarm_data.get("vehicles"),
                alarm_data.get("alarmedTime"),
                json.dumps(alarm_data, ensure_ascii=False)
            ))
            self.conn.commit()
            logger.info(f"[DB] Alarm gespeichert: {alarm_data.get('externalId')}")
        except Exception as e:
            logger.error(f"[DB] Fehler beim Speichern des Alarms: {e}")

    def log_fahrzeugstatus(self, timestamp, fahrzeug, status):
        try:
            self.cursor.execute(
                "INSERT INTO fahrzeuglog (timestamp, fahrzeug, status) VALUES (?, ?, ?)",
                (timestamp, fahrzeug, status)
            )
            self.conn.commit()
            logger.info(f"[DB] Fahrzeugstatus gespeichert: {fahrzeug} → {status}")
        except Exception as e:
            logger.error(f"[DB] Fehler beim Speichern des Fahrzeugstatus: {e}")
