from app.app import app

from backend import log_helper  # wichtig: löst Initialisierung aus
logger = log_helper.logger
logger.info("Starte runserver.py ...")

if __name__ == "__main__":
    # Produktionstauglicher WSGI-Server (multi-threaded, stabil im Dauerbetrieb)
    # statt des Flask-Entwicklungsservers. Die DB-Zugriffe sind thread-sicher.
    from waitress import serve
    logger.info("Starte Server (waitress) auf http://0.0.0.0:5000 ...")
    serve(app, host="0.0.0.0", port=5000, threads=8)
