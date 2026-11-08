#!/usr/bin/env python3
"""A small proxy in front of the local S3 service, for checking what the app does when a bucket
that said it supports conditional writes then answers 501 to one.

  s3-501-proxy.py [PORT] [UPSTREAM_PORT]    defaults 9100 and 9000

Everything is passed through. While the file `501-BUCKET` exists in the directory the proxy was
started in, a PUT to BUCKET with an If-None-Match header gets 501 instead. Make and remove the file
to turn it on and off, per bucket."""
import http.client
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1]) if len(sys.argv) > 1 else 9100
upstream = int(sys.argv[2]) if len(sys.argv) > 2 else 9000


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_any(self):
        bucket = self.path.lstrip("/").split("/", 1)[0].split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.command == "PUT" and "If-None-Match" in self.headers and os.path.exists(f"501-{bucket}"):
            print(f"501 for PUT {self.path}", flush=True)
            self.send_response(501)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        conn = http.client.HTTPConnection("127.0.0.1", upstream)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
        conn.request(self.command, self.path, body=body or None, headers=headers)
        response = conn.getresponse()
        data = response.read()
        self.send_response(response.status)
        for k, v in response.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        conn.close()

    do_GET = do_PUT = do_POST = do_DELETE = do_HEAD = handle_any

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), Proxy).serve_forever()
