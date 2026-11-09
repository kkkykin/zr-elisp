"""Local OPDS/KOReader fixture based on Komga and calibre routes."""

import base64
import hashlib
import json
import sys
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


root = Path(sys.argv[1])
lock = threading.Lock()
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aN1sAAAAASUVORK5CYII="
)
for name in ("one", "two"):
    with zipfile.ZipFile(root / (name + ".epub"), "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr(
            "META-INF/container.xml",
            "<container><rootfiles><rootfile full-path='OEBPS/book.opf' "
            "media-type='application/oebps-package+xml'/></rootfiles></container>",
        )
        archive.writestr(
            "OEBPS/book.opf",
            "<package version='3.0' xmlns:dc='http://purl.org/dc/elements/1.1/'>"
            "<metadata><dc:title>本地书名</dc:title><dc:creator>作者</dc:creator></metadata>"
            "<manifest><item id='a' href='Text/a.xhtml' media-type='application/xhtml+xml'/>"
            "<item id='b' href='Text/b.xhtml' media-type='application/xhtml+xml'/>"
            "<item id='notes' href='notes.xhtml' media-type='application/xhtml+xml'/>"
            "<item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>"
            "<item id='img' href='tiny.png' media-type='image/png'/></manifest>"
            "<spine><itemref idref='a'/><itemref idref='b'/></spine></package>",
        )
        archive.writestr(
            "OEBPS/nav.xhtml",
            "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'>"
            "<a href='Text/a.xhtml#start'>第一章</a><a href='Text/b.xhtml#note'>第二章</a>"
            "</nav></body></html>",
        )
        archive.writestr(
            "OEBPS/Text/a.xhtml",
            "<html><body><h1 id='start'>第一章正文</h1><p>中文内容 α</p>"
            "<a href='b.xhtml#note'>下一章</a><a href='../notes.xhtml#footnote'>附录脚注</a>"
            "<img src='../tiny.png'/></body></html>",
        )
        archive.writestr(
            "OEBPS/Text/b.xhtml",
            "<html><body><h1>第二章正文</h1><p id='note'>脚注目标</p>"
            "<a href='a.xhtml#start'>上一章</a></body></html>",
        )
        archive.writestr("OEBPS/notes.xhtml", "<html><body><p id='footnote'>附录正文</p></body></html>")
        archive.writestr("OEBPS/tiny.png", png)


def publication(name):
    revision = root / "revision.txt"
    modified = revision.read_text().strip() if revision.exists() else "2026-01-01T00:00:00Z"
    links = [
        {"rel": "self", "href": f"/publication/{name}", "type": "application/opds-publication+json"},
        {"rel": ["http://opds-spec.org/acquisition"], "href": f"/content/{name}.epub", "type": "application/epub+zip"},
    ]
    return {"metadata": {"title": "测试书籍 " + name, "modified": modified,
                         "identifier": "urn:isbn:duplicate", "author": [{"name": "作者甲"}, "作者乙"]},
            "links": links}


def partial_md5(path):
    digest = hashlib.md5()
    with path.open("rb") as stream:
        for offset in (0, 1024, 4096, 16384, 65536, 262144, 1048576,
                       4194304, 16777216, 67108864, 268435456, 1073741824):
            stream.seek(offset)
            block = stream.read(1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def respond(self, status, body=b"", content_type="application/opds+json", headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def json_response(self, value, status=200, content_type="application/opds+json"):
        self.respond(status, json.dumps(value, ensure_ascii=False).encode(), content_type)

    def record(self, body=None):
        with lock, (root / "requests.jsonl").open("a") as stream:
            stream.write(json.dumps({"method": self.command, "path": self.path,
                                     "key": self.headers.get("X-API-Key"),
                                     "authorization": self.headers.get("Authorization"),
                                     "accept": self.headers.get("Accept"),
                                     "content_type": self.headers.get("Content-Type"),
                                     "sync_user": self.headers.get("X-Auth-User"),
                                     "sync_key": self.headers.get("X-Auth-Key"),
                                     "body": body}) + "\n")

    def authenticated(self):
        if (root / "digest-auth.txt").exists():
            authorization = self.headers.get("Authorization", "")
            if not authorization.startswith("Digest "):
                return False
            fields = urllib.request.parse_keqv_list(urllib.request.parse_http_list(authorization[7:]))
            md5 = lambda value: hashlib.md5(value.encode()).hexdigest()
            ha1 = md5("reader:calibre:test-password")
            ha2 = md5(self.command + ":" + self.path)
            expected = md5(":".join((ha1, "fixture-nonce", fields.get("nc", ""), fields.get("cnonce", ""), "auth", ha2)))
            return (fields.get("username") == "reader" and fields.get("nonce") == "fixture-nonce" and
                    fields.get("uri") == self.path and fields.get("response") == expected)
        basic = "Basic " + base64.b64encode(b"reader:test-password").decode()
        return self.headers.get("X-API-Key") in ("test-key", "komga-key") or self.headers.get("Authorization") == basic

    def koreader(self, path, body=None):
        """Reproduce the distinct auth and response shapes of both servers."""
        if path.startswith("/komga/koreader/"):
            kind, route = "komga", path.removeprefix("/komga/koreader/")
            authorized = self.headers.get("X-Auth-User") == "komga-key"
        elif path.startswith("/calibre/kosync/"):
            kind, route = "calibre", path.removeprefix("/calibre/kosync/")
            authorized = (self.headers.get("X-Auth-User") == "reader" and
                          self.headers.get("X-Auth-Key") == hashlib.md5(b"test-password").hexdigest())
        else:
            return False
        if not authorized:
            self.json_response({"code": 2001, "message": "Unauthorized"}, 403 if kind == "komga" else 401)
            return True
        if route == "users/auth":
            (root / "kosync-enabled.txt").write_text("enabled")
            self.json_response({"authorized": "OK"})
            return True
        previous = root / "koreader-progress.json"
        if self.command == "GET" and route.startswith("syncs/progress/"):
            if (root / "ko-get-status.txt").exists():
                self.respond(int((root / "ko-get-status.txt").read_text()))
            elif (root / "ko-get-body.txt").exists():
                self.respond(200, (root / "ko-get-body.txt").read_bytes(), "application/json")
            elif route.rsplit("/", 1)[-1] != partial_md5(root / "one.epub"):
                self.respond(404)
            elif previous.exists():
                self.json_response(json.loads(previous.read_text()), content_type="application/json")
            elif kind == "komga":
                self.json_response({"status": 200, "error": "OK", "timestamp": "2026-11-09T00:00:00Z",
                                    "message": "No progress found for this book", "path": path},
                                   content_type="application/json")
            else:
                self.json_response({}, content_type="application/json")
        elif self.command == "PUT" and route == "syncs/progress":
            if (root / "ko-put-status.txt").exists():
                self.respond(int((root / "ko-put-status.txt").read_text()))
                return True
            if (root / "ko-put-delay.txt").exists():
                time.sleep(float((root / "ko-put-delay.txt").read_text()))
            if (body.get("document") != partial_md5(root / "one.epub") or
                body.get("progress") not in ("/body/DocFragment[1].0", "/body/DocFragment[2].0") or
                not 0 <= body.get("percentage", -1) <= 1 or
                not body.get("device") or not body.get("device_id")):
                self.respond(400)
                return True
            if kind == "calibre":
                offset = float((root / "ko-time-offset.txt").read_text()) if (root / "ko-time-offset.txt").exists() else 0
                body["timestamp"] = int(time.time() + offset)
            previous.write_text(json.dumps(body))
            if kind == "komga":
                self.respond(200, content_type="application/json")
            else:
                self.json_response({"document": body["document"], "timestamp": body["timestamp"]},
                                   content_type="application/json")
        else:
            self.respond(404)
        return True

    def do_GET(self):
        self.record()
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        if path == "/echo":
            self.json_response(dict(self.headers))
            return
        if path == "/redirect":
            target = urllib.parse.parse_qs(parsed.query).get("target", ["/catalog"])[0]
            self.respond(302, headers={"Location": target})
            return
        if self.koreader(path):
            return
        if not self.authenticated():
            challenge = ('Digest realm="calibre", nonce="fixture-nonce", algorithm=MD5, qop="auth"'
                         if (root / "digest-auth.txt").exists() else 'Basic realm="calibre", charset="UTF-8"')
            self.respond(401, headers={"WWW-Authenticate": challenge})
            return
        if path == "/slow":
            time.sleep(2)
        if path == "/malformed":
            self.respond(200, b"not json")
        elif path == "/failure":
            self.respond(503)
        elif path in ("/catalog", "/komga/opds/v2/catalog", "/calibre/opds"):
            if path != "/catalog" and self.headers.get("Accept") != "application/opds+json":
                self.respond(200, b"<feed>OPDS 1</feed>", "application/atom+xml")
                return
            if path == "/calibre/opds":
                book = publication("one")
                book["links"] = [{"rel": "http://opds-spec.org/acquisition", "href": "/calibre/get/epub/1/main",
                                  "type": "application/epub+zip"}]
                self.json_response({"metadata": {"title": "calibre Library"}, "publications": [book]})
                return
            if path == "/komga/opds/v2/catalog":
                self.json_response({"metadata": {"title": "Komga Library"}, "publications": [publication("one")]})
                return
            self.json_response({"metadata": {"title": "Library"},
                                "links": [{"rel": "self", "href": "/catalog"}],
                                "navigation": [{"href": "/books", "type": "application/opds+json", "title": "All books", "templated": False}],
                                "groups": [{"metadata": {"title": "Recommended"},
                                            "links": [{"rel": "self", "href": "/books", "type": "application/opds+json"}],
                                            "publications": [publication("one")]}]})
        elif path == "/books":
            page = urllib.parse.parse_qs(parsed.query).get("page", ["1"])[0]
            links = [{"rel": "self", "href": self.path}]
            if page == "1":
                links.append({"rel": ["next"], "href": "?page=2", "type": "application/opds+json"})
                books = [publication("one"), {"metadata": {"title": "Comic"}, "links": [
                    {"rel": "acquisition", "href": "/comic.cbz", "type": "application/vnd.comicbook+zip"}]}]
            else:
                books = [publication("two"), publication("one")]
            self.json_response({"metadata": {"title": "Books"}, "links": links, "publications": books,
                                "navigation": [{"href": "/catalog", "type": "application/opds+json", "title": "Home"}]})
        elif path.startswith("/publication/"):
            self.json_response(publication(path.rsplit("/", 1)[-1]), content_type="application/opds-publication+json")
        elif path.startswith("/content/"):
            self.respond(200, (root / path.rsplit("/", 1)[-1]).read_bytes(), "application/epub+zip")
        elif path == "/calibre/get/epub/1/main":
            if (root / "kosync-enabled.txt").exists():
                (root / "kosync-registered.txt").write_text(partial_md5(root / "one.epub"))
            self.respond(200, (root / "one.epub").read_bytes(), "application/epub+zip")
        else:
            self.respond(404)

    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        self.record(body)
        if self.koreader(urllib.parse.urlsplit(self.path).path, body):
            return
        self.respond(404)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port.txt").write_text(str(server.server_port))
server.serve_forever()
