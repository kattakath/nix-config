# The RDK-B gateway contract (Rogers CGM4981)

The household's internet comes through a **Technicolor CGM4981** — Rogers' "Ignite"
gateway, the Comcast XB8's sibling. When it fails, `nixpi` goes with it
(`docs/repo-map.md` § nixpi), so being able to *ask the gateway questions* without
clicking a GUI is operationally useful.

This file records the gateway's **HTTP contract**: how to authenticate, how the
session and CSRF token work, which endpoints exist, and how responses are encoded.

**It is a contract, not a tool.** The contract is the durable artifact — endpoints,
enums, field names and lockout semantics survive; a script that wraps them rots on
the next firmware push. Read this before writing anything that talks to the gateway.

## Why this can be cited rather than guessed

The firmware's web UI is **open source**: [`rdkcentral/webui`](https://github.com/rdkcentral/webui),
Apache-2.0, actively developed. It is not a cousin of our device's UI — it **is**
our device's UI. Our exact model string is branched on by name:

```
source/Styles/xb3/jst/check.jst:128
  if (($modelName == "CGM4140COM") || ($modelName == "CGM4331COM")
      || ($modelName == "CGM4981COM") || ...)
```

`CGM4981COM` appears a further 11 times across `xb3/` and `xb6/`. Note the tree
layout: `xb6/` is a small **overlay** on the full `xb3/` base, so a file living only
under `xb3/` (such as `check.jst`) is still the file XB6/XB7/XB8 run — xb6 simply
does not override it.

Every citation below is `file:line` in that repo, verified against a clone of
`develop`. Where upstream and our measured behaviour disagree, the table at the
bottom says so explicitly.

## Identity and authentication

`POST /check.jst` — form fields `username`, `password`, `locale`
(`source/Styles/xb3/jst/index.jst:373,381,385,358`).

Two accounts exist, mapped to TR-181 objects (`check.jst:135-160`):

| Login | TR-181 object | Reachable from |
|---|---|---|
| `admin` | `Device.Users.User.3` | LAN only — rejected from `cm_ip` (`check.jst:304`) |
| `mso` | `Device.Users.User.1` | operator side only — rejected from `lan_ip` (`check.jst:141`) |

Password check is `Device.Users.User.3.X_RDKCENTRAL-COM_ComparePassword`
(`check.jst:319`).

> **The `cm_ip` / `lan_ip` split is a lead, not a curiosity.** The firmware
> distinguishes a cable-modem-side interface from the LAN side. The customer UI we
> can reach is the LAN side only, which is why its logs carry no DOCSIS tier. Do not
> conclude "the gateway exposes no WAN diagnostics" from the LAN UI alone.

### ⚠ The lockout counter is server-side and persisted

`check.jst:111-115` reads `Device.UserInterface.PasswordLockoutEnable`,
`…PasswordLockoutAttempts` and `…PasswordLockoutTime`; `check.jst:215-224`
increments and **persists** `Device.Users.User.{1,3}.NumOfFailedAttempts` on every
failed attempt.

**A retry loop against `check.jst` can lock the household out of its own gateway.**
Any automated client must fail fast on bad credentials, never retry them. It
increments on *failure* only, so a succeeding client never feeds it.

### ⚠ Do not fuzz the login endpoint

Published 2026-08: multiple RDK-B WebUI vulnerabilities, including a **`check.jst`
DoS via oversized password** and a **heap overflow in the multipart parser**
([whitehats.pwr.edu.pl](https://whitehats.pwr.edu.pl/blog/2026-08-19-multiple-vulnerabilities-in-rdkb/)).
Send well-formed credentials once. Do not probe, fuzz or stress this endpoint — it
is the front door of a live household's internet.

## Session lifetime is a formula

```
check.jst:710-714
  $timeout_val = intval(getStr("Device.X_CISCO_COM_DeviceControl.WebUITimeout"));
  ("" == $timeout_val) && ($timeout_val = 900);
  $_SESSION["timeout"] = $timeout_val - 60;
```

Default **840 s**. Enforcement is **client-side only** — `includes/userbar.jst:166`
turns it into a JS inactivity timer. A headless client that keeps hitting an
authenticated page keeps the PHP session alive, so session reuse is viable and
re-login per request is unnecessary.

The session cookie is `HttpOnly` (invisible to `document.cookie`); a cookie jar
handles it.

## CSRF

The UI inlines a per-session token into page HTML and sends it as a **request
header**:

```
source/Styles/xb3/jst/troubleshooting_logs.jst:220
  var token = "<?% echo( $_SESSION['Csrf_token'] );?>";
source/Styles/xb3/jst/troubleshooting_logs.jst:240-243
  url:"actionHandler/ajax_troubleshooting_logs.jst",
  data:{mode:mode,timef:timef},
  headers: { csrfp_token: token },
```

The implementation is a vendored community library — mebjas **CSRF-Protector-PHP**
(`csrfprotector.jst:4` defines `CSRFP_TOKEN = "csrfp_token"`; `:222` emits
`X-CSRF-Protection: OWASP CSRFP 1.0.0`). `csrfprotector.jst:428-436` also sets it as
an `HttpOnly` cookie.

**Upstream says GET requires no token at all**: `verifyGetFor` is empty
(`csrfprotector.jst:173`), so `isURLallowed()` returns true and `authorizePost()`
skips the GET branch entirely (`:238`, `:609`). Upstream's `getTokenFromRequest()`
(`:285`) reads `$_POST` only — the header-reading block is commented out.

So on upstream, the header we send is read by nobody, and the token scrape is
unnecessary for reads. **This is not confirmed on our box** (see table) — keep
sending it until measured; it is harmless.

## Endpoints

### JSON

```
GET /actionHandler/ajax_troubleshooting_logs.jst?mode=<MODE>&timef=<WINDOW>
```

`ajax_troubleshooting_logs.jst:63-64` reads both from `$_GET`.

- `MODE` — `system` | `event` | `firewall`
- `WINDOW` — `Today` | `Yesterday` | `Last week` | `Last month` | `Last 90 days`
  (`:67-90`; anything else hits `default: throw Error('Invalid timeframe')`)

Response shapes:

| Mode | Fields | Cite |
|---|---|---|
| `system`, `event` | `time`, `Level`, `Des` | `:113`, `:146` |
| `firewall` | `time`, `Des`, `Count`, `Target`, `Source`, `Type` | `:182` |

`Target` and `Source` are in the firewall shape but were never seen in our captures.

`actionHandler/ajaxSet_userbar.jst` also exists.

**Unauthenticated requests do not return JSON** — `ajax_troubleshooting_logs.jst:20-24`
emits an HTML `alert("Please Login First!")` plus a redirect. Detect auth failure by
parsing, never by status code (see below).

### Pages

`.jst` pages observed and present upstream: `at_a_glance`, `connection_status`,
`connected_devices_computers`, `network_setup`, `troubleshooting_logs`, `software`,
`hardware`, `port_forwarding`, `wifi`, `lan`, `wan_network`, `moca`, `battery`,
`device_discovery`, `dmz`, `managed_sites`, `parental_reports`.

`POST /troubleshooting_logs_download.jst` — fields `log_type`, `time_frame`.

## Encoding: why entity depth varies per page

Each branch ends:

```
header("Content-Type: application/json");
echo( htmlspecialchars(json_encode($sysLog), ENT_NOQUOTES, 'UTF-8') );
```

`htmlspecialchars` runs over the **already-serialised JSON string**, so any `&`
already inside a log line gains another layer. Depth varies because the number of
`htmlspecialchars` calls differs per file:

| File | calls |
|---|---|
| `at_a_glance.jst` | 9 |
| `connected_devices_computers.jst` | 6 |
| `connection_status.jst` | 5 |
| `ajax_troubleshooting_logs.jst` | 3 |

**Measured depth is lower than that suggests.** Re-tested 2026-09-23 against a real
55,590-byte authenticated capture of `troubleshooting_logs.jst`: after stripping tags,
the body carries **3** entity references and **one** decode pass clears all of them.
An earlier claim in this file of "status ~2 deep, logs ~3 deep" did not reproduce and
has been withdrawn.

The mechanism above still matters: the call counts are real, they differ per file, and
a payload can arrive multiply-escaped. But do not infer a specific depth from them —
measure the endpoint you are actually reading. `rogers-gw` decodes twice, which is one
more pass than anything observed and still bounded.

**Decoding to a fixpoint is therefore unsafe in general**: it cannot distinguish a
server-applied layer from entity text that was genuinely in the data. A device
hostname is attacker-chosen (any LAN client picks its own DHCP name), so
over-decoding is reachable. Decode a bounded number of times, per endpoint, or
decode once and accept residue.

## Traps measured on the live device

- **Every `.jst` returns HTTP 200**, authenticated or not; the unauthenticated
  response is a byte-identical login wall (`md5` matched across three different
  pages). Status codes carry no auth signal — inspect content.
- **"Show Logs" fires no request.** It is pure client-side `show()`/`hide()`; the
  rows come from the JSON endpoint above. Fetching the page alone yields an empty
  table forever.
- **Only ports 80, 443, 53 are open.** SSH (22) and telnet (23) are closed; SNMP
  (161) does not answer `public` or `private`. There is no CLI on this device.
- **The device clock is `UTC-5` and does not follow DST.** Its log timestamps are
  local; correlate against UTC before drawing conclusions.

## Confirmed vs unconfirmed

| Claim | Source | Status on CGM4981 |
|---|---|---|
| `POST /check.jst` with `username`/`password`/`locale` | upstream + measured | **confirmed** |
| `admin` = `Device.Users.User.3` | upstream | **confirmed** (login works) |
| JSON endpoint, params, 5 windows, field names | upstream + measured | **confirmed** |
| `var token` scrape → `csrfp_token` header | upstream + measured | **confirmed working** |
| GET needs no CSRF token | upstream `csrfprotector.jst:173,238,609` | **UNCONFIRMED** — not tested by omitting it |
| Header form ignored; `$_POST` only | upstream `:285` | **UNCONFIRMED** — our header-bearing GETs succeed, consistent with GET simply not being verified |
| Session timeout 840 s, client-enforced | upstream `check.jst:710-714` | **UNCONFIRMED** |
| Lockout counter persists on failure | upstream `check.jst:111-115,215-224` | **UNCONFIRMED — and must not be tested** |
| `firewall` rows carry `Target`/`Source` | upstream `:182` | **UNCONFIRMED** — never observed |
| A `cm_ip`-side interface exists | upstream `check.jst:141,304` | **UNCONFIRMED** — never probed |

## What this means for tooling

**Do not build monitoring on this gateway.** The customer-facing event log is
`OneWifi`-only — no WAN or DOCSIS tier — so the payload does not justify the auth,
CSRF and session machinery, and the substrate is leased hardware whose local admin
UI the vendor is progressively gating behind its app.

For "is the internet up?", the fleet already has a strictly better signal: the
**Cloudflare tunnel to `nixpi`** (`infra/cloudflare/nixpi-tunnel.nix`). Tunnel down
*is* WAN down, it is already declared, Cloudflare already notifies, and it observes
from **outside the house** — so the alert can escape when the gateway cannot.

This contract is for **ad-hoc inspection**: asking the gateway a question when
something is already wrong.
