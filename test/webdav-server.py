"""In-memory WebDAV fixture for ERT; Python standard library only."""

import base64
import email.utils
import hashlib
import http.server
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET


DAV = "{DAV:}"
ET.register_namespace("D", "DAV:")
LOCK = threading.RLock()
FILES = {}
REVISION = 0


def put(path, data):
    global REVISION
    REVISION += 1
    FILES[path] = {"data": data, "revision": REVISION}


def etag(entry):
    return '"%s"' % hashlib.sha256(
        (entry["data"] or b"") + str(entry["revision"]).encode()
    ).hexdigest()


def modified(entry):
    return email.utils.formatdate(1788912000 + entry["revision"], usegmt=True)


for initial in ("/", "/dav", "/auth"):
    put(initial, None)
put("/auth/secret.txt", b"authenticated")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply(self, status, body=b"", headers=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
        self.close_connection = True

    def resource_headers(self, entry):
        return {"ETag": etag(entry), "Last-Modified": modified(entry)}

    def prepare(self):
        self.body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        raw_path = urllib.parse.urlsplit(self.path).path
        self.resource = urllib.parse.unquote(raw_path).rstrip("/") or "/"
        path = self.resource
        if path.startswith("/auth"):
            expected = "Basic " + base64.b64encode(b"alice:app-password").decode()
            if self.headers.get("Authorization") != expected:
                self.reply(401, headers={"WWW-Authenticate": 'Basic realm="fixture"'})
                return False
        if path == "/__test__/forbidden":
            self.reply(403)
            return False
        if path == "/__test__/broken-xml":
            self.reply(207, b"<broken")
            return False
        if path == "/__test__/missing-multistatus":
            self.reply(207, b'<multistatus xmlns="DAV:"><response>'
                       b'<href>/__test__/missing-multistatus</href>'
                       b'<status>HTTP/1.1 404 Not Found</status></response></multistatus>')
            return False
        if path == "/__test__/cross-origin":
            self.reply(307, headers={
                "Location": "http://localhost:%d/auth/secret.txt" % self.server.server_port
            })
            return False
        if path == "/__test__/loop":
            self.reply(301, headers={"Location": self.path})
            return False
        if path == "/__test__/slow":
            time.sleep(0.6)
            self.reply(200, b"late")
            return False
        if path == "/__test__/truncated":
            self.send_response(200)
            self.send_header("Content-Length", "1000")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"partial")
            self.close_connection = True
            return False
        if path.endswith("/redirect-source"):
            self.reply(302, headers={"Location": "redirect-target"})
            return False
        entry = FILES.get(path)
        if (entry and entry["data"] is None and not raw_path.endswith("/")
                and self.command in ("PROPFIND", "GET")):
            self.reply(301, headers={"Location": raw_path + "/"})
            return False
        return True

    def do_PROPFIND(self):
        with LOCK:
            if not self.prepare():
                return
            path = self.resource
            if path not in FILES:
                self.reply(404)
                return
            entry = FILES[path]
            paths = [path]
            if self.headers.get("Depth") == "1" and entry["data"] is None:
                prefix = path.rstrip("/") + "/"
                paths += [p for p in FILES if p.startswith(prefix)
                          and p != path and "/" not in p[len(prefix):]]
            root = ET.Element(DAV + "multistatus")
            for item in paths:
                info = FILES[item]
                response = ET.SubElement(root, DAV + "response")
                href = urllib.parse.quote(item, safe="/")
                if info["data"] is None and not href.endswith("/"):
                    href += "/"
                ET.SubElement(response, DAV + "href").text = href
                propstat = ET.SubElement(response, DAV + "propstat")
                prop = ET.SubElement(propstat, DAV + "prop")
                resource_type = ET.SubElement(prop, DAV + "resourcetype")
                if info["data"] is None:
                    ET.SubElement(resource_type, DAV + "collection")
                ET.SubElement(prop, DAV + "getcontentlength").text = str(len(info["data"] or b""))
                ET.SubElement(prop, DAV + "getlastmodified").text = modified(info)
                ET.SubElement(prop, DAV + "getetag").text = etag(info)
                ET.SubElement(propstat, DAV + "status").text = "HTTP/1.1 200 OK"
                missing = ET.SubElement(response, DAV + "propstat")
                ET.SubElement(ET.SubElement(missing, DAV + "prop"), DAV + "creationdate")
                ET.SubElement(missing, DAV + "status").text = "HTTP/1.1 404 Not Found"
            self.reply(207, ET.tostring(root, encoding="utf-8", xml_declaration=True),
                       {"Content-Type": "application/xml; charset=utf-8"})

    def do_GET(self):
        with LOCK:
            if not self.prepare():
                return
            entry = FILES.get(self.resource)
            if not entry:
                self.reply(404)
            elif entry["data"] is None:
                self.reply(405)
            else:
                self.reply(200, entry["data"], self.resource_headers(entry))

    do_HEAD = do_GET

    def parent_exists(self, path):
        parent = path.rsplit("/", 1)[0] or "/"
        return parent in FILES and FILES[parent]["data"] is None

    def do_PUT(self):
        with LOCK:
            if not self.prepare():
                return
            path = self.resource
            old = FILES.get(path)
            if ((self.headers.get("If-None-Match") == "*" and old)
                    or (self.headers.get("If-Match") is not None
                        and (not old or self.headers["If-Match"] != etag(old)))
                    or (self.headers.get("If-Unmodified-Since") and old
                        and self.headers["If-Unmodified-Since"] != modified(old))):
                self.reply(412)
            elif not self.parent_exists(path):
                self.reply(409)
            elif old and old["data"] is None:
                self.reply(405)
            else:
                put(path, self.body)
                self.reply(204 if old else 201, headers=self.resource_headers(FILES[path]))

    def do_MKCOL(self):
        with LOCK:
            if not self.prepare():
                return
            path = self.resource
            if path in FILES:
                self.reply(405)
            elif not self.parent_exists(path):
                self.reply(409)
            else:
                put(path, None)
                self.reply(201)

    def do_DELETE(self):
        with LOCK:
            if not self.prepare():
                return
            path = self.resource
            if path not in FILES:
                self.reply(404)
            elif path.endswith("/partial-delete"):
                body = ('<multistatus xmlns="DAV:"><response><href>%s</href>'
                        '<status>HTTP/1.1 423 Locked</status></response></multistatus>') % path
                self.reply(207, body.encode())
            else:
                for item in list(FILES):
                    if item == path or item.startswith(path + "/"):
                        del FILES[item]
                self.reply(204)

    def copy_move(self, move):
        with LOCK:
            if not self.prepare():
                return
            source = self.resource
            target = urllib.parse.unquote(
                urllib.parse.urlsplit(self.headers.get("Destination", "")).path
            ).rstrip("/") or "/"
            if move and target.endswith("/precious-race.txt"):
                put(target, b"external winner\n")
            condition = self.headers.get("If")
            if source not in FILES:
                self.reply(404)
            elif condition and (target not in FILES or "[" + etag(FILES[target]) + "]" not in condition):
                self.reply(412)
            elif target in FILES and self.headers.get("Overwrite") == "F":
                self.reply(412)
            elif not self.parent_exists(target):
                self.reply(409)
            else:
                old = target in FILES
                for path in list(FILES):
                    if path == target or path.startswith(target + "/"):
                        del FILES[path]
                for path, entry in list(FILES.items()):
                    if path == source or path.startswith(source + "/"):
                        # MOVE preserves the entity tag, as many DAV servers do.
                        destination = target + path[len(source):]
                        if move:
                            FILES[destination] = entry
                            del FILES[path]
                        else:
                            put(destination, entry["data"])
                self.reply(204 if old else 201)

    def do_COPY(self):
        self.copy_move(False)

    def do_MOVE(self):
        self.copy_move(True)


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print("PORT %d" % server.server_port, flush=True)
    server.serve_forever()
