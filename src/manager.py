#!/usr/bin/env python3
"""AutoDarts Proxmox Manager — minimale lokale Web-UI (nur stdlib, keine Deps).

Port: 8080, bind 0.0.0.0
Routen:
  /            Dashboard (Links zu Board-Manager :3180, Caller-Link :8079)
  /health      Liveness-Probe (200 OK)
  /api/status  JSON-Status (services, darts-hub, video-devices, net)
"""
import json
import os
import socket
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MANAGER_PORT = int(os.environ.get("MANAGER_PORT", "8080"))
BOARD_PORT = int(os.environ.get("BOARD_PORT", "3180"))
CALLER_PORT = int(os.environ.get("CALLER_PORT", "8079"))
DARTS_HUB_DIR = os.environ.get("DARTS_HUB_DIR", "/opt/darts-hub")
CALLER_DIR = os.environ.get("CALLER_DIR", "/opt/darts-caller")
BOARD_ID_FILE = os.environ.get("BOARD_ID_FILE", "/etc/autodarts/board-id")
MANAGER_VERSION = os.environ.get("MANAGER_VERSION", "1.1.0")


def run(cmd, timeout=5):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()[:4000]
    except Exception as e:  # komplette Kette ausgeben, nicht nur letzte Zeile
        return 127, f"{type(e).__name__}: {e}"


def service_state(name):
    code, out = run(["systemctl", "is-active", name])
    return out.splitlines()[0] if out else ("active" if code == 0 else "unknown")


def list_video_devices():
    devs = []
    try:
        for entry in sorted(os.listdir("/dev")):
            if entry.startswith("video"):
                devs.append(f"/dev/{entry}")
    except Exception as e:
        devs.append(f"error: {e}")
    return devs


def usb_list():
    code, out = run(["lsusb"])
    if code == 127:
        return "lsusb nicht installiert (usbutils)"
    return out or "(keine USB-Geraete sichtbar)"


def container_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        pass
    code, out = run(["hostname", "-I"])
    return out.split()[0] if out else "localhost"


def status_payload():
    hub_bin = os.path.join(DARTS_HUB_DIR, "darts-hub")
    caller_bin = os.path.join(CALLER_DIR, "darts-caller")
    board_id = ""
    try:
        with open(BOARD_ID_FILE, encoding="utf-8") as f:
            board_id = f.read().strip()
    except Exception:
        board_id = ""
    masked = ("…" + board_id[-4:]) if len(board_id) > 4 else ("gesetzt" if board_id else "")
    return {
        "manager": {"version": MANAGER_VERSION, "port": MANAGER_PORT},
        "container_ip": container_ip(),
        "board": {"configured": bool(board_id), "masked": masked, "file": BOARD_ID_FILE},
        "services": {
            "autodarts-manager": service_state("autodarts-manager"),
            "darts-caller": service_state("darts-caller"),
            "darts-hub": service_state("darts-hub"),
        },
        "darts_hub": {
            "dir": DARTS_HUB_DIR,
            "binary_present": os.path.isfile(hub_bin),
            "binary_executable": os.access(hub_bin, os.X_OK),
        },
        "darts_caller": {
            "dir": CALLER_DIR,
            "binary_present": os.path.isfile(caller_bin),
            "binary_executable": os.access(caller_bin, os.X_OK),
        },
        "video_devices": list_video_devices(),
        "usb": usb_list(),
        "links": {
            "board_manager": f"http://{container_ip()}:{BOARD_PORT}",
            "caller_link": f"https://{container_ip()}:{CALLER_PORT}",
        },
    }


DASHBOARD = """<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AutoDarts Proxmox Manager</title>
<style>body{font-family:system-ui,sans-serif;max-width:860px;margin:2rem auto;padding:0 1rem;background:#0f1115;color:#e8e8e8}
.card{background:#1a1e26;border:1px solid #2c3340;border-radius:12px;padding:1rem 1.2rem;margin:1rem 0}
a{color:#7cc4ff}code{background:#0a0c10;padding:.15rem .4rem;border-radius:6px}
.btn{display:inline-block;background:#2f81f7;color:#fff;padding:.5rem 1rem;border-radius:8px;text-decoration:none;margin:.25rem .5rem .25rem 0}
.small{opacity:.75;font-size:.9em}</style></head><body>
<h1>&#127919; AutoDarts Proxmox Manager</h1>
<p class="small">Laeuft lokal im LXC-Container. Version: __VERSION__ | IP: __IP__</p>
<div class="card"><h2>Direkt-Links</h2>
<p><a class="btn" href="__BOARD_URL__">Board-Manager (:3180)</a>
<a class="btn" href="__CALLER_URL__">Caller Login (:8079, https)</a>
<a class="btn" href="/api/status">JSON-Status</a>
<a class="btn" href="/health">Health</a></p>
<p class="small">__BOARD_HINT__</p></div>
<div class="card"><h2>Naechste Schritte (reduziert)</h2><ol>
<li>Caller-URL oeffnen (<code>https://&lt;CT-IP&gt;:8079</code>, Zertifikatswarnung bestaetigen) und Device-Link Login via <code>auth.autodarts.io/link</code> freigeben.</li>
<li>Im Board-Manager Kameras waehlen, kalibrieren, Testspiel starten.</li>
<li>USB-Kameras am Proxmox-Host per Passthrough in diesen Container reichen (siehe README) — ohne <code>/dev/video*</code> kein Scoring.</li>
</ol>
<p class="small">Board-ID wurde bei der Installation abgefragt und liegt in <code>/etc/autodarts/board-id</code>. Nachtragen: <code>echo DEINE_ID &gt; /etc/autodarts/board-id</code> + Setup-Re-Run.</p></div>
<div class="card"><h2>Live-Status</h2><pre id="st">lade …</pre></div>
<script>fetch('/api/status').then(r=>r.text()).then(t=>document.getElementById('st').textContent=t).catch(e=>document.getElementById('st').textContent='Fehler: '+e)</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "AutoDartsManager/1.0"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        try:
            if path == "/health":
                self._send(200, "OK", "text/plain")
            elif path == "/api/status":
                self._send(200, json.dumps(status_payload(), indent=2, ensure_ascii=False), "application/json; charset=utf-8")
            elif path in ("/", "/index.html"):
                ip = container_ip()
                st = status_payload()
                if st["board"]["configured"]:
                    hint = f"Board {st['board']['masked']} konfiguriert — nur noch Caller-Login + Kameras."
                else:
                    hint = "Keine Board-ID hinterlegt — nachtragen (siehe unten), sonst bleibt Caller gestoppt."
                html = (DASHBOARD.replace("__VERSION__", MANAGER_VERSION)
                        .replace("__IP__", ip)
                        .replace("__BOARD_URL__", f"http://{ip}:{BOARD_PORT}")
                        .replace("__CALLER_URL__", f"https://{ip}:{CALLER_PORT}")
                        .replace("__BOARD_HINT__", hint))
                self._send(200, html)
            else:
                self._send(404, "Not found", "text/plain")
        except Exception as e:
            import traceback
            self._send(500, f"Internal error:\n{type(e).__name__}: {e}\n{traceback.format_exc()}", "text/plain")


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", MANAGER_PORT), Handler)
    print(f"[manager] listening on 0.0.0.0:{MANAGER_PORT} (board :{BOARD_PORT}, caller :{CALLER_PORT})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
