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
  const segs = segments(cmd).map(argv0);

  // ---- Rule 1: Cloudflare API calls (terranix apply/destroy, wrangler, api.cloudflare.com) ----
  if (CF_TERRANIX_APP.test(cmd)) {
    emit(
      "block",
      "Runs a terranix Cloudflare apply/destroy app, which mutates live infra via the API.",
      "This applies/destroys Cloudflare infra. Use mcp__cloudflare__execute (or __search) instead, or confirm this is intentional and re-run manually.",
    );
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
        emit(
          "block",
          `Direct HTTP request to ${host} — a Cloudflare API endpoint.`,
          "Use mcp__cloudflare__execute (or __search) instead of a raw request to api.cloudflare.com.",
        );
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
    // Non-blocking by default (see POLICY CHANGE in file header): approve, but
    // still surface the nudge to Claude via systemMessage.
    process.stdout.write(JSON.stringify({ decision: "approve", systemMessage: nudge }));
    process.exit(0);
  }

  // ---- Rule 4: default approve ----
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
