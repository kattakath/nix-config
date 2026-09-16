#!/usr/bin/env node
/**
 * pretooluse-bash-guard.js — deterministic replacement for the former
 * `type: "prompt"` PreToolUse:Bash gate in .claude/settings.json.
 *
 * WHY THIS EXISTS (2026-08-19 incident): the prompt-type gate re-ran a fresh LLM
 * judgment call against a 4-rule natural-language prompt on EVERY single Bash
 * invocation. Three of those four rules are pure syntax (does argv0 match a
 * fixed list?) with zero need for semantic judgment, yet were paying LLM
 * latency (up to 15s) and — because a prompt is re-interpreted from scratch
 * each time with no memoization — inconsistent verdicts on similar commands.
 * It also had NO supervision: unlike every other decision-bearing hook in this
 * repo (Stop -> stop-gate.js), it could not be wrapped by superhook.js for
 * crash-safety/loop-breaking, because Claude Code evaluates prompt-type hooks
 * internally rather than spawning them as a subprocess superhook.js can
 * intercept (see superhook.js's own "Scope note" docstring). That combination
 * — unsupervised, non-deterministic, LLM-latency-per-call — is what made this
 * gate "frequent and annoying" (agent-parent conversation, 2026-08-19): it fired
 * on ordinary read-only lookups (a bare `find` for a settings file; `ls`+`ps`
 * inside an otherwise benign diagnostic one-liner) with no way to predict it in
 * advance and no aggregate visibility into how often it fired or why.
 *
 * FIX: port the same 4 rules to plain string/regex parsing (deterministic, near
 * -instant, fully unit-testable) and route through superhook.js — which already
 * lists "PreToolUse" in its DECISION_EVENTS set and already knows how to parse a
 * `{"decision":"block"|"approve"}` payload from an inner command hook (proven
 * today by the Stop -> stop-gate.js wiring) — so a mis-firing/looping guard here
 * gets the exact same crash-safety and 3-strikes loop-breaker Stop already has,
 * which the old prompt hook structurally could never get.
 *
 * POLICY CHANGE, not just a mechanical port: Rule 3 (desktop-commander) is a
 * TOOL-PREFERENCE nudge, not a safety concern — nothing bad happens if `find`
 * runs directly instead of via the MCP tool. The old hook enforced it as a hard
 * per-call BLOCK anyway, which is the majority of the observed friction. Here it
 * downgrades to a non-blocking systemMessage nudge (RULE3_BLOCKING = false
 * below) — Claude still gets pointed at the MCP tool, but a routine lookup never
 * halts a turn for it. Rules 1/2 (Cloudflare API calls / billed or mutating)
 * keep their hard block: those genuinely warrant stopping. Flip RULE3_BLOCKING
 * to `true` to restore the old hard-block behavior for Rule 3 if preferred.
 *
 * POLICY CHANGE (2026-08-19, izzykatt.ca redirect-rule task): the plain "raw
 * request to api.cloudflare.com" sub-check of Rule 1 downgrades to a
 * non-blocking nudge (RULE1_API_HOST_BLOCKING = false below), same shape as
 * Rule 3. Reason: mcp__cloudflare__execute's OAuth grant was confirmed (live
 * 9109 Unauthorized on both Rulesets and Page Rules writes, even after a full
 * reconnect) to NOT include WAF/Rulesets/Page-Rules write access — a limit of
 * Cloudflare's own official MCP app, not a fixable per-session scope — so the
 * MCP path is a genuine dead end for anything beyond DNS record CRUD. The
 * user holds a correctly-scoped personal CLOUDFLARE_API_TOKEN (Keychain) for
 * exactly these operations and explicitly asked to unblock raw calls after
 * being shown this tradeoff. The terranix apply/destroy check
 * (CF_TERRANIX_APP) and the bare `wrangler` check stay hard-blocked — those
 * mutate broader fleet infra (the nixpi tunnel) sight-unseen, a materially
 * bigger blast radius than one ad-hoc scoped API call. Flip
 * RULE1_API_HOST_BLOCKING to `true` to restore the hard block.
 *
 * RULE 1b IS RETIRED (2026-09-15). It hard-blocked the two live-fleet activations
 * this repo could launch — `deploy` and `darwin-rebuild switch --flake .#macos` —
 * because both reported SUCCESS while dropping the private nix-personal layer or
 * deploying a site-free nixpi. That layer was retired and folded into this repo,
 * so this tree now carries the real data and BOTH commands are the sanctioned
 * ones. The rule, its constants and its `permissions.deny` twin are all gone.
 *
 * RULE 1d REPLACED IT (2026-09-15), inverting what is dangerous: the risk is no
 * longer "which flake activates" but "which machine BUILDS". nixpi is a Pi 4 on
 * an SD card; a power cut mid-build corrupts the card and the fix needs hands on
 * the hardware. So 1d blocks the shapes that build ON the Pi (`--build-host <pi>`,
 * `deploy --remote-build`, `ssh <pi> nix build`, `--builders ssh://<pi>`) and
 * deliberately ALLOWS `--target-host` and `deploy --targets`, which build here and
 * only activate there. CI keeps that possible by warming the closure into Cachix
 * (.github/workflows/warm-nixpi-cache.yml).
 *
 * THIS HOOK IS NOT THE ONLY LAYER, AND MUST NOT BE (2026-09-06 audit). It runs
 * wrapped by superhook.js, whose FIRST job is crash safety: if this script
 * throws, times out, or exits non-zero, superhook emits `{"decision":"approve"}`
 * so the session is never wedged. That is right for a guard whose job is mostly
 * nudges, and it is exactly why a crash is a SILENT DISARM of every rule at once.
 * Measured 2026-09-15: retiring Rule 1b removed its constants but left the code
 * referencing them, and this file threw ReferenceError on EVERY Bash call —
 * approving everything, including the secret-egress block — with no gate noticing.
 * The fix is `.claude/hooks/tests/*.sh`, run by claude-config-lint.yml: each suite
 * asserts the must-BLOCK shapes, the must-stay-APPROVED shapes, AND that the hook
 * does not throw. Add a case there with every rule change.
 *
 * Contract (superhook.js, NOT the raw Claude Code hook protocol, since this
 * always runs wrapped): always exit 0; stdout is
 * `{"decision":"approve"}` or `{"decision":"block","reason":"...","systemMessage":"..."}`.
 * superhook.js re-emits (or loop-breaks) that for the harness.
 *
 * Input: hook JSON on stdin — tool_input.command.
 */
"use strict";
const fs = require("node:fs");

const RULE3_BLOCKING = false; // see POLICY CHANGE above; true = restore old hard block
const RULE1_API_HOST_BLOCKING = false; // see 2026-08-19 POLICY CHANGE above; true = restore hard block

// Rule 4's allowlist — also the Rule 3 exemption set (a raw ls/find/stat/ps/kill
// riding alongside one of these in a compound command is "part of a larger
// approved-CLI script", not someone reaching for a raw tool as their primary).
const APPROVED_CLIS = new Set([
  "git",
  "nix",
  "nix-instantiate",
  "nix-build",
  "nix-store",
  "darwin-rebuild",
  "nixos-rebuild",
  "nixos-install",
  "nixos-enter",
  "home-manager",
  "cloudflared",
  "ssh",
  "scp",
  "sshpass",
  "ssh-keygen",
  "ssh-keyscan",
  "rsync",
  "curl",
  "dig",
  "host",
  "nc",
  "ping",
  "arp",
  "brew",
  "open",
  "osascript",
  "plutil",
  "qemu-img",
  "parted",
  "mkfs.fat",
  "mkfs.ext4",
  "lsblk",
  "blkid",
  "wipefs",
  "udevadm",
  "sudo",
  "statix",
  "deadnix",
  "utmctl",
  "gh",
  "jq",
  "node",
  "python3",
  "bash",
  "zsh",
]);

const DESKTOP_COMMANDER_TOOLS = new Set(["ls", "find", "stat", "ps", "kill"]);

// Rule 1: terranix apply/destroy apps that mutate Cloudflare infra via the API.
//
// Names DRIFT, and this rule drifted into guarding nothing. It used to read
// `cf-(?:tunnel|mcp)-(?:apply|destroy)`: `cf-mcp-*` was real, then was removed
// with the Opera/Kapture MCP servers (6ca8c46), while the terranix family that
// replaced it — `mcp-public-*` — was never added. So the one app this rule most
// needed to catch sailed straight through. Derive this list from `nix flake show`
// when an infra app is added or renamed, not from memory.
//
// `mcp-public-token` is deliberately ABSENT: it is read-only (it prints the
// connector token out of existing state for piping into `secret set`) and
// mutates nothing.
//
// Shape copied from PUBLIC_MACOS_APP below rather than reinvented — it already
// handles the two evasions a bare `\.#` misses: a quoted flake ref, and the
// `github:kattakath/nix-config#…` form that runs the same app without a checkout.
const CF_TERRANIX_APP =
  /\bnix\s+run\s+["']?(?:\.|github:kattakath\/nix-config)#(?:cf-tunnel|mcp-public|hf)-(?:apply|destroy)\b/;

// Rule 1c — the two ways a secret VALUE reaches stdout, and therefore this
// session's transcript. Deliberately WHOLE-COMMAND regexes, not the
// argv0-per-segment `segs` view every other rule uses: measured against five
// evasion shapes, argv0 matching missed three of them — `echo $(secret reveal
// X)`, the backtick form, and a direct `security ... -w` inside a
// substitution — because none of those put the leaking command at a segment's
// argv0. A whole-command match caught 5/5.
//
// `secret reveal` is the CLI's one printing verb (nix-keychain-secrets). It
// exists so printing is deliberate and greppable; this rule is the grep.
// Anchored at COMMAND POSITION — start, or after a separator / substitution
// opener. A bare \bsecret\s+reveal\b matched the literal text ANYWHERE, so
// `git commit -m "...secret reveal..."` and `grep 'secret reveal'` were blocked
// as if they were leaks. This rule blocked its own commit within a minute of
// being written, then blocked the command that tried to fix it — which is the
// argument for command-position anchoring rather than a substring match.
// Every execution shape still matches, substitutions and backticks included.
// The separator must not be BACKSLASH-ESCAPED. A grep alternation inside a
// quoted argument is a regex, not a pipe into a command — and it blocked a
// search for this rule's own call sites. A real pipe is never written escaped.
const CMD_POS = String.raw`(?:^|(?<!\\)[\n;|&(]|\$\(|\x60)\s*`;
// The lookbehind above suppresses a separator preceded by a backslash, so a
// regex alternation (`grep 'a\|secret reveal b'`) is not read as a pipeline.
// On its own that is a BYPASS: in `printf 'a\\' | secret reveal K` the `\\` is
// an escaped backslash and the `|` is a REAL pipe, but the lookbehind sees only
// "backslash, then |" and steps aside. A lookbehind cannot count backslashes.
// So collapse escaped PAIRS to a non-backslash placeholder first; whatever
// backslash survives is genuinely escaping the character after it. Length is
// preserved (two chars in, two out) so reported offsets stay meaningful.
const unescapePairs = (c) => c.replace(/\\\\/g, "  ");
const SECRET_REVEAL = new RegExp(CMD_POS + String.raw`(?:\S*/)?secret\s+reveal\b`);
// The bypass that matters more: the agent does not need the CLI at all.
// `security find-generic-password -w` (or -g) prints the value directly, and
// blocking only `secret reveal` would be security theatre. -w prints the
// password alone; -g prints it to stderr alongside the attributes.
const SECURITY_PRINTS_VALUE = new RegExp(
  CMD_POS + String.raw`(?:\S*/)?security\b[^\n|;&]*\bfind-(?:generic|internet)-password\b[^\n|;&]*(?:\s-w\b|\s-g\b)`,
);
// `switch` vs `build`/`check`/`--dry-run` — only `switch` actually activates.
// Matched per-SEGMENT alongside an `argv0 === "darwin-rebuild"` test rather
// than as one big regex over the whole command, so flag ORDER is irrelevant.
const DARWIN_SWITCH_VERB = /\bswitch\b/;
// Commands that activate something. Used only for the non-blocking Bedrock
// heads-up below — never to block (see § Rule 1b retirement, 2026-09-15: this
// repo now carries its own real data, so activating it is no longer a trap).
const ACTIVATION_ARGV0 = new Set(["darwin-rebuild", "home-manager"]);

// ---- Rule 1d: never BUILD on nixpi (2026-09-15) -----------------------------
// nixpi is a Pi 4 on an SD card. A build there is slow, and a power cut mid-build
// corrupts the card — recoverable only by physically reflashing it
// (docs/nixpi-sd-flashing-runbook.md, ~40 min), which defeats the entire
// remotely-managed design. The Pi must only ever SUBSTITUTE a closure CI already
// built and pushed to Cachix (.github/workflows/warm-nixpi-cache.yml).
//
// This blocks the SHAPES that make the Pi build, and deliberately NOT the ones
// that build elsewhere and only activate there:
//   BLOCKED   nixos-rebuild … --build-host <pi>     (builds ON the Pi)
//   BLOCKED   deploy … --remote-build               (deploy-rs, same effect)
//   BLOCKED   ssh <pi> … nix build / nixos-rebuild  (a build in a remote shell)
//   ALLOWED   nixos-rebuild … --target-host <pi>    (builds HERE, activates there)
//   ALLOWED   deploy --targets .#nixpi              (remoteBuild = false)
// The distinction is the whole point: --target-host is the sanctioned path.
const PI_HOSTS = String.raw`(?:\S+@)?nixpi(?:\.kattakath\.com|\.local)?`;
// --build-host pointing at the Pi, in any spelling (=, space, quoted).
const BUILD_HOST_PI = new RegExp(String.raw`--build-host[=\s]+["']?` + PI_HOSTS + String.raw`\b`, "i");
// deploy-rs' own flag for the same thing.
const DEPLOY_REMOTE_BUILD = /--remote-build\b/;
// `ssh <pi> … nix build|nixos-rebuild|nix-build` — a build dispatched into the Pi.
const SSH_BUILD_ON_PI = new RegExp(
  String.raw`\bssh\b[^\n|;&]*\b` + PI_HOSTS + String.raw`\b[^\n|;&]*\b(?:nix(?:os-rebuild|-build)?\s+build|nixos-rebuild|nix-build)\b`,
  "i",
);
// A remote BUILDER pointed at the Pi (`--builders ssh://…nixpi`, `--store ssh://…`).
const BUILDERS_PI = new RegExp(String.raw`--(?:builders|store)[=\s]+["']?ssh(?:-ng)?://` + PI_HOSTS, "i");

// ---- the Bedrock trap (2026-08-30) -----------------------------------------
// CLAUDE_CODE_USE_BEDROCK lives in the login Keychain, so it SURVIVES any
// activation. Its companions AWS_REGION/AWS_PROFILE come only from the private
// layer (nix-personal's claude-bedrock.nix → ~/.claude/settings.json) and its
// ~/.aws/config profiles, so a public-repo activation DROPS them. Bedrock
// therefore stays selected with no region and no profile: Claude Code can reach
// no model, and the agent needed to undo the activation is the thing that just
// died. settings.json is a read-only /nix store symlink, so it cannot be hand
// repaired — hence chicken-and-egg, and hence a hard block rather than a nudge.
// PRESENCE is the test, not the value: per the operator, merely having the
// variable set selects Bedrock, so `=0` is not a safe "off".
const bedrockSelected = process.env.CLAUDE_CODE_USE_BEDROCK !== undefined;
const awsIdentityLive = ["AWS_REGION", "AWS_PROFILE"].filter((v) => process.env[v]);
// Rule 1/2: an http(s) URL's host, extracted so "cloudflare" merely appearing in
// a path/query on a local host is never mistaken for a real API call. `i` flag:
// schemes are case-insensitive (`HTTP://...` is shell/curl-valid and was
// previously missed — 2026-08-19 push-review finding).
const URL_HOST = /https?:\/\/([^/\s"'<>]+)/gi;
const isLocalHost = (h) => /^(127\.0\.0\.1|localhost|0\.0\.0\.0|\[::1\])(:\d+)?$/i.test(h);
const isCloudflareApiHost = (h) => /^(api\.cloudflare\.com|[^.]+\.[^.]*\bapi\.cloudflare\.com)$/i.test(h) || h.toLowerCase() === "api.cloudflare.com";
const isCloudflareDocsHost = (h) => /(^|\.)developers\.cloudflare\.com$/i.test(h);

function emit(decision, reason, systemMessage) {
  const payload = decision === "block" ? { decision, reason, systemMessage: systemMessage || reason } : { decision };
  process.stdout.write(JSON.stringify(payload));
  process.exit(0);
}

// ---- top-level command segmentation (best-effort, not a full shell parser) ----
// Splits on ;, &&, ||, |, and newlines — matches the granularity the retired
// prompt rule reasoned in ("this AND that", "piped into"). Quoting edge cases
// (a ';' inside a quoted string) are not handled — same limitation the LLM
// version had in practice, and false-negatives here just fall through to the
// Rule-4 default-approve, never a false BLOCK.
//
// UNWRAP `sh -c` FIRST (2026-09-16). Every per-argv0 rule — 1d above all — asks
// "what command is this segment?" and falls through to `default: false` when the
// answer is unknown. An interpreter wrapper makes the answer permanently
// unknown: `bash -c '<anything>'` has argv0 === "bash", so the guard APPROVED a
// build on the Pi's SD card, and would approve every other per-argv0 rule's
// shape too. Rewriting the payload in place BEFORE the split — rather than
// teaching argv0 about `-c` — is what makes a payload containing `&&` segment
// correctly afterwards.
//
// Anchored at CMD_POS, so only a wrapper that would actually RUN is unwrapped.
// Without that anchor a commit message QUOTING the shape starts getting blocked,
// which is the exact regression Rule 1d's per-argv0 gating was written to avoid.
// Not a shell parser: an escaped or nested same-quote inside the payload is not
// handled, and that failure direction is the safe one — no match leaves the
// wrapper intact, i.e. exactly today's default-approve.
const SHELL_DASH_C =
  CMD_POS +
  String.raw`(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S*|sudo|doas|env|exec|nohup|setsid|time|nice)\s+)*` +
  String.raw`(?:\S*/)?(?:ba|z|da|k|a)?sh\s+-[a-zA-Z]*c\s+(['"])([\s\S]*?)\1`;
function unwrapShellC(cmd) {
  let out = cmd;
  // Depth-capped: `bash -c "bash -c '…'"` is two layers; three is generous and
  // guarantees termination whatever the payload looks like.
  for (let d = 0; d < 3; d++) {
    const next = out.replace(new RegExp(SHELL_DASH_C, "gi"), (_m, _q, payload) => `; ${payload} ;`);
    if (next === out) break;
    out = next;
  }
  return out;
}

function segments(cmd) {
  return unwrapShellC(cmd)
    .split(/&&|\|\||[;|\n]/)
    .map((s) => s.trim())
    .filter(Boolean);
}

// Transparent wrappers: each execs the REST of the segment, so the command that
// actually runs is a LATER token, not this one. `env`/`doas`/`nohup`/`setsid`
// were missing, which hid `env nixos-rebuild … --build-host nixpi` from every
// per-argv0 rule for the same reason `bash -c` did.
const TRANSPARENT_WRAPPERS = new Set([
  "sudo",
  "doas",
  "exec",
  "command",
  "time",
  "nice",
  "env",
  "nohup",
  "setsid",
  "stdbuf",
  "ionice",
]);
// Wrapper flags that CONSUME the next token. Skipping the flag but not its value
// leaves argv0 === the username (`sudo -u izzy nix …` -> "izzy"), which falls
// through to default-approve just as silently as the wrapper itself did.
const WRAPPER_FLAGS_WITH_VALUE = new Set(["-u", "--user", "-g", "--group", "-C", "-p", "--prompt"]);

// First real token of a segment: skip leading VAR=val assignments, transparent
// wrappers and those wrappers' own flags; strip any path prefix.
function argv0(segment) {
  const tokens = segment.split(/\s+/);
  let i = 0;
  let sawWrapper = false;
  // ONE loop, not two. `env FOO=1 cmd` interleaves an assignment with a wrapper,
  // and two sequential loops stop at the first token that is not of the kind the
  // loop they are in is scanning for.
  while (i < tokens.length) {
    const tok = tokens[i];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tok)) {
      i++;
      continue;
    }
    // Path-stripped, so `/usr/bin/sudo` is skipped like a bare `sudo`. The old
    // list compared the RAW token, so an absolute path defeated it.
    if (TRANSPARENT_WRAPPERS.has(tok.split("/").pop().toLowerCase())) {
      i++;
      sawWrapper = true;
      continue;
    }
    // Only AFTER a wrapper: a leading `-flag` on the real command is that
    // command's own business, and consuming it would misread argv0.
    if (sawWrapper && tok.startsWith("-")) {
      i += WRAPPER_FLAGS_WITH_VALUE.has(tok) ? 2 : 1;
      continue;
    }
    break;
  }
  const tok = tokens[i] || "";
  return tok.split("/").pop().toLowerCase();
}

function main() {
  let stdin = "";
  try {
    stdin = fs.readFileSync(0, "utf8");
  } catch {
    /* no stdin */
  }
  let payload = {};
  try {
    payload = JSON.parse(stdin);
  } catch {
    emit("approve");
  }
  const cmd = String((payload.tool_input && payload.tool_input.command) || "");
  if (!cmd.trim()) emit("approve");

  // Computed once, reused by both the wrangler check (Rule 1) and the
  // desktop-commander nudge (Rule 3) — argv0() strips path prefixes, so
  // `/opt/homebrew/bin/wrangler` and `./wrangler` are caught the same as a
  // bare `wrangler` (a raw-string regex previously missed both — 2026-08-19
  // push-review finding).
  // rawSegs keeps the FULL text of each segment (Rule 1b needs the flags, not
  // just argv0); segs is the argv0-per-segment view every other rule reasons in.
  // Same index space, so `segs[i]` is `rawSegs[i]`'s command name.
  const rawSegs = segments(cmd);
  const segs = rawSegs.map(argv0);
  const nudges = [];

  // ---- Rule 1: Cloudflare API calls (terranix apply/destroy, wrangler, api.cloudflare.com) ----
  if (CF_TERRANIX_APP.test(cmd)) {
    emit(
      "block",
      "Runs a terranix Cloudflare apply/destroy app, which mutates live infra via the API.",
      "This applies/destroys Cloudflare infra. Use mcp__cloudflare__execute (or __search) instead, or confirm this is intentional and re-run manually.",
    );
  }
  // (Rule 1b RETIRED 2026-09-15 — it blocked `deploy` and public-`#macos`
  // activation because both silently dropped the private nix-personal layer.
  // That layer is gone: this repo carries its own real data, so both commands
  // are now the correct, sanctioned ones. Its constants were deleted with it.)

  // ---- Rule 1d: never BUILD on nixpi ----------------------------------------
  // See the constants above for the full why. Ranked with the blocks because the
  // damage is physical: a power cut during an SD-card build corrupts the card and
  // the fix needs hands on the hardware.
  //
  // Matched PER-SEGMENT and gated on that segment's argv0, never as a substring
  // of the whole command — the same discipline the retired Rule 1b used, and for
  // the same reason: a `git commit -m "…--build-host nixpi…"` or an `echo` that
  // merely MENTIONS the shape must not be blocked. (Measured the day this rule
  // landed: a substring match blocked the very commit that introduced it.)
  {
    const buildsOnPi = rawSegs.some((seg, i) => {
      switch (segs[i]) {
        case "nixos-rebuild":
          return BUILD_HOST_PI.test(seg);
        case "deploy":
          return DEPLOY_REMOTE_BUILD.test(seg);
        case "ssh":
          return SSH_BUILD_ON_PI.test(seg);
        case "nix":
        case "nix-build":
          return BUILDERS_PI.test(seg) || BUILD_HOST_PI.test(seg);
        default:
          return false;
      }
    });
    if (buildsOnPi) {
      emit(
        "block",
        "This builds ON nixpi (a Pi 4 on an SD card). A build there is slow, and a power cut mid-build corrupts the card — which then needs a physical reflash (~40 min, docs/nixpi-sd-flashing-runbook.md) and defeats the remotely-managed design.",
        "The Pi should only SUBSTITUTE. CI warms the whole nixpi closure into Cachix on every closure change (.github/workflows/warm-nixpi-cache.yml), so after that lands use `nixos-rebuild switch --flake .#nixpi --target-host ismail@nixpi.kattakath.com` (builds HERE, activates there) or `deploy --targets .#nixpi`. If the Mac still wants to BUILD instead of fetch, the cache is merely not warm yet — or Nix negatively cached an earlier 404 for up to an hour; retry with `--narinfo-cache-negative-ttl 0` rather than moving the build onto the Pi.",
      );
    }
  }
  // ---- Rule 1c: printing a secret into the transcript ------------------------
  // Ranked with the blocks, not the nudges, for the reason the others are: it
  // succeeds and does its damage silently. A printed secret is not an error —
  // it is a value in a .jsonl that persists for 30 days (cleanupPeriodDays),
  // with no built-in redaction, and `/feedback` uploads that file.
  //
  // This is layer 4 of five, and the weakest of them by construction: superhook
  // FAILS OPEN if this script throws, and an agent with a shell can defeat any
  // in-CLI check (`script -q /dev/null` flips isatty while still capturing).
  // What actually holds is layer 1 (Keychain ACL prompts) and layer 2 (the
  // high-privilege secrets are not ambient at all — `secret unbind`). This rule
  // exists to make a leak LOUD AND DELIBERATE rather than habitual, which is
  // precisely the failure it was written for: three leaks in one session, all
  // from a printing command nobody meant to run.
  //
  // Not a veto. The operator runs either form by hand whenever they want, and
  // `secret reveal` is the right answer when a script genuinely needs the value
  // in its own process (see nix-personal's character-mcp proof scripts).
  // Match against the pair-collapsed form (see unescapePairs) so an escaped
  // BACKSLASH before a real separator cannot hide the command after it.
  const cmdEsc = unescapePairs(cmd);
  if (SECRET_REVEAL.test(cmdEsc) || SECURITY_PRINTS_VALUE.test(cmdEsc)) {
    const via = SECRET_REVEAL.test(cmdEsc) ? "`secret reveal`" : "`security find-generic-password -w/-g`";
    emit(
      "block",
      `${via} prints a secret VALUE to stdout, which lands verbatim in this session's transcript (~/.claude/projects/**.jsonl, kept 30 days, no redaction).`,
      "Use the verb that fits: `secret copy KEY` hands it to the human via a concealed pasteboard; `secret exec KEY -- CMD` puts it only in the child's env; `secret fp KEY` proves which value it is (digest + length + mdat) without disclosing it. If you genuinely need it printed, run it yourself.",
    );
  }
  // A legitimate activation (`activate`, a private-flake switch, `home-manager switch`)
  // is approved — but if the AWS identity vars are live while the Keychain switch
  // is currently OFF, the trap is merely disarmed, not gone: restoring that one
  // Keychain entry re-arms it. Worth one line, never a block.
  if (!bedrockSelected && awsIdentityLive.length) {
    const activates = rawSegs.some(
      (seg, i) => ACTIVATION_ARGV0.has(segs[i]) && (segs[i] === "activate" || DARWIN_SWITCH_VERB.test(seg)),
    );
    if (activates) {
      nudges.push(
        `${awsIdentityLive.join("/")} present but CLAUDE_CODE_USE_BEDROCK unset — Bedrock is currently OFF, so this activation is safe. It re-arms the moment that Keychain entry returns; \`nix-bedrock-gate\` reports the live verdict.`,
      );
    }
  }

  if (segs.includes("wrangler")) {
    emit(
      "block",
      "Direct `wrangler` invocation — a Cloudflare API call (Workers/Pages/D1/KV/R2/Queues).",
      "Use mcp__cloudflare__execute (or __search) for Cloudflare API operations instead of raw wrangler.",
    );
  }
  {
    let m;
    URL_HOST.lastIndex = 0;
    while ((m = URL_HOST.exec(cmd))) {
      const host = m[1].split(/[/:]/)[0];
      if (isLocalHost(m[1])) continue; // local gateway (127.0.0.1:8096/servers/cloudflare/...) is never an API call
      if (host.toLowerCase() === "api.cloudflare.com") {
        const reason = `Direct HTTP request to ${host} — a Cloudflare API endpoint.`;
        if (RULE1_API_HOST_BLOCKING) {
          emit("block", reason, "Use mcp__cloudflare__execute (or __search) instead of a raw request to api.cloudflare.com.");
        }
        // Non-blocking by default (see 2026-08-19 POLICY CHANGE in file header).
        nudges.push(`${reason} (mcp__cloudflare__execute lacks Rulesets/Page-Rules write scope — raw call allowed.)`);
      }
      // ---- Rule 2: Cloudflare docs lookups ----
      if (isCloudflareDocsHost(host)) {
        emit(
          "block",
          `Direct HTTP request to ${host} — a Cloudflare docs lookup.`,
          "Use mcp__cloudflare-docs__search_cloudflare_documentation instead of fetching developers.cloudflare.com directly.",
        );
      }
    }
  }

  // ---- Rule 3: desktop-commander tool-preference nudge ----
  const hasRawTool = segs.some((a) => DESKTOP_COMMANDER_TOOLS.has(a));
  const hasApprovedCli = segs.some((a) => APPROVED_CLIS.has(a));
  if (hasRawTool && !hasApprovedCli) {
    const which = segs.find((a) => DESKTOP_COMMANDER_TOOLS.has(a));
    const nudge = `\`${which}\` used standalone — prefer mcp__desktop-commander__* for file/process listing when convenient.`;
    if (RULE3_BLOCKING) {
      emit("block", nudge, nudge);
    }
    nudges.push(nudge);
  }

  // ---- Rule 4: default approve (with any accumulated non-blocking nudges) ----
  if (nudges.length) {
    process.stdout.write(JSON.stringify({ decision: "approve", systemMessage: nudges.join(" | ") }));
    process.exit(0);
  }
  emit("approve");
}

try {
  main();
} catch (e) {
  // Never let a bug here wedge the session — superhook.js also crash-safes this,
  // but fail open locally too.
  process.stdout.write(JSON.stringify({ decision: "approve", systemMessage: `pretooluse-bash-guard error (ignored): ${String(e && e.message)}` }));
  process.exit(0);
}
