"""Local HTTP fixture for the shared curl transport (standard library only)."""

import base64
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        path = self.path.split("?", 1)[0]
        status = 200
        headers = []
        if path == "/slow":
            time.sleep(0.4)
        if path == "/inspect":
            data = json.dumps(
                {"method": self.command, "path": self.path,
                 "headers": dict(self.headers),
                 "body": base64.b64encode(body).decode("ascii")}
            ).encode()
        elif path == "/echo":
            data = body
        elif path == "/redirect":
            status, data = 302, b"redirect body"
            headers.append(("Location", "/bytes"))
        elif path == "/error":
            status, data = 404, b'{"error":"missing"}'
        else:
            data = bytes(range(256))
        try:
            if path == "/headers":
                self.wfile.write(b"HTTP/1.1 103 Early Hints\r\nLink: </early>\r\n\r\n")
                headers.extend([("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")])
            self.send_response(status)
            self.send_header("Connection", "close")
            for name, value in headers:
                self.send_header(name, value)
            if path == "/chunked":
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for chunk in (data[:100], data[100:]):
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            else:
                self.send_header("Content-Length", str(len(data) + (100 if path == "/partial" else 0)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = handle_request
    do_PROPFIND = do_COPY = do_MOVE = handle_request


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(f"PORT {server.server_port}", flush=True)
    server.serve_forever()
