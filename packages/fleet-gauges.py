"""fleet-gauges: hourly fleet-health gauges pushed to Grafana Cloud as OTLP JSON.

ADR-011 step 7 (docs/observability-hub-adr.md). Each family is best-effort: a
source that errors is skipped and counted in fleet_gauges_source_errors, never fatal.

  fleet_credential_expiry_timestamp_seconds{credential,provider}
      Grafana Cloud access tokens (GCOM API), Cloudflare API tokens (/user/tokens/verify)
      and the GitHub PAT (the github-authentication-token-expiration header). A
      credential with no expiry emits nothing.
  fleet_credential_active{credential,provider}
      1/0 = the Cloudflare token verifies as active / does not.
  github_security_open_alerts{owner,kind}
      Open Dependabot / code-scanning / secret-scanning alerts, summed per owner.
  github_workflow_last_conclusion_ok{repo,workflow}
      1/0 = the latest COMPLETED main-branch run of each workflow, in the same repos,
      succeeded (success/skipped/neutral) / did not. A workflow absent from a repo's
      latest 100 completed runs is absent here, not 0.
  nixpi_sd_release_age_seconds
      Age of the newest nixos-sd-image-*.img(.zst) asset on the SD_RELEASE_REPO's
      installer-latest release (its updated_at: the publish re-uploads the asset).
  hc_check_up{slug}, hc_check_status{slug,status}, hc_check_last_ping_age_seconds{slug}
  hc_check_overdue{slug}   1 when a check is `down`, or still `new` past the time its first
      ping was due: first seen (by this script) + its period or next cron fire + its grace.
      A brand-new weekly check is therefore not "overdue" for up to a week (2026-11-04).
      healthchecks.io Management API v3. up = 1 for up/grace, else 0; status is one
      0/1 point per slug for each of new/up/grace/down/paused, so a recovery shows at
      once; the ping age only when the check has pinged.
  launchd_doctor_findings{section}, launchd_doctor_ok
      `launchd-doctor --json` (packages/launchd-doctor.nix): findings per section, zeros
      included, and 1/0 = its exit code was 0.
  mac_backup_destinations, mac_backup_last_success_timestamp_seconds
      Time Machine. With no destination only the first is emitted (0). Informational:
      no rule alerts on it (the operator accepts no backup, 2026-11-04).
  terranix_drift_status{stack}, terranix_drift_last_run_timestamp_seconds
      0/1/2 = clean/drift/error per terranix stack, read from the daily drift check's
      summary.json (packages/terranix-drift.nix). Read here rather than pushed by the
      drift check itself: one OTLP push path and one credential set, not two.
  fleet_gauges_source_errors{source}
      Errors per source family, 0 included for every family in SOURCES, so a source
      that recovers reads 0 instead of keeping its last bad value.

Environment (supplied by `secret exec`, never argv): GRAFANA_OTLP_ENDPOINT,
GRAFANA_OTLP_INSTANCE, GRAFANA_OTLP_TOKEN, GCOM_TOKEN, GH_TOKEN, HC_API_KEY, and
CF_TOKEN_<n> pairs named by CF_TOKEN_NAMES (space-separated Keychain item names, same
order). Scope, from the Nix module (space-separated, unset = probe none): GCOM_REGIONS,
GH_ORGS, GH_USERS, SD_RELEASE_REPO (owner/repo), LAUNCHD_DOCTOR (an executable path).
Prints counts only; never a token.
"""

import base64
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

GCOM_REGIONS = os.environ.get("GCOM_REGIONS", "").split()
GH_ORGS = os.environ.get("GH_ORGS", "").split()
GH_USERS = os.environ.get("GH_USERS", "").split()
SD_RELEASE_REPO = os.environ.get("SD_RELEASE_REPO", "")
ALERT_KINDS = ["dependabot", "code-scanning", "secret-scanning"]
# Every source family fail() can name; each gets a fleet_gauges_source_errors point.
SOURCES = ["grafana", "cloudflare", "github", "time-machine", "terranix-drift", "healthchecks", "launchd-doctor"]
HC_STATUSES = ["new", "up", "grace", "down", "paused"]
WORKFLOW_OK = {"success", "skipped", "neutral"}
SD_IMAGE = re.compile(r"^nixos-sd-image-.*\.img(\.zst)?$")

points = []
errors = {}


def gauge(name, value, **attrs):
    points.append((name, float(value), attrs))


def fail(source, exc):
    errors[source] = errors.get(source, 0) + 1
    code = getattr(exc, "code", "")
    print(f"fleet-gauges: {source}: {type(exc).__name__} {code}".rstrip(), file=sys.stderr)


def http(url, token=None, scheme="Bearer", headers=False, extra=None):
    req = urllib.request.Request(url, headers={"Accept": "application/json", **(extra or {})})
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
            gauge("fleet_credential_expiry_timestamp_seconds", ts, credential=os.environ.get("GH_TOKEN_NAME", "github"), provider="github")
    except Exception as e:  # noqa: BLE001
        fail("github:pat", e)

    # Orgs and users walk the same filtered repo list, so both owners count the same
    # thing: public, non-fork, non-archived repos (the org-wide alerts endpoint would
    # also count private, fork and archived ones).
    owners = [(o, f"https://api.github.com/orgs/{o}/repos?type=all&per_page=100") for o in GH_ORGS] + \
        [(u, f"https://api.github.com/users/{u}/repos?type=owner&per_page=100") for u in GH_USERS]
    for owner, repos_url in owners:
        try:
            repos = [r["name"] for r in pages(repos_url, tok)
                     if not (r.get("fork") or r.get("private") or r.get("archived"))]
        except Exception as e:  # noqa: BLE001
            fail(f"github:{owner}:repos", e)
            continue
        workflow_health(owner, repos, tok)
        for kind in ALERT_KINDS:
            try:
                total = 0
                for name in repos:
                    try:
                        total += count_pages(
                            f"https://api.github.com/repos/{owner}/{name}/{kind}/alerts?state=open&per_page=100", tok)
                    except urllib.error.HTTPError as e:
                        if e.code not in (403, 404):  # feature off for that repo
                            raise
                gauge("github_security_open_alerts", total, owner=owner, kind=kind)
            except Exception as e:  # noqa: BLE001
                fail(f"github:{owner}:{kind}", e)

    if SD_RELEASE_REPO:
        try:
            rel = http(f"https://api.github.com/repos/{SD_RELEASE_REPO}/releases/tags/installer-latest", tok, "token")
            stamps = [iso_to_epoch(a["updated_at"]) for a in rel.get("assets", []) if SD_IMAGE.match(a.get("name", ""))]
            if stamps:
                gauge("nixpi_sd_release_age_seconds", time.time() - max(stamps))
        except Exception as e:  # noqa: BLE001
            fail("github:sd-release", e)


def workflow_health(owner, repos, tok):
    # One call per repo: runs come newest first, so the first run seen per workflow name
    # is its latest. `status=completed` keeps an in-progress run (conclusion null) out.
    for name in repos:
        try:
            body = http(f"https://api.github.com/repos/{owner}/{name}/actions/runs"
                        "?branch=main&status=completed&per_page=100", tok, "token")
            latest = {}
            for run in body.get("workflow_runs", []):
                latest.setdefault(run.get("name") or "?", run.get("conclusion"))
            for wf, conclusion in latest.items():
                gauge("github_workflow_last_conclusion_ok", 1 if conclusion in WORKFLOW_OK else 0,
                      repo=f"{owner}/{name}", workflow=wf)
        except Exception as e:  # noqa: BLE001
            fail(f"github:{owner}/{name}:workflows", e)


HC_SEEN = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
                       "fleet-gauges", "hc-first-seen.json")


def cron_field(spec, lo, hi):
    """The values one cron field allows: `*`, a number, `a-b`, `*/n`, comma lists."""
    out = set()
    for part in spec.split(","):
        rng, _, step = part.partition("/")
        a, b = (lo, hi) if rng == "*" else (int(rng.split("-")[0]), int(rng.split("-")[-1]))
        out.update(range(a, b + 1, int(step) if step else 1))
    return out


def cron_next(schedule, after):
    """First minute strictly after `after` (UTC epoch) that a 5-field cron schedule fires."""
    mi, hr, dom, mon, dow = schedule.split()
    sets = (cron_field(mi, 0, 59), cron_field(hr, 0, 23), cron_field(dom, 1, 31),
            cron_field(mon, 1, 12), {d % 7 for d in cron_field(dow, 0, 7)})
    t = datetime.datetime.fromtimestamp(after, datetime.timezone.utc).replace(second=0, microsecond=0)
    for _ in range(60 * 24 * 370):
        t += datetime.timedelta(minutes=1)
        if (t.minute in sets[0] and t.hour in sets[1] and t.day in sets[2]
                and t.month in sets[3] and (t.isoweekday() % 7) in sets[4]):
            return t.timestamp()
    raise ValueError(f"cron schedule never fires: {schedule}")


def first_ping_due(c, seen):
    """When a `new` check's first ping is due: first seen + period (or next fire) + grace."""
    grace = c.get("grace") or 0
    if c.get("schedule") and (c.get("tz") or "UTC") == "UTC":
        return cron_next(c["schedule"], seen) + grace
    return seen + (c.get("timeout") or 0) + grace


def healthchecks():
    key = os.environ.get("HC_API_KEY")
    if not key:
        return
    try:
        checks = http("https://healthchecks.io/api/v3/checks/", extra={"X-Api-Key": key})["checks"]
        now = time.time()
        try:
            with open(HC_SEEN) as f:
                seen = json.load(f)
        except (OSError, ValueError):
            seen = {}
        for c in checks:
            slug, status = c.get("slug") or c.get("name", "?"), c.get("status")
            # The API has no creation time, so `new` is dated from when this script first
            # saw it; a ping later clears it (status leaves `new`).
            if status == "new":
                seen.setdefault(slug, now)
            else:
                seen.pop(slug, None)
            overdue = status == "down" or (status == "new" and now > first_ping_due(c, seen[slug]))
            gauge("hc_check_overdue", 1 if overdue else 0, slug=slug)
            gauge("hc_check_up", 1 if status in ("up", "grace") else 0, slug=slug)
            for s in HC_STATUSES:
                gauge("hc_check_status", 1 if status == s else 0, slug=slug, status=s)
            if c.get("last_ping"):
                gauge("hc_check_last_ping_age_seconds", now - iso_to_epoch(c["last_ping"]), slug=slug)
        os.makedirs(os.path.dirname(HC_SEEN), exist_ok=True)
        with open(HC_SEEN, "w") as f:
            json.dump(seen, f)
    except Exception as e:  # noqa: BLE001
        fail("healthchecks", e)


def launchd_doctor():
    exe = os.environ.get("LAUNCHD_DOCTOR")
    if not exe:
        return
    try:
        # A non-zero exit means findings, not failure: the JSON is complete either way.
        out = subprocess.run([exe, "--json"], capture_output=True, text=True, timeout=300)
        report = json.loads(out.stdout)
        for section, found in report["sections"].items():
            gauge("launchd_doctor_findings", len(found), section=section)
        gauge("launchd_doctor_ok", 1 if report["rc"] == 0 else 0)
    except Exception as e:  # noqa: BLE001
        fail("launchd-doctor", e)


def pages(url, tok):
    # Follow Link rel="next": the Dependabot alerts endpoint is cursor-paged and answers
    # HTTP 400 to `page=` (measured 2026-11-03); the other endpoints accept either.
    while url:
        items, hdrs = http(url, tok, "token", headers=True)
        yield from items
        url = next((part.split(";")[0].strip(" <>") for part in (hdrs.get("Link") or "").split(",")
                    if 'rel="next"' in part), None)


def count_pages(url, tok):
    return sum(1 for _ in pages(url, tok))


def time_machine():
    try:
        out = subprocess.run(["/usr/bin/tmutil", "destinationinfo"], capture_output=True, text=True, timeout=30)
        dests = sum(1 for line in out.stdout.splitlines() if line.startswith("ID"))
        gauge("mac_backup_destinations", dests)
        if dests:
            latest = subprocess.run(["/usr/bin/tmutil", "latestbackup"], capture_output=True, text=True, timeout=30)
            if latest.returncode != 0:
                # A failed read is not "no backup yet": report it instead of silently omitting the gauge.
                raise RuntimeError(f"tmutil latestbackup exited {latest.returncode}")
            stamp = os.path.basename(latest.stdout.strip())[:17]  # YYYY-MM-DD-HHMMSS
            if stamp:
                ts = time.mktime(time.strptime(stamp, "%Y-%m-%d-%H%M%S"))
                gauge("mac_backup_last_success_timestamp_seconds", ts)
    except Exception as e:  # noqa: BLE001
        fail("time-machine", e)


def terranix_drift():
    # The daily drift check's summary (packages/terranix-drift.nix), at the path the Nix
    # wrapper names. Re-sent every hour, so a stale run shows as an old last-run
    # timestamp instead of a gap. Each stack's `code` is the drift check's own
    # 0/1/2 = clean/drift/error class, so it is sent as-is rather than re-derived.
    path = os.environ.get("TERRANIX_DRIFT_SUMMARY", "")
    if not path or not os.path.exists(path):
        return
    try:
        with open(path) as f:
            summary = json.load(f)
        for s in summary["stacks"]:
            gauge("terranix_drift_status", s["code"], stack=s["stack"])
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


def errors_by_family(errs):
    # One point per `source` label: several "github:<owner>:<kind>" errors share the
    # label "github", and duplicate label sets in one push make Mimir reject all of it.
    out = {}
    for source, n in errs.items():
        family = source.split(":")[0]
        out[family] = out.get(family, 0) + n
    return out


def main():
    grafana_tokens()
    cloudflare_tokens()
    github()
    time_machine()
    terranix_drift()
    healthchecks()
    launchd_doctor()
    by_family = errors_by_family(errors)
    for family in sorted(set(SOURCES) | set(by_family)):
        gauge("fleet_gauges_source_errors", by_family.get(family, 0), source=family)
    gauge("fleet_gauges_last_run_timestamp_seconds", time.time())
    status = push()
    print(f"fleet-gauges: pushed {len(points)} points, {sum(errors.values())} source errors, HTTP {status}")


if __name__ == "__main__":
    main()
