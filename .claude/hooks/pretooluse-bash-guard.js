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
 * NEW RULE (2026-08-30, deploy-rs adoption review): Rule 1b hard-blocks the two
 * LIVE-FLEET ACTIVATIONS that this public repo can launch and that both report
 * SUCCESS while doing damage — `deploy` (deploy-rs; the node here points at the
 * SITE-FREE nixpi, and magic rollback only reverts an UNREACHABLE host) and
 * `darwin-rebuild switch --flake .#macos` (drops the private nix-personal layer).
 * Both traps were already documented loudly in CLAUDE.md/README/flake.nix, but
 * documentation is not a brake, and adding the `deploy` CLI to the darwin devShell
 * is what first put one of them on PATH. Same tier as CF_TERRANIX_APP.
 *
 * Contract (superhook.js, NOT the raw Claude Code hook protocol, since this
 * always runs wrapped): always exit 0; stdout is
 * `{"decision":"approve"}` or `{"decision":"block","reason":"...","systemMessage":"..."}`.
 * superhook.js re-emits (or loop-breaks) that for the harness.
 *
 * Input: hook JSON on stdin — tool_input.command (same shape pretooluse-log.js
 * already reads).
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
const CF_TERRANIX_APP = /\bnix\s+run\s+\.#cf-(?:tunnel|mcp)-(?:apply|destroy)\b/;
// Rule 1b (2026-08-30 review): the activation shapes that are a trap.
// Matched per-SEGMENT alongside an `argv0 === "darwin-rebuild"` test rather than
// as one big regex over the whole command, so flag ORDER is irrelevant
// (`darwin-rebuild --flake .#macos switch` reads the same as the canonical form)
// and a `.#macos` merely mentioned in a neighbouring `git`/`echo` segment can
// never trigger it. `build`/`check`/`--dry-run` shapes stay approved — they do
// not activate.
const DARWIN_SWITCH_VERB = /\bswitch\b/;
// Every flake-ref shape that resolves to THIS public tree's `#macos`. The original
// rule matched only the canonical `--flake .#macos`, which let four equivalent
// spellings straight through (2026-08-30 Bedrock review):
//   `--flake .`            — no attr, so nix-darwin resolves it by hostname → #macos
//   `--flake ~/…/nix-config` / an absolute path to this checkout
//   `--flake github:kattakath/nix-config#macos` — the remote is the same tree
// The attr is `(?:#macos)?` — either spelled out or absent (nix-darwin then
// resolves it by hostname, which on this Mac IS macos). Deliberately NOT a
// wildcard `#[\w-]*`: that would also swallow `--flake .#macvm`, a different host
// whose activation this rule has nothing to say about, and would attach a message
// naming the wrong composition. A trailing `(?=…)` guard keeps `../nix-personal`
// and longer path suffixes out.
const PUBLIC_MACOS_REFS = [
  /--flake[=\s]+\.(?:#macos)?(?=\s|$|["';|])/,
  /--flake[=\s]+["']?[~/][^\s"';|]*nix-config(?:#macos)?(?=\s|$|["';|])/i,
  /--flake[=\s]+["']?github:kattakath\/nix-config(?:#macos)?(?=\s|$|["';|])/i,
];
// `--flake` absent entirely: a bare `darwin-rebuild switch` re-activates whatever
// flake the current system profile recorded — unknowable from here, so it is
// treated as suspect rather than assumed safe. `activate` is the sanctioned entry
// point either way, so this costs nothing legitimate.
const HAS_FLAKE_FLAG = /--flake\b/;
// `nix run .#macos` is a REAL activation app (apps.aarch64-darwin.macos, the
// first-activation path from CLAUDE.md § Build & Commands) — same damage as
// `darwin-rebuild switch`, and it was never covered.
const PUBLIC_MACOS_APP = /\bnix\s+run\s+["']?(?:\.|github:kattakath\/nix-config)#macos\b/;
// Commands that activate SOMETHING but are not the public-repo trap: `activate`
// (the freshness-gated private composition CLI from nix-personal) and a
// `home-manager switch`. Used only for the non-blocking Bedrock heads-up below —
// never to block.
const ACTIVATION_ARGV0 = new Set(["activate", "darwin-rebuild", "home-manager"]);

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
function segments(cmd) {
  return cmd
    .split(/&&|\|\||[;|\n]/)
    .map((s) => s.trim())
    .filter(Boolean);
}

// First real token of a segment: skip leading VAR=val env assignments and a
// leading `sudo`/`exec`/`command`/`time`/`nice` wrapper, strip any path prefix.
function argv0(segment) {
  const tokens = segment.split(/\s+/);
  let i = 0;
  while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i])) i++;
  while (i < tokens.length && ["sudo", "exec", "command", "time", "nice"].includes(tokens[i])) i++;
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
  // ---- Rule 1b: live-fleet activation launched from THIS public repo ----------
  // Ranked with the terranix apply block, not with the Rule 3 nudges, because
  // both of these SUCCEED and do their damage silently — nothing downstream
  // reports failure:
  //   `deploy` — the deploy-rs CLI now ships in the darwin devShell, so it is on
  //     PATH for the first time. `deploy.nodes.nixpi` in THIS repo points at the
  //     SITE-FREE public `nixosConfigurations.nixpi` (`hostedSites` defaults to
  //     `[ ]`), so a deploy from this tree hands the live Pi a Caddy with zero
  //     vhosts — every site goes dark while sshd and the primary tunnel stay up.
  //     deploy-rs reports SUCCESS, and magicRollback cannot save it: rollback
  //     fires only for an UNREACHABLE host, and a site-free Pi is reachable.
  //     Worse, a bare `deploy` with no `--targets` fans out over EVERY node
  //     (upstream `src/cli.rs` defaults the target to `.`), so the argument-less
  //     form IS a live-Pi deploy. Blocked in every shape, `--dry-activate`
  //     included: that still copies a closure to the live Pi, and the whole point
  //     is that the RIGHT flake to deploy from is nix-personal, not this one.
  //   `darwin-rebuild switch --flake .#macos` — silently drops the private
  //     nix-personal layer (CLAUDE.md § Important Notes). `activate` is the real entry.
  // Neither block is a veto — the operator can still run either by hand.
  if (segs.includes("deploy")) {
    emit(
      "block",
      "`deploy` (deploy-rs) from this public repo targets the SITE-FREE nixosConfigurations.nixpi — a successful deploy dark-sites the live Pi and magic rollback cannot catch it.",
      "Deploy from the private nix-personal flake, not this one. A bare `deploy` also fans out over every node — always `--targets`. Confirm intent and run it manually if this really is what you want.",
    );
  }
  // Activation of the public `#macos` in any of its spellings, plus the bare
  // no-`--flake` form. `build`/`check`/`--dry-run` shapes still fall through —
  // they do not activate.
  const darwinSwitchSegs = rawSegs.filter((seg, i) => segs[i] === "darwin-rebuild" && DARWIN_SWITCH_VERB.test(seg));
  const publicMacosActivation =
    PUBLIC_MACOS_APP.test(cmd) || darwinSwitchSegs.some((seg) => PUBLIC_MACOS_REFS.some((re) => re.test(seg)));
  const bareDarwinSwitch = darwinSwitchSegs.some((seg) => !HAS_FLAKE_FLAG.test(seg));
  if (publicMacosActivation || bareDarwinSwitch) {
    const what = publicMacosActivation
      ? "Activates the PUBLIC `#macos` composition from this repo"
      : "A bare `darwin-rebuild switch` re-activates whatever flake the system profile recorded — it may well be this public tree";
    // Two different severities, because the consequences differ in kind: with the
    // Bedrock switch live this destroys the operator's own AI access, so the
    // message has to lead with the recovery path, not with the layering theory.
    emit(
      "block",
      bedrockSelected
        ? `${what}, which drops the private nix-personal layer — including AWS_REGION/AWS_PROFILE. CLAUDE_CODE_USE_BEDROCK is set in this environment and lives in the Keychain, so it SURVIVES: Bedrock would stay selected with no region, Claude Code would reach no model, and settings.json is a read-only /nix symlink you cannot hand-repair. That is the chicken-and-egg outage.`
        : `${what}, which silently drops the private nix-personal layer (CLAUDE.md § Important Notes).`,
      bedrockSelected
        ? "Use `activate` (nix-personal's freshness-gated CLI for the private composition) — it restores AWS_REGION/AWS_PROFILE in the same switch. If you must run the public one, `secret rm CLAUDE_CODE_USE_BEDROCK` FIRST and open a new shell, so Claude Code falls back to its default provider and survives. `darwin-rebuild build` is always safe."
        : "Use `activate` (nix-personal's CLI for the private composition), or ask first. `darwin-rebuild build --flake .#macos` is fine for verification.",
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
