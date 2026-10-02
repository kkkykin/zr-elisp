"""Loopback-only HTTP proxy fixture; prints its port and request targets."""
import http.client
import http.server
import select
import socket
import urllib.parse


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        target = urllib.parse.urlsplit(self.path)
        if target.scheme != "http" or target.hostname != "127.0.0.1":
            self.send_error(403)
            return
        print("GET " + self.path, flush=True)
        if target.path == "/drop":
            return  # A failed proxy request must never fall back to direct.
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in ("connection", "proxy-authorization")}
        headers["Connection"] = "close"
        connection = http.client.HTTPConnection(target.hostname, target.port, timeout=5)
        try:
            path = urllib.parse.urlunsplit(("", "", target.path, target.query, ""))
            connection.request("GET", path, headers=headers)
            response = connection.getresponse()
            body = response.read()
            self.send_response(response.status)
            self.send_header("Content-Length", str(len(body)))
            if location := response.getheader("Location"):
                self.send_header("Location", location)
            self.end_headers()
            self.wfile.write(body)
        finally:
            connection.close()

    def do_CONNECT(self):
        host, port = self.path.rsplit(":", 1)
        if host != "127.0.0.1":
            self.send_error(403)
            return
        print("CONNECT " + self.path, flush=True)
        with socket.create_connection((host, int(port)), timeout=5) as upstream:
            self.send_response(200, "Connection established")
            self.end_headers()
            self.wfile.flush()
            sockets = (self.connection, upstream)
            while readable := select.select(sockets, [], [], 5)[0]:
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    destination = upstream if source is self.connection else self.connection
                    destination.sendall(data)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
