#!/usr/bin/env python3
"""Re-inject a .user.js into matching Kapture tabs (localhost:61822).

Idempotence is the script's job: each userscript must tear down a previous
run (window.__nix*Teardown) before reconstructing. This file only strips the
metadata block, matches @match against open tabs, and POSTs the body.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

KAPTURE_BASE = os.environ.get("KAPTURE_URL", "http://127.0.0.1:61822").rstrip("/")
HEADER_RE = re.compile(r"//\s*==UserScript==.*?//\s*==/UserScript==", re.S)
MATCH_RE = re.compile(r"^//\s*@match\s+(\S+)", re.M)


def emit(msg: str, *, suppress: bool = False) -> int:
    sys.stdout.write(
        json.dumps({"systemMessage": msg, "suppressOutput": suppress}) + "\n"
    )
    return 0


def tool_path(payload: dict) -> str | None:
    ti = payload.get("tool_input") or payload.get("toolInput") or {}
    if not isinstance(ti, dict):
        ti = {}
    for key in ("file_path", "path", "target_file"):
        val = ti.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    return None


def gm_match(pattern: str, url: str) -> bool:
    try:
        regex = re.compile("^" + re.escape(pattern).replace(r"\*", ".*") + "$")
    except re.error:
        return False
    return regex.match(url) is not None


def kapture_tabs() -> list | None:
    try:
        with urllib.request.urlopen(KAPTURE_BASE + "/tabs", timeout=2) as resp:
            data = json.loads(resp.read().decode())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None
    return data if isinstance(data, list) else None


def kapture_evaluate(tab_id: str, code: str) -> dict:
    req = urllib.request.Request(
        KAPTURE_BASE + "/tab/" + tab_id + "/evaluate",
        data=json.dumps({"code": code, "timeout": 30000}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=40) as resp:
        return json.loads(resp.read().decode())


def preview(path: Path) -> int:
    if not path.name.endswith(".user.js"):
        return emit("userscript-preview: skip (not .user.js)", suppress=True)
    if not path.is_file():
        return emit("userscript-preview: missing " + str(path))
    raw = path.read_text(encoding="utf-8")
    header_m = HEADER_RE.search(raw)
    if not header_m:
        return emit("userscript-preview: no ==UserScript== block in " + path.name)
    matches = MATCH_RE.findall(header_m.group(0))
    if not matches:
        return emit("userscript-preview: no @match in " + path.name)
    body = (raw[: header_m.start()] + raw[header_m.end() :]).lstrip()
    if not body.strip():
        return emit("userscript-preview: empty body in " + path.name)

    tabs = kapture_tabs()
    if tabs is None:
        return emit(
            "userscript-preview: Kapture not on "
            + KAPTURE_BASE
            + " — open the matching tab with Kapture connected"
        )

    hits = []
    blocked = []
    for tab in tabs:
        if not isinstance(tab, dict):
            continue
        url = tab.get("url") or ""
        if not any(gm_match(pat, url) for pat in matches):
            continue
        tab_id = str(tab.get("tabId") or "")
        if not tab.get("evalAllowed"):
            blocked.append(urlparse(url).hostname or url)
            continue
        if tab_id:
            hits.append((tab_id, url))

    if not hits and blocked:
        return emit(
            "userscript-preview: matching tab, but evalAllowed=false — enable "
            "Allow JS execution in the Kapture popup (" + ", ".join(blocked) + ")"
        )
    if not hits:
        return emit(
            "userscript-preview: no open tab matches "
            + path.name
            + " "
            + " ".join(matches)
        )

    injected = []
    errors = []
    for tab_id, url in hits:
        try:
            resp = kapture_evaluate(tab_id, body)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as err:
            errors.append(str(err))
            continue
        if resp.get("success"):
            injected.append(urlparse(url).hostname or tab_id)
        else:
            errors.append(json.dumps(resp)[:240])

    bits = []
    if injected:
        bits.append("injected " + path.name + " → " + ", ".join(injected))
    if errors:
        bits.append("errors: " + "; ".join(errors))
    return emit("userscript-preview: " + " | ".join(bits))


def main() -> int:
    if len(sys.argv) > 1:
        return preview(Path(sys.argv[1]).expanduser())
    raw_stdin = sys.stdin.read()
    if not raw_stdin.strip():
        return emit("userscript-preview: no path (hook stdin empty)")
    try:
        payload = json.loads(raw_stdin)
    except json.JSONDecodeError:
        return emit("userscript-preview: hook stdin is not JSON")
    path = tool_path(payload if isinstance(payload, dict) else {})
    if not path:
        return 0
    return preview(Path(path).expanduser())


if __name__ == "__main__":
    raise SystemExit(main())
