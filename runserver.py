from app.app import app

from backend import log_helper  # wichtig: löst Initialisierung aus
logger = log_helper.logger
logger.info("Starte runserver.py ...")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
