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
CONTAINER = "ikuku_frappe_1"

status = {"phase": "starting", "lines": [], "ready": False, "error": None}

def poll_logs():
    global status
    start_time = time.time()
    while not status["ready"]:
        try:
            r = subprocess.run(["podman", "logs", "--tail", "30", CONTAINER], capture_output=True, text=True, timeout=15)
            full = r.stdout + r.stderr
            lines = full.strip().split("\n")[-30:]
            status["lines"] = lines
            if time.time() - start_time > 30:
                try:
                    import urllib.request
                    urllib.request.urlopen("http://localhost:8000", timeout=3)
                    status["phase"] = "ready"
                    status["ready"] = True
                except Exception:
                    pass
            if not status["ready"]:
                if any(k in full for k in ["bench get-app", "Getting", "Cloning"]):
                    status["phase"] = "installing_apps"
                elif any(k in full for k in ["yarn", "Building", "DONE  Total Build"]):
                    status["phase"] = "building_assets"
                elif any(k in full for k in ["new-site", "migrate", "install-app", "Installing app"]):
                    status["phase"] = "creating_site"
                elif "bench init" in full or "Creating new bench" in full:
                    status["phase"] = "initializing"
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
        pass

if __name__ == "__main__":
    threading.Thread(target=poll_logs, daemon=True).start()
    print(f"Progress server on http://localhost:{PORT}")
    http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
