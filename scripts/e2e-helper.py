"""Runs herdr API requests for the sandboxed UI tests, which cannot reach herdr's sockets.

Usage: python3 scripts/e2e-helper.py <session>... -- <test command>...
Serves on 127.0.0.1 while the test command runs, then exits with its status.
POST /<session> with one API request line as the body; the reply line comes back.
POST /<session>/control with a terminal id as the body opens `terminal session control` on it
without takeover, releases it at once, and gives back what the stream printed (a frame, or the
reason it was refused).
Any session not named on the command line is refused.
"""

import http.server
import os
import re
import socketserver
import subprocess
import sys
import threading

split = sys.argv.index("--")
sessions, command = sys.argv[1:split], sys.argv[split + 1:]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        session, _, action = self.path.strip("/").partition("/")
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if session not in sessions:
            status, reply = 403, f"refusing session '{session}'".encode()
        elif action not in ("", "control"):
            status, reply = 404, f"no action '{action}'".encode()
        elif action == "control" and not re.fullmatch(rb"\w[\w-]*", body):
            status, reply = 400, b"the body must be a terminal id"
        else:
            if action == "control":
                argv = ["terminal", "session", "control", body.decode(), "--cols", "80", "--rows", "24"]
                body = b'{"type":"terminal.release"}\n'
            else:
                argv = ["remote-api-bridge"]
            try:
                run = subprocess.run(["herdr", "--session", session, *argv],
                                     input=body, capture_output=True, timeout=10)
                status, reply = (200, run.stdout) if run.returncode == 0 else (500, run.stderr)
            except Exception as error:  # a timeout or no herdr: tell the test, keep serving
                status, reply = 500, str(error).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


# Not HTTPServer: its getfqdn() lookup raised the Local Network prompt on CI.
server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
# xcodebuild passes TEST_RUNNER_* to the tests without the prefix.
env = {**os.environ, "TEST_RUNNER_HL_HELPER": f"http://127.0.0.1:{server.server_address[1]}",
       **{f"TEST_RUNNER_HL_SESSION{n if n > 1 else ''}": name for n, name in enumerate(sessions, 1)}}
sys.exit(subprocess.run(command, env=env).returncode)
