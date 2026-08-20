#!/usr/bin/env node
/**
 * SessionStart digest for Claude Code's own routing telemetry.
 *
 * Mirrors superhook-digest.js: surfaces UNREVIEWED claude_code.tool_decision
 * events whose `source` is user_temporary/user_permanent — i.e. tool-routing
 * decisions a human still had to approve in the moment, rather than a
 * PreToolUse hook or static config — into context at session start, so the
 * "should this become a deterministic hook?" backlog stays visible instead
 * of requiring a manually-remembered /routing-review.
 *
 * The local OTel Collector (services.claudeOtel, modules/shared/claude-otel.nix)
 * writes one JSON line per OTLP logs export batch to
 * ~/.local/state/claude-otel/events.jsonl. Each line is a full OTLP LogsData
 * object: resourceLogs[].scopeLogs[].logRecords[], each record's attributes[]
 * an array of {key, value: {stringValue|...}} pairs — NOT a flat record.
 *
 * The /routing-review command writes a top-level "reviewedAt" ISO timestamp
 * into .claude/hooks/.routing-review-state.json; events at or before that
 * are considered seen.
 *
 * NUDGE_THRESHOLD is a provisional placeholder (no real usage data existed
 * when this was written, 2026-08-20) — retune once a few weeks of real
 * sessions show the actual volume of user_temporary/user_permanent decisions.
 *
 * This is a read-only reporter: it NEVER throws, NEVER blocks, and always
 * exits 0. Stdout from SessionStart is shown to the user and added to context.
 */

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

const NUDGE_THRESHOLD = 3;
const RELEVANT_SOURCES = new Set(["user_temporary", "user_permanent"]);
const MAX_DETAIL = 120;

const truncate = (s) => {
  const str = String(s == null ? "" : s).replace(/\s+/g, " ").trim();
  return str.length > MAX_DETAIL ? `${str.slice(0, MAX_DETAIL - 1)}…` : str;
};

const attrsToMap = (attributes) => {
  const map = {};
  for (const a of attributes || []) {
    if (!a || typeof a.key !== "string" || !a.value) continue;
    const v = a.value;
    map[a.key] = v.stringValue ?? v.intValue ?? v.boolValue ?? v.doubleValue ?? "";
  }
  return map;
};

const nanoToIso = (timeUnixNano) => {
  try {
    const ms = BigInt(timeUnixNano) / 1000000n;
    return new Date(Number(ms)).toISOString();
  } catch {
    return "";
  }
};

try {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const hooksDir = path.join(projectDir, ".claude", "hooks");
  const statePath = path.join(hooksDir, ".routing-review-state.json");
  // Same CLAUDE_OTEL_EVENTS_FILE override as packages/claude-otel-doctor.nix —
  // both are generic, non-Nix-templated consumers of services.claudeOtel's
  // eventsFile default and need to agree if it's ever overridden.
  const eventsPath =
    process.env.CLAUDE_OTEL_EVENTS_FILE ||
    path.join(os.homedir(), ".local", "state", "claude-otel", "events.jsonl");

  let logRaw = "";
  try {
    logRaw = fs.readFileSync(eventsPath, "utf8");
  } catch {
    process.exit(0); // no telemetry yet — nothing to report
  }
  if (!logRaw.trim()) process.exit(0);

  let reviewedAt = null;
  try {
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    if (state && typeof state.reviewedAt === "string") reviewedAt = state.reviewedAt;
  } catch {
    /* missing or malformed state — treat as never reviewed */
  }

  // Flatten every logRecord across every line into {ts, attrs}.
  const records = [];
  for (const line of logRaw.split("\n")) {
    if (!line.trim()) continue;
    let payload;
    try {
      payload = JSON.parse(line);
    } catch {
      continue; // skip unparseable lines
    }
    for (const rl of payload.resourceLogs || []) {
      for (const sl of rl.scopeLogs || []) {
        for (const rec of sl.logRecords || []) {
          records.push({ ts: nanoToIso(rec.timeUnixNano), attrs: attrsToMap(rec.attributes) });
        }
      }
    }
  }

  // Keep unreviewed tool_decision events whose source needed a human.
  const pending = records.filter(({ ts, attrs }) => {
    if (attrs["event.name"] !== "claude_code.tool_decision") return false;
    if (!RELEVANT_SOURCES.has(attrs.source)) return false;
    if (reviewedAt !== null && !(ts && ts > reviewedAt)) return false;
    return true;
  });

  // Below threshold: stay silent (avoids nudging on every single approval).
  if (pending.length < NUDGE_THRESHOLD) process.exit(0);

  // Aggregate by (tool_name, source): count + latest ts + a detail (skill/mcp/command).
  const groups = new Map();
  for (const { ts, attrs } of pending) {
    const toolName = attrs.tool_name || "unknown";
    const source = attrs.source;
    const key = `${toolName} ${source}`;
    let g = groups.get(key);
    if (!g) {
      g = { toolName, source, count: 0, latestTs: "", detail: "" };
      groups.set(key, g);
    }
    g.count += 1;
    if (ts >= g.latestTs) {
      g.latestTs = ts;
      g.detail = attrs.skill_name || attrs.mcp_tool_name || attrs.bash_command || attrs.full_command || "";
    }
  }

  const lines = [
    `routing-review: ${pending.length} tool decision(s) still needed human judgment (user_temporary/user_permanent) since last review:`,
  ];
  const ordered = [...groups.values()].sort((a, b) => (a.latestTs < b.latestTs ? 1 : -1));
  for (const g of ordered) {
    const ts = g.latestTs || "unknown";
    const detail = truncate(g.detail);
    const suffix = detail ? ` — ${detail}` : "";
    lines.push(`  - ${g.toolName}: ${g.count} ${g.source} (latest: ${ts})${suffix}`);
  }
  lines.push("Run /routing-review to find deterministic-routing hardening candidates.");
  process.stdout.write(`${lines.join("\n")}\n`);
  process.exit(0);
} catch {
  // A digest reporter must never wedge SessionStart.
  process.exit(0);
}
