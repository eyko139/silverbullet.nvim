import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote


FILES = {}


def etag(content):
    return '"' + hashlib.sha256(content).hexdigest() + '"'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def authorized(self):
        return self.headers.get("Authorization") == "Bearer test-token"

    def send_body(self, status, body=b"", content_type="text/plain", headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def path_name(self):
        return unquote(self.path.removeprefix("/.fs/"))

    def do_GET(self):
        if not self.authorized():
            self.send_body(401)
            return
        if self.path == "/.ping":
            self.send_body(200, b"OK")
            return
        if self.path == "/.config":
            self.send_body(200, b"{}", "application/json")
            return
        if self.path == "/.fs":
            body = json.dumps(
                [
                    {
                        "name": name,
                        "contentType": "text/markdown",
                        "size": len(content),
                        "perm": "rw",
                    }
                    for name, content in sorted(FILES.items())
                ]
            ).encode()
            self.send_body(200, body, "application/json")
            return
        name = self.path_name()
        if name not in FILES:
            self.send_body(404)
            return
        content = FILES[name]
        self.send_body(
            200,
            content,
            "text/markdown",
            {"ETag": etag(content), "X-Permission": "rw"},
        )

    def do_PUT(self):
        if not self.authorized():
            self.send_body(401)
            return
        name = self.path_name()
        current = FILES.get(name)
        if self.headers.get("If-None-Match") == "*" and current is not None:
            self.send_body(412)
            return
        if_match = self.headers.get("If-Match")
        if if_match and (current is None or if_match != etag(current)):
            self.send_body(412)
            return
        content = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        FILES[name] = content
        self.send_body(200, headers={"ETag": etag(content), "X-Permission": "rw"})

    def do_DELETE(self):
        if not self.authorized():
            self.send_body(401)
            return
        name = self.path_name()
        if name not in FILES:
            self.send_body(404)
            return
        del FILES[name]
        self.send_body(204)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
