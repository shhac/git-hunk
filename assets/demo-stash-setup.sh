#!/bin/bash
# Setup script for stash demo
set -e

rm -rf /tmp/hunk-demo-stash
mkdir -p /tmp/hunk-demo-stash
cd /tmp/hunk-demo-stash
git init -q

# Initial committed file
cat > server.py << 'PYEOF'
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"hello")

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

def run():
    server = HTTPServer(("localhost", 8080), Handler)
    server.serve_forever()

if __name__ == "__main__":
    run()
PYEOF

git add . && git commit -qm "initial"

# Two edits: one ready to commit, one experimental
cat > server.py << 'PYEOF'
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"hello")

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        if not body:
            self.send_response(400)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

def run():
    logging.basicConfig(level=logging.INFO)
    server = HTTPServer(("localhost", 8080), Handler)
    server.serve_forever()

if __name__ == "__main__":
    run()
PYEOF
