"""Isolated HTTP fixture for ERC media tests; prints its loopback port."""
import http.server
import ssl
import struct
import sys
import time
import zlib


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


PNG = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", 320, 180, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress((b"\0" + b"\x40\x80\xff" * 320) * 180))
       + chunk(b"IEND", b""))
FILE = b"binary\0file\xff\n"


class Handler(http.server.BaseHTTPRequestHandler):
    leaks = 0

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/leak")
            self.end_headers()
            return
        if self.path == "/leak":
            Handler.leaks += 1
        if self.path == "/file":
            if (self.headers.get("Authorization") != "Bearer media-secret"
                    or self.headers.get("X-Bridge") != "onebot"):
                self.send_error(403)
                return
        if self.path == "/error":
            self.send_error(500)
            return
        if self.path == "/slow":
            time.sleep(2)
        body = (PNG if self.path == "/image.png" else
                str(Handler.leaks).encode() if self.path == "/leak-count" else FILE)
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
if len(sys.argv) == 3:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_port, flush=True)
server.serve_forever()
