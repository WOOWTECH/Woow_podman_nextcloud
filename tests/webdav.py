#!/usr/bin/env python3
"""Exercise authenticated WebDAV against a running fresh Nextcloud instance."""
import base64
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid


def main() -> int:
    base = os.environ.get("NEXTCLOUD_TEST_URL", "http://127.0.0.1:18081").rstrip("/")
    user = os.environ.get("NEXTCLOUD_TEST_USER", "admin")
    password = subprocess.check_output(
        ["podman", "secret", "inspect", "--showsecret", "--format", "{{.SecretData}}", "nextcloud-admin-password"],
        text=True,
    ).strip()
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    path = f"/remote.php/dav/files/{urllib.parse.quote(user)}/"
    prefix = f"podman-parity-{uuid.uuid4().hex}"
    source = base + path + prefix + ".txt"
    moved = base + path + prefix + "-moved.txt"

    def request(method: str, url: str, data: bytes | None = None, headers: dict | None = None):
        headers = {**(headers or {}), "Authorization": "Basic " + token}
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers, method=method), timeout=30) as response:
            return response.status, response.read()

    payload = os.urandom(64) + b"\nNextcloud Podman WebDAV check\n"
    try:
        status, _ = request("PUT", source, payload, {"Content-Type": "text/plain"})
        assert status in (201, 204), f"PUT: {status}"
        status, body = request("GET", source)
        assert status == 200 and body == payload, "GET differs from uploaded bytes"
        status, _ = request("PROPFIND", source, b"", {"Depth": "0"})
        assert status == 207, f"PROPFIND: {status}"
        status, _ = request("MOVE", source, headers={"Destination": moved, "Overwrite": "F"})
        assert status in (201, 204), f"MOVE: {status}"
        status, body = request("GET", moved)
        assert status == 200 and body == payload, "moved file differs"
        print("WebDAV PUT, GET, PROPFIND, MOVE: passed")
        return 0
    finally:
        for url in (source, moved):
            try:
                request("DELETE", url)
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"WebDAV check failed: {error}", file=sys.stderr)
        sys.exit(1)
