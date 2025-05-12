import logging
import os
import sys
from logging.handlers import RotatingFileHandler
from dotenv import load_dotenv

def get_log_dir():
    if getattr(sys, 'frozen', False):  # PyInstaller?
        return os.path.dirname(sys.executable)
    return os.path.abspath(".")

LOG_DIR = os.path.join(get_log_dir(), "logs")
os.makedirs(LOG_DIR, exist_ok=True)

LOG_PATH = os.path.join(LOG_DIR, "app.log")

logger = logging.getLogger("Alamos2Fireplan")
logger.setLevel(logging.INFO)

if not logger.handlers:
    file_handler = RotatingFileHandler(
        LOG_PATH,
        maxBytes=10_000_000,
        backupCount=3,
        encoding="utf-8"
    )
    formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

load_dotenv(dotenv_path=os.path.join("config", ".env"))
log_level = os.getenv("LOG_LEVEL", "INFO").upper()
logger.setLevel(getattr(logging, log_level, logging.INFO))