"""fleet-gauges: hourly fleet-health gauges pushed to Grafana Cloud as OTLP JSON.

ADR-011 step 7 (docs/observability-hub-adr.md). Each family is best-effort: a
source that errors is skipped and counted in fleet_gauges_source_errors, never fatal.

  fleet_credential_expiry_timestamp_seconds{credential,provider}
      Grafana Cloud access tokens (GCOM API), Cloudflare API tokens (/user/tokens/verify)
      and the GitHub PAT (the github-authentication-token-expiration header). A
      credential with no expiry emits nothing.
  github_security_open_alerts{owner,kind}
      Open Dependabot / code-scanning / secret-scanning alerts, summed per owner.
  mac_backup_destinations, mac_backup_last_success_timestamp_seconds
      Time Machine. With no destination only the first is emitted (0).
  terranix_drift_status{stack}, terranix_drift_last_run_timestamp_seconds
      0/1/2 = clean/drift/error per terranix stack, read from the daily drift check's
      summary.json (packages/terranix-drift.nix). Read here rather than pushed by the
      drift check itself: one OTLP push path and one credential set, not two.

Environment (supplied by `secret exec`, never argv): GRAFANA_OTLP_ENDPOINT,
GRAFANA_OTLP_INSTANCE, GRAFANA_OTLP_TOKEN, GCOM_TOKEN, GH_TOKEN, and CF_TOKEN_<n>
pairs named by CF_TOKEN_NAMES (space-separated Keychain item names, same order).
Prints counts only; never a token.
"""

import base64
import datetime
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

GCOM_REGIONS = ["prod-ca-east-0", "prod-us-west-0"]
GH_OWNERS = ["kattakath", "ismailkattakath"]
ALERT_KINDS = ["dependabot", "code-scanning", "secret-scanning"]

points = []
errors = {}


def gauge(name, value, **attrs):
    points.append((name, float(value), attrs))


def fail(source, exc):
    errors[source] = errors.get(source, 0) + 1
    code = getattr(exc, "code", "")
    print(f"fleet-gauges: {source}: {type(exc).__name__} {code}".rstrip(), file=sys.stderr)


def http(url, token=None, scheme="Bearer", headers=False):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        req.add_header("Authorization", f"{scheme} {token}")
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = json.loads(resp.read() or b"null")
        return (body, resp.headers) if headers else body


def iso_to_epoch(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def grafana_tokens():
    tok = os.environ.get("GCOM_TOKEN")
    if not tok:
        return
    for region in GCOM_REGIONS:
        try:
            body = http(f"https://grafana.com/api/v1/tokens?region={region}&pageSize=100", tok)
            for t in body.get("items", []):
                if t.get("expiresAt"):
                    gauge("fleet_credential_expiry_timestamp_seconds", iso_to_epoch(t["expiresAt"]),
                          credential=t.get("name", "?"), provider="grafana")
        except Exception as e:  # noqa: BLE001 — best-effort per source
            fail(f"grafana:{region}", e)


def cloudflare_tokens():
    names = os.environ.get("CF_TOKEN_NAMES", "").split()
    for i, name in enumerate(names):
        tok = os.environ.get(f"CF_TOKEN_{i}")
        if not tok:
            continue
        try:
            res = http("https://api.cloudflare.com/client/v4/user/tokens/verify", tok)["result"]
            if res.get("expires_on"):
                gauge("fleet_credential_expiry_timestamp_seconds", iso_to_epoch(res["expires_on"]),
                      credential=name, provider="cloudflare")
            gauge("fleet_credential_active", 1 if res.get("status") == "active" else 0,
                  credential=name, provider="cloudflare")
        except Exception as e:  # noqa: BLE001
            fail(f"cloudflare:{name}", e)


def github():
    tok = os.environ.get("GH_TOKEN")
    if not tok:
        return
    try:
        _, hdrs = http("https://api.github.com/user", tok, "token", headers=True)
        exp = hdrs.get("github-authentication-token-expiration")
        if exp:
            ts = datetime.datetime.strptime(exp.replace(" UTC", " +0000"), "%Y-%m-%d %H:%M:%S %z").timestamp()
            gauge("fleet_credential_expiry_timestamp_seconds", ts, credential="gh:github.com:pat", provider="github")
    except Exception as e:  # noqa: BLE001
        fail("github:pat", e)

    for owner in GH_OWNERS:
        for kind in ALERT_KINDS:
            try:
                if owner == "kattakath":
                    total = count_pages(f"https://api.github.com/orgs/{owner}/{kind}/alerts?state=open&per_page=100", tok)
                else:
                    total = 0
                    repos = http(f"https://api.github.com/users/{owner}/repos?type=owner&per_page=100", tok)
                    for r in repos:
                        if r.get("fork") or r.get("private") or r.get("archived"):
                            continue
                        try:
                            total += count_pages(
                                f"https://api.github.com/repos/{owner}/{r['name']}/{kind}/alerts?state=open&per_page=100", tok)
                        except urllib.error.HTTPError as e:
                            if e.code not in (403, 404):  # feature off for that repo
                                raise
                gauge("github_security_open_alerts", total, owner=owner, kind=kind)
            except Exception as e:  # noqa: BLE001
                fail(f"github:{owner}:{kind}", e)


def count_pages(url, tok):
    # Follow Link rel="next": the Dependabot alerts endpoint is cursor-paged and answers
    # HTTP 400 to `page=` (measured 2026-11-03); the other two accept either.
    total = 0
    while url:
        items, hdrs = http(url, tok, "token", headers=True)
        total += len(items)
        url = next((part.split(";")[0].strip(" <>") for part in (hdrs.get("Link") or "").split(",")
                    if 'rel="next"' in part), None)
    return total


def time_machine():
    try:
        out = subprocess.run(["/usr/bin/tmutil", "destinationinfo"], capture_output=True, text=True, timeout=30)
        dests = sum(1 for line in out.stdout.splitlines() if line.startswith("ID"))
        gauge("mac_backup_destinations", dests)
        if dests:
            latest = subprocess.run(["/usr/bin/tmutil", "latestbackup"], capture_output=True, text=True, timeout=30)
            stamp = os.path.basename(latest.stdout.strip())[:17]  # YYYY-MM-DD-HHMMSS
            if stamp:
                ts = time.mktime(time.strptime(stamp, "%Y-%m-%d-%H%M%S"))
                gauge("mac_backup_last_success_timestamp_seconds", ts)
    except Exception as e:  # noqa: BLE001
        fail("time-machine", e)


DRIFT_STATUS = {"clean": 0, "drift": 1, "error": 2}


def terranix_drift():
    # The daily drift check's summary (packages/terranix-drift.nix). Re-sent every hour,
    # so a stale run shows as an old last-run timestamp instead of a gap.
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    path = os.path.join(state, "nix-config-terranix-drift", "summary.json")
    if not os.path.exists(path):
        return
    try:
        with open(path) as f:
            summary = json.load(f)
        for s in summary["stacks"]:
            gauge("terranix_drift_status", DRIFT_STATUS.get(s["status"], 2), stack=s["stack"])
        gauge("terranix_drift_last_run_timestamp_seconds", summary["finished"])
    except Exception as e:  # noqa: BLE001
        fail("terranix-drift", e)


def push():
    now = str(time.time_ns())
    metrics = {}
    for name, value, attrs in points:
        dp = {"asDouble": value, "timeUnixNano": now,
              "attributes": [{"key": k, "value": {"stringValue": v}} for k, v in attrs.items()]}
        metrics.setdefault(name, []).append(dp)
    body = {"resourceMetrics": [{
        "resource": {"attributes": [
            {"key": "service.name", "value": {"stringValue": "fleet-gauges"}},
            {"key": "deployment.environment", "value": {"stringValue": "operator-mac"}}]},
        "scopeMetrics": [{"metrics": [{"name": n, "gauge": {"dataPoints": d}} for n, d in metrics.items()]}],
    }]}
    auth = base64.b64encode(
        f"{os.environ['GRAFANA_OTLP_INSTANCE']}:{os.environ['GRAFANA_OTLP_TOKEN']}".encode()).decode()
    req = urllib.request.Request(f"{os.environ['GRAFANA_OTLP_ENDPOINT']}/v1/metrics",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Basic {auth}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status


def main():
    grafana_tokens()
    cloudflare_tokens()
    github()
    time_machine()
    terranix_drift()
    for source, n in errors.items():
        gauge("fleet_gauges_source_errors", n, source=source.split(":")[0])
    gauge("fleet_gauges_last_run_timestamp_seconds", time.time())
    status = push()
    print(f"fleet-gauges: pushed {len(points)} points, {sum(errors.values())} source errors, HTTP {status}")


if __name__ == "__main__":
    main()
