#!/usr/bin/env python3
"""ibisOffice (WASM/WebGPU) を 3367 番ポートで静的配信するサーバ.

SharedArrayBuffer / WebGPU 用の COOP/COEP ヘッダを付けて配信する.
"""
import http.server
import os
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3367
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else "/opt/ibisoffice/public-ibisoffice"
# Tailscale serve (https) がホスト側ポートを横取りできるよう loopback のみで待つ.
BIND = os.environ.get("IBISOFFICE_BIND", "127.0.0.1")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        super().end_headers()


if __name__ == "__main__":
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    server = http.server.ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"serving {DIRECTORY} on {BIND}:{PORT} (COOP/COEP enabled)", flush=True)
    server.serve_forever()
