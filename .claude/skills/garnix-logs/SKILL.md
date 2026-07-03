---
name: garnix-logs
description: >
  Fetch, read, grep, or download a Garnix CI build log headlessly (no browser) to diagnose a
  failing Garnix check. Use when the user (or Claude) needs to inspect an app.garnix.io/build/<id>
  failure, read a Garnix build log, tail a CI log for a red status check, or grep build output for
  an error. Garnix is this repo's CI (garnix.yaml). Runs garnix-log.sh <build-id> against the
  Garnix API using a session JWT read from the GARNIX_JWT_COOKIE env var.
---

# garnix-logs — fetch Garnix CI build logs via curl

Garnix (https://garnix.io) is this repo's sole multi-system CI (see `garnix.yaml`). It builds each
flake output on native builders and reports one GitHub status check per output. When a check goes
red, use this skill to pull the build log headlessly instead of opening a browser.

## How to use

1. **Resolve the build ID.** Garnix status rows link to `https://app.garnix.io/build/<id>`. Find
   them from a PR with:

   ```bash
   gh pr checks <pr-number>
   ```

   The Garnix rows carry `app.garnix.io/build/<id>` links — take the `<id>` (the script also
   accepts the full URL and extracts it).

2. **Fetch the log:**

   ```bash
   .claude/skills/garnix-logs/garnix-log.sh <build-id>          # raw plaintext (default)
   .claude/skills/garnix-logs/garnix-log.sh <build-id> json     # structured JSON
   ```

   Pipe raw output to `grep` to isolate errors, e.g. `... | grep -i error`. ANSI color codes are
   already stripped from raw output for clean grepping.

## Auth — GARNIX_JWT_COOKIE (required)

The script reads the Garnix session JWT from the `GARNIX_JWT_COOKIE` env var and sends it only as a
cookie. The token is never hardcoded, printed, or written to disk.

If it's unset or expired, the script exits without leaking anything and prints guidance. Provide the
token in-session (it is not persisted):

```bash
! export GARNIX_JWT_COOKIE='<paste JWT-Cookie value here>'
```

Obtain the value from a logged-in app.garnix.io session: copy the `JWT-Cookie` cookie
(browser DevTools → Application/Storage → Cookies, or the `Cookie` header of any
`/api/build/*/logs` request). The JWT expires — re-export it when fetches start failing.

## Endpoints & exit codes

- `raw` → `GET /api/build/<id>/logs/raw` — clean plaintext (preferred).
- `json` → `GET /api/build/<id>/logs` — `{"finished":bool, …, "logs":[{"timestamp":…,"log_message":…}]}`; pretty-printed via `jq` when available.
- Exit `3` — `GARNIX_JWT_COOKIE` unset/empty (no request made).
- Exit `4` — request failed (non-200, empty, or a login page); token likely expired.
