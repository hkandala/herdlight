"""Runs herdr API requests for the sandboxed UI tests, which cannot reach herdr's sockets.

Usage: python3 scripts/e2e-helper.py <session>...  (prints its port, then serves on 127.0.0.1)
POST /<session> with one API request line as the body; the reply line comes back.
Any session not named on the command line is refused.
"""

import http.server
import socketserver
import subprocess
import sys

sessions = set(sys.argv[1:])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        session = self.path.strip("/")
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if session not in sessions:
            status, reply = 403, f"refusing session '{session}'".encode()
        else:
            run = subprocess.run(["herdr", "--session", session, "remote-api-bridge"],
                                 input=body, capture_output=True, timeout=10)
            status, reply = (200, run.stdout) if run.returncode == 0 else (500, run.stderr)
        self.send_response(status)
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


# Not HTTPServer: its getfqdn() lookup raised the Local Network prompt on CI.
server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
