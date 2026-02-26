#!/bin/bash
# Setup script for git-hunk demo recording
# Creates a demo repo with 3 well-separated hunks
set -e

rm -rf /tmp/hunk-demo
mkdir -p /tmp/hunk-demo
cd /tmp/hunk-demo
git init -q

# Initial committed file
cat > app.py << 'PYEOF'
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

HOST = "localhost"
PORT = 8080
DEBUG = True


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        data = json.loads(body)
        result = process(data)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(result).encode())

    def log_message(self, format, *args):
        if DEBUG:
            super().log_message(format, *args)


def process(data):
    raw = data.get("input", 0)
    return {"value": raw * 2}


def health_check():
    """Return server health status."""
    return {
        "status": "healthy",
        "version": "1.0.0",
    }


def run():
    server = HTTPServer((HOST, PORT), Handler)
    print(f"Serving on {HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    run()
PYEOF

git add . && git commit -qm "initial"

# Modified file: 3 separated edits
# 1. Add import logging + flip DEBUG (top)
# 2. Add input validation in do_POST (middle)
# 3. Add logging.basicConfig in run() (bottom)
cat > app.py << 'PYEOF'
import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

HOST = "localhost"
PORT = 8080
DEBUG = False


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        data = json.loads(body)
        if "input" not in data:
            self.send_response(400)
            self.end_headers()
            return
        result = process(data)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(result).encode())

    def log_message(self, format, *args):
        if DEBUG:
            super().log_message(format, *args)


def process(data):
    raw = data.get("input", 0)
    return {"value": raw * 2}


def health_check():
    """Return server health status."""
    return {
        "status": "healthy",
        "version": "1.0.0",
    }


def run():
    logging.basicConfig(level=logging.INFO)
    server = HTTPServer((HOST, PORT), Handler)
    print(f"Serving on {HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    run()
PYEOF
