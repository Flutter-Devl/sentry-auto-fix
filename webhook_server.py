"""Optional local webhook receiver for Sentry Internal Integrations."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

from orchestrator import load_env_file, process_issue


def run_webhook_server(*, host: str = "127.0.0.1", port: int = 8765) -> None:
    script_dir = Path(__file__).resolve().parent
    load_env_file(script_dir / "config.env")
    secret = os.environ.get("SENTRY_WEBHOOK_SECRET", "")

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)

            if secret and not _verify_signature(body, self.headers.get("Sentry-Hook-Signature"), secret):
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b"invalid signature")
                return

            payload = json.loads(body.decode("utf-8"))
            action = payload.get("action")
            data = payload.get("data", {}).get("issue") or payload.get("data", {})

            issue_id = str(data.get("id") or "")
            if action in ("created", "unresolved", "regression") and issue_id:
                threading.Thread(
                    target=process_issue,
                    kwargs={"issue_id": issue_id},
                    daemon=True,
                ).start()

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            print(f"[webhook] {self.address_string()} - {format % args}")

    server = HTTPServer((host, port), Handler)
    print(f"Webhook listening on http://{host}:{port}/")
    print("Point Sentry Internal Integration webhook here (use cloudflared tunnel if remote).")
    server.serve_forever()


def _verify_signature(body: bytes, signature: str | None, secret: str) -> bool:
    if not signature:
        return False
    digest = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(digest, signature)
