// Automatisch alle 30 Sekunden die Seite neu laden
setInterval(function() {
    if (window.location.pathname === "/status" || window.location.pathname === "/alarms") {
        window.location.reload();
    }
}, 30000);
