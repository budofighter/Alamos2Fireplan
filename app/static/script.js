// Werte aus MQTT-Nachrichten/Logs stammen von aussen -> vor dem Einfuegen in
// innerHTML immer escapen (sonst HTML/Script-Injection ueber Alarmtexte).
function escapeHtml(value) {
    if (value === null || value === undefined) return "";
    return String(value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

async function updateAlarms() {
    // Seite erkennt sich an der Tabelle (die Alarmliste liegt unter "/").
    const tbody = document.getElementById("alarm-table");
    if (!tbody) return;

    try {
        const response = await fetch("/api/alarms");
        const data = await response.json();

        if (data.alarms.length === 0) {
            tbody.innerHTML = `<tr><td colspan="6" class="text-center">Keine Alarme vorhanden.</td></tr>`;
            return;
        }

        tbody.innerHTML = data.alarms.map(alarm => `
            <tr>
                <td>${escapeHtml(formatDate(alarm.timestamp))}</td>
                <td>${escapeHtml(alarm.keyword)}</td>
                <td>${escapeHtml(alarm.city)}</td>
                <td>${escapeHtml(alarm.street)}</td>
                <td>${escapeHtml(alarm.house)}</td>
                <td>
                    <a href="/alarm/${encodeURIComponent(alarm.id)}" class="btn btn-sm btn-primary">Details</a>
                </td>
            </tr>
        `).join("");

    } catch (err) {
        console.error("Fehler beim Laden der Alarme:", err);
    }
}


function formatDate(isoString) {
    const dt = new Date(isoString);
    if (isNaN(dt.getTime())) return isoString || "";
    return dt.toLocaleString("de-DE", {
        day: "2-digit",
        month: "2-digit",
        year: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit"
    });
}


async function updateMqttButton() {
    try {
        const response = await fetch("/api/mqtt_status");
        const data = await response.json();
        const running = data.running;

        const form = document.getElementById("mqtt-control");
        if (!form) return; // Falls auf dieser Seite kein Button vorhanden ist

        form.setAttribute("action", running ? "/mqtt/stop" : "/mqtt/start");
        form.setAttribute("method", "post");
        form.innerHTML = `
            <button type="submit" class="btn ${running ? "btn-success" : "btn-danger"}">
                ${running ? "MQTT läuft" : "MQTT starten"}
            </button>
        `;
    } catch (err) {
        console.error("Fehler beim Abrufen des MQTT-Status:", err);
    }
}

async function updateStatus() {
    const tbody = document.getElementById("status-table");
    if (!tbody) return;

    try {
        const response = await fetch("/api/status");
        const data = await response.json();

        if (data.statuses.length === 0) {
            tbody.innerHTML = `<tr><td colspan="3" class="text-center">Keine Einträge vorhanden.</td></tr>`;
            return;
        }

        tbody.innerHTML = data.statuses.map(row => {
            const statusValue = parseInt(row.status);
            let badgeClass = "bg-light text-dark";
            let badgeText = statusValue;

            switch (statusValue) {
                case 1:
                    badgeClass = "bg-success bg-opacity-50";
                    break;
                case 2:
                    badgeClass = "bg-success";
                    break;
                case 3:
                    badgeClass = "bg-warning text-dark";
                    break;
                case 4:
                    badgeClass = "bg-danger";
                    break;
                case 5:
                    badgeClass = "bg-secondary";
                    break;
                case 6:
                    badgeClass = "bg-dark";
                    break;
                default:
                    badgeClass = "bg-light text-dark";
            }

            return `
                <tr>
                    <td>${escapeHtml(formatDate(row.timestamp))}</td>
                    <td>${escapeHtml(row.fahrzeug)}</td>
                    <td><span class="badge ${badgeClass}">${escapeHtml(badgeText)}</span></td>
                </tr>
            `;
        }).join("");

    } catch (err) {
        console.error("Fehler beim Laden des Fahrzeugstatus:", err);
    }
}



async function loadLogs() {
    const container = document.getElementById("log-container");
    if (!container) return;

    try {
        const response = await fetch("/api/logs");
        const data = await response.text();

        const lines = data.split("\n").filter(line => line.trim() !== "");

        container.innerHTML = lines.map(line => {
            let cssClass = "";
            if (line.includes("ERROR")) cssClass = "log-error";
            else if (line.includes("WARNING")) cssClass = "log-warning";
            else if (line.includes("DEBUG")) cssClass = "log-debug";
            else if (line.includes("INFO")) cssClass = "log-info";
            else if (line.includes("CRITICAL")) cssClass = "log-critical";

            return `<div class="${cssClass}">${escapeHtml(line)}</div>`;
        }).join("");
        container.scrollTop = 0; // neueste Einträge oben sichtbar

    } catch (err) {
        console.error("Fehler beim Laden der Logs:", err);
    }
}

  

document.addEventListener("DOMContentLoaded", () => {
    updateMqttButton();
    setInterval(updateMqttButton, 5000);

    updateAlarms();
    setInterval(updateAlarms, 5000); 

    updateStatus();
    setInterval(updateStatus, 5000); 

    loadLogs();
    setInterval(loadLogs, 5000);
});

