#!/usr/bin/env python3
"""grafana-rollup.py — one row per day of KPI aggregates, Grafana -> the history Sheet.

ADR-011 step 11 (docs/observability-hub-adr.md). Grafana keeps 14-31 days; this copies
yesterday's aggregate of each KPI into a Google Sheet, which is a STORE only. Grafana
reads it back with its Sheets datasource; nothing charts inside the Sheet.

Each KPI is one PromQL instant query evaluated at the END of the UTC day being rolled
up, through Grafana's datasource proxy (a Viewer service-account token), so the job
needs no Prometheus instance id. Columns are matched BY HEADER NAME: a new KPI becomes
a new column, and a removed one leaves its old column alone. Re-running a day updates
that day's row in place (only the KPIs that returned a value) instead of adding a second one.

Environment: GRAFANA_URL, GRAFANA_TOKEN (Viewer), SHEET_ID, GOOGLE_ACCESS_TOKEN
(from google-github-actions/auth, WIF), optional ROLLUP_DATE=YYYY-MM-DD (default:
yesterday, UTC). Prints the row's KPI count and the empty ones; never a value.
"""
import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request

PROM = "grafanacloud-prom"
USAGE = "grafanacloud-usage"

def day_total(counter):
    """One day's growth of a sparse cumulative counter, the first sample included.

    increase() needs two samples and always drops a stream's FIRST one. Claude Code's
    streams gain a sample only when a session exports (deltatocumulative in
    modules/home/claude-otel.nix), so a light day read EMPTY (2026-11-03: one sample, no
    value). A stream that STARTED today is counted by its last value, since all of it is
    today's; one that also existed yesterday by increase(), which also absorbs collector
    restarts (counter resets).
    """
    new = f"sum(last_over_time({counter}[1d]) unless last_over_time({counter}[1d] offset 1d)) or vector(0)"
    old = f"sum(increase({counter}[1d]) and last_over_time({counter}[1d] offset 1d)) or vector(0)"
    return f"({new}) + ({old})"


# name -> (datasource uid, PromQL evaluated at the day's end). Ratios, counts, hours and
# the AI spend in USD; the finance figures are ratios or counts, never amounts, by
# construction (beancount-kit metrics).
KPIS = {
    "finance_savings_rate_last_month": (PROM, 'max(last_over_time(finance_savings_rate{window="last_month"}[35d]))'),
    "finance_budget_used_ratio": (PROM, "max(last_over_time(finance_budget_used_ratio[35d]))"),
    "finance_month_elapsed_ratio": (PROM, "max(last_over_time(finance_month_elapsed_ratio[35d]))"),
    "finance_budgets_over": (PROM, 'max(last_over_time(finance_budgets{state="over"}[35d]))'),
    "finance_review_backlog": (PROM, "max(last_over_time(finance_review_backlog[35d]))"),
    "finance_import_stale_accounts": (PROM, "max(last_over_time(finance_import_stale_accounts[35d]))"),
    "jobseek_ready": (PROM, 'max(last_over_time(jobseek_applications{stage="ready"}[7d]))'),
    "jobseek_applied": (PROM, 'max(last_over_time(jobseek_applications{stage="applied"}[7d]))'),
    "jobseek_interview": (PROM, 'max(last_over_time(jobseek_applications{stage="interview"}[7d]))'),
    "jobseek_offer": (PROM, 'max(last_over_time(jobseek_applications{stage="offer"}[7d]))'),
    "jobseek_applied_7d": (PROM, 'max(last_over_time(jobseek_applied{window="7d"}[7d]))'),
    "jobseek_days_since_last_application": (PROM, "max(last_over_time(jobseek_days_since_last_application[7d]))"),
    "jobseek_next_action_overdue": (PROM, "max(last_over_time(jobseek_next_action_overdue[7d]))"),
    "evidence_ndcg_at_10_hybrid": (PROM, 'max(last_over_time(evidence_retrieval_ndcg_at_10{system="hybrid"}[30d]))'),
    "claude_cost_usd_day": (PROM, day_total("claude_code_cost_usage_USD_total")),
    "claude_active_hours_day": (PROM, f'({day_total("claude_code_active_time_seconds_total")}) / 3600'),
    # sum(): node_uname_info splits into a new series when the kernel changes.
    "nixpi_reporting_ratio_day": (PROM, 'sum(count_over_time(node_uname_info{instance="nixpi"}[1d])) / 1440'),
    "nixpi_soc_max_c_day": (PROM, 'max(max_over_time(node_thermal_zone_temp{instance="nixpi"}[1d]))'),
    "public_site_success_ratio_day": (PROM, 'avg(avg_over_time(probe_success{job="nixpi-public-site"}[1d]))'),
    "github_security_open_alerts": (PROM, "sum(last_over_time(github_security_open_alerts[2d]))"),
    "grafana_billable_series": (USAGE, "max(max_over_time(grafanacloud_org_metrics_billable_series[1d]))"),
}


def call(url, token, data=None, method=None):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:  # noqa: S310 — fixed https hosts
        return json.loads(r.read() or b"null")


def query(ds, expr, at):
    q = urllib.parse.urlencode({"query": expr, "time": f"{at:.0f}"})
    body = call(f"{os.environ['GRAFANA_URL']}/api/datasources/proxy/uid/{ds}/api/v1/query?{q}",
                os.environ["GRAFANA_TOKEN"])
    res = body.get("data", {}).get("result", [])
    return round(float(res[0]["value"][1]), 6) if res else None


def cell_date(v):
    # A date cell read UNFORMATTED is the RAW string written ("2026-11-02"), or a serial
    # number if someone retyped it in the Sheet; only the string form can match.
    return str(v).strip()[:10] if v not in (None, "") else ""


def merge_row(existing, header, row):
    """The row to write: the existing cells, with only this run's KPIs overwritten.

    Columns missing from `row` (a retired KPI) keep their old value. A KPI that came
    back None keeps an old value too, so a failed re-run never blanks a good cell.
    """
    line = list(existing) + [""] * (len(header) - len(existing))
    for i, col in enumerate(header):
        if col in row and row[col] is not None:
            line[i] = row[col]
    return line


def main():
    day = dt.date.fromisoformat(os.environ["ROLLUP_DATE"]) if os.environ.get("ROLLUP_DATE") \
        else dt.datetime.now(dt.timezone.utc).date() - dt.timedelta(days=1)
    at = dt.datetime.combine(day + dt.timedelta(days=1), dt.time(0), dt.timezone.utc).timestamp() - 1
    row = {"date": day.isoformat()}
    empty = []
    for name, (ds, expr) in KPIS.items():
        try:
            row[name] = query(ds, expr, at)
        except Exception as e:  # noqa: BLE001 — one bad KPI must not lose the row
            row[name] = None
            print(f"grafana-rollup: {name}: {type(e).__name__}", file=sys.stderr)
        if row[name] is None:
            empty.append(name)

    sheets = f"https://sheets.googleapis.com/v4/spreadsheets/{os.environ['SHEET_ID']}/values"
    gtok = os.environ["GOOGLE_ACCESS_TOKEN"]
    # UNFORMATTED: the merge writes old cells back RAW, so a formatted read would turn
    # every number into text, and a date's display format would stop it matching.
    current = call(f"{sheets}/A1:ZZ?majorDimension=ROWS&valueRenderOption=UNFORMATTED_VALUE",
                   gtok).get("values", [])
    header = current[0] if current else []
    for col in row:
        if col not in header:
            header.append(col)
    dates = [cell_date(r[0]) if r else "" for r in current[1:]]
    if row["date"] in dates:
        target = dates.index(row["date"]) + 2
        existing = current[target - 1]
    else:
        target, existing = (len(current) + 1 if current else 2), []
    line = merge_row(existing, header, row)
    rng = urllib.parse.quote("A1:ZZ1")
    call(f"{sheets}/{rng}?valueInputOption=RAW", gtok, json.dumps({"values": [header]}).encode(), "PUT")
    rng = urllib.parse.quote(f"A{target}:ZZ{target}")
    call(f"{sheets}/{rng}?valueInputOption=RAW", gtok, json.dumps({"values": [line]}).encode(), "PUT")
    print(f"grafana-rollup: {day} -> row {target}: {len(KPIS) - len(empty)}/{len(KPIS)} KPIs"
          + (f"; empty: {', '.join(empty)}" if empty else ""))


if __name__ == "__main__":
    main()
