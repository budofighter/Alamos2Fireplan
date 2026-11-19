import os
import sys

# Immer im Programmordner arbeiten: config/.env, alarme.db und logs/ werden
# relativ aufgeloest. So bleibt das Verhalten korrekt, auch wenn der Dienst mit
# einem abweichenden Arbeitsverzeichnis gestartet wird.
APP_DIR = os.path.dirname(os.path.abspath(__file__))
os.chdir(APP_DIR)
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from backend import log_helper  # wichtig: löst Initialisierung aus
logger = log_helper.logger


def _log_uncaught(exc_type, exc, tb):
    # Unerwartete Abstuerze landen sonst nur in service.log - hier auch in app.log.
    logger.critical("Unbehandelter Fehler - Dienst wird beendet.", exc_info=(exc_type, exc, tb))
    sys.__excepthook__(exc_type, exc, tb)


sys.excepthook = _log_uncaught

from backend.version import APP_VERSION  # noqa: E402
logger.info(f"Starte Alamos2Fireplan v{APP_VERSION} (Python {sys.version.split()[0]}) in {APP_DIR}")

from app.app import app  # noqa: E402

if __name__ == "__main__":
    # Produktionstauglicher WSGI-Server (multi-threaded, stabil im Dauerbetrieb)
    # statt des Flask-Entwicklungsservers. Die DB-Zugriffe sind thread-sicher.
    from waitress import serve
    port = int(os.getenv("WEB_PORT") or 5000)
    logger.info(f"Starte Server (waitress) auf http://0.0.0.0:{port} ...")
    serve(app, host="0.0.0.0", port=port, threads=8)
