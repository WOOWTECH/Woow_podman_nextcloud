#!/usr/bin/env python3
"""Open a temporary ODT in Nextcloud Office using a real Chromium browser."""
import base64
import io
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

from playwright.sync_api import sync_playwright


def configured_public_url() -> str:
    env_file = Path.home() / ".config/nextcloud/nextcloud.env"
    if env_file.is_file():
        for line in env_file.read_text().splitlines():
            if line.startswith("NEXTCLOUD_PUBLIC_URL="):
                return line.partition("=")[2].strip()
    return "http://127.0.0.1:18081"


BASE = (os.environ.get("NEXTCLOUD_TEST_URL") or configured_public_url()).rstrip("/")
USER = os.environ.get("NEXTCLOUD_TEST_USER", "admin")
PASSWORD = subprocess.check_output(
    ["podman", "secret", "inspect", "--showsecret", "--format", "{{.SecretData}}", "nextcloud-admin-password"],
    text=True,
).strip()
NAME = f"office-browser-{uuid.uuid4().hex[:12]}.odt"
URL = f"{BASE}/remote.php/dav/files/{USER}/{NAME}"
TOKEN = base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()


def request(method: str, data: bytes | None = None):
    headers = {"Authorization": f"Basic {TOKEN}", "Content-Type": "application/vnd.oasis.opendocument.text"}
    return urllib.request.urlopen(urllib.request.Request(URL, data=data, method=method, headers=headers), timeout=30)


def make_odt() -> bytes:
    content = b'''<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:text><text:p>Initial Podman Office document</text:p></office:text></office:body></office:document-content>'''
    manifest = b'''<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>'''
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as archive:
        archive.writestr("mimetype", "application/vnd.oasis.opendocument.text", compress_type=zipfile.ZIP_STORED)
        archive.writestr("content.xml", content)
        archive.writestr("META-INF/manifest.xml", manifest)
    return out.getvalue()


def main():
    with request("PUT", make_odt()) as response:
        assert response.status in (201, 204)
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page(viewport={"width": 1440, "height": 900})
            diagnostics = []
            page.on("framenavigated", lambda frame: diagnostics.append(("frame", urllib.parse.urlsplit(frame.url).path)))
            page.on("requestfailed", lambda request: diagnostics.append(("request failed", urllib.parse.urlsplit(request.url).path, request.failure)))
            page.on("response", lambda response: diagnostics.append(("HTTP", response.status, urllib.parse.urlsplit(response.url).path)) if response.status >= 400 else None)
            page.on("console", lambda message: diagnostics.append(("console error", urllib.parse.urlsplit(message.location.get("url", "")).path)) if message.type == "error" else None)
            page.goto(BASE + "/login", wait_until="domcontentloaded", timeout=30000)
            page.locator("#user").fill(USER)
            page.locator("#password").fill(PASSWORD)
            page.locator("button[type=submit]").click()
            page.wait_for_url("**/apps/dashboard/**", timeout=30000)
            page.goto(BASE + "/apps/files/", wait_until="domcontentloaded", timeout=30000)
            file = page.get_by_text(NAME, exact=True)
            file.wait_for(state="visible", timeout=30000)
            file.dblclick()
            # The editor iframe is created only after Nextcloud finishes its WOPI setup.
            # Wait for that event and catch the Files UI's explicit failure message.
            deadline = time.monotonic() + 90
            office_frame = None
            while time.monotonic() < deadline:
                office_frame = next((frame for frame in page.frames if "/cool.html?" in frame.url), None)
                if office_frame is not None:
                    break
                if page.get_by_text("Document loading failed", exact=True).count():
                    print(f"Office load diagnostics: {diagnostics[-20:]}", file=sys.stderr)
                    page.screenshot(path="/tmp/nextcloud-office-editor-missing.png")
                    raise AssertionError("Nextcloud reported that Collabora could not load the document")
                page.wait_for_timeout(1000)
            if office_frame is None:
                paths = [urllib.parse.urlsplit(frame.url).path for frame in page.frames]
                print(f"Office iframe missing; page={urllib.parse.urlsplit(page.url).path}; frames={paths}; diagnostics={diagnostics[-20:]}", file=sys.stderr)
                page.screenshot(path="/tmp/nextcloud-office-editor-missing.png")
                raise AssertionError("Nextcloud did not open the Collabora editor")
            office_frame.locator("#document-canvas").wait_for(state="visible", timeout=30000)
            assert "4 words, 30 characters" in office_frame.locator("body").inner_text(), "ODT content was not loaded"
            # Collabora shows its first-run welcome overlay for a new browser context.
            if office_frame.locator(".iframe-welcome-wrap").is_visible():
                welcome_frame = next(frame for frame in page.frames if "/welcome/welcome.html" in frame.url)
                welcome_frame.locator("#welcome-close").click()
                office_frame.locator(".iframe-welcome-wrap").wait_for(state="hidden", timeout=5000)
            office_frame.locator("#document-canvas").click(position={"x": 350, "y": 150})
            page.keyboard.press("Control+End")
            page.keyboard.type(" Verified office save")
            page.keyboard.press("Control+s")
            page.wait_for_timeout(8000)
            with request("GET") as response:
                updated = response.read()
            with zipfile.ZipFile(io.BytesIO(updated)) as archive:
                xml = archive.read("content.xml").decode()
            assert "Verified office save" in xml, "Office edit did not reach Nextcloud WebDAV"
            print("Collabora opened, edited, and saved ODT through WOPI")
            browser.close()
    finally:
        try:
            with request("DELETE") as response:
                print("cleanup:", response.status)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise


if __name__ == "__main__":
    main()
