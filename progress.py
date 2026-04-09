#!/usr/bin/env python3
"""ikuku install progress server — serves status page and polls podman logs."""
import http.server
import json
import subprocess
import threading
import time
import os
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
HTML_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "progress.html")
FRAPPE_URL = "http://localhost:8000"
CONTAINER = "ikuku_frappe_1"

status = {"phase": "starting", "lines": [], "ready": False, "error": None}

def poll_logs():
    """Background thread: tail podman logs and check if frappe is ready."""
    global status
    while not status["ready"]:
        try:
            r = subprocess.run(
                ["podman", "logs", CONTAINER],
                capture_output=True, text=True, timeout=5
            )
            lines = (r.stdout + r.stderr).strip().split("\n")[-30:]
            status["lines"] = lines

            full = r.stdout + r.stderr
            if "Booting worker" in full or "Running on" in full:
                status["phase"] = "ready"
                status["ready"] = True
            elif "error" in full.lower() and "warning" not in full.lower():
                last_err = [l for l in lines if "error" in l.lower() and "warning" not in l.lower()]
                if last_err:
                    status["error"] = last_err[-1]
                    status["phase"] = "error"
            elif "Installing" in full or "install" in full.lower():
                status["phase"] = "installing_apps"
            elif "Building" in full or "yarn" in full:
                status["phase"] = "building_assets"
            elif "Creating" in full or "migrate" in full.lower():
                status["phase"] = "creating_site"
            else:
                status["phase"] = "starting"
        except Exception as e:
            status["error"] = str(e)
        time.sleep(3)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps(status).encode())
        elif self.path == "/" or self.path == "/progress.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            with open(HTML_PATH, "rb") as f:
                self.wfile.write(f.read())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass  # quiet

if __name__ == "__main__":
    threading.Thread(target=poll_logs, daemon=True).start()
    print(f"Progress server on http://localhost:{PORT}")
    http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
