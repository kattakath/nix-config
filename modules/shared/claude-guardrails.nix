{ pkgs, lib, ... }:
# The GLOBAL guardrail floor for Claude Code — user-scope `permissions.deny`
# that applies in EVERY repo on this Mac, not just this one.
#
# WHY THIS EXISTS. Every decision hook this fleet runs (`pretooluse-bash-guard`,
# `stop-gate`, the Write|Edit secret prompt, the mcpfinder deny) lives in THIS
# repo's `.claude/settings.json` — project scope. A session anywhere else (a work
# repo, `~`) got none of it, while the VS Code extension and the `claude`
# terminal profile start in `bypassPermissions` (home.nix). The MCP gateway, by
# contrast, IS global: `mcpfinder` is wired into every session through
# `programs.claude-code.mcpServers`, so its config-writing tool was deny-listed
# here and callable everywhere else. Measured 2026-09-15.
#
# UPSTREAM FIRST. `programs.claude-code.settings` is `jsonFormat.type`
# (home-manager 87c391f, modules/programs/claude-code/options.nix) — freeform,
# and module-system list merging concatenates `permissions.deny` across modules,
# so this file ADDS to whatever else sets it. Its own example block shows
# `permissions.deny`. No hook, no script, no activation step: Claude Code
# enforces deny rules itself, in every permission mode — `bypassPermissions`
# skips PROMPTS, and a deny is not a prompt.
#
# WHAT A DENY RULE IS NOT. Claude Code's docs are explicit that a Bash deny
# "isn't a security boundary around the program": it matches the command text
# Claude writes (compound commands and `$(…)` included) but not `/usr/bin/x` or
# `sh -c 'x'`. This is a FLOOR against the common, accidental shape — the
# project-scoped superhook guard stays the deeper, tested layer in this repo.
#
# THE TWO mcpfinder RULES ARE ALSO IN `.claude/settings.json`, ON PURPOSE — that
# is not duplication to clean up. This file is materialised by Home Manager into
# ~/.claude, which the devcontainer deliberately does NOT mount (.devcontainer/
# devcontainer.json: "No volume for ~/.claude (deliberate — don't re-add one)").
# Inside that container, and in any clone on a machine this HM config never
# touched, the checked-in project copy is the only floor there is.
#
# SCOPE RULE for adding an entry: it must be a FLEET-WIDE policy already written
# down somewhere (claude/CLAUDE.md, mcp-scout, CLAUDE.md § Security), and wrong
# in every repo. Repo-specific policy (Cloudflare scoping, nixpi builds) stays in
# that repo's `.claude/`. Escape hatch for the operator: run it yourself — a
# `!`-prefixed command in the prompt, or a normal terminal.
#
# Paths: `~/` anchors at $HOME and `//` at the filesystem root. A single leading
# `/` in USER settings anchors at ~/.claude, not `/` — the classic miswrite.
#
# Top-level `lib.mkIf isDarwin`, matching ./claude-brain.nix: programs.claude-code
# is darwin-only (home.nix), and the gate keeps nixpi/nixvm byte-identical.
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  programs.claude-code.settings.permissions.deny = [
    # ── Imperative MCP adoption (mcp-scout: "installation IS declaration") ──
    # The gateway is the single MCP source; a runtime add lands in ~/.claude.json,
    # outside flake.lock, Cachix and the public ⊆ hosted assertion (ADR-003 §5).
    # Both tool-name spellings: the HM-managed plugin prefix is what sessions see.
    "mcp__plugin_claude-code-home-manager_mcpfinder__add_mcp_server_config"
    "mcp__mcpfinder__add_mcp_server_config"
    "Bash(claude mcp add *)"
    "Bash(claude mcp add-json *)"
    "Bash(claude mcp add-from-claude-desktop *)"
    "Edit(~/.claude.json)"

    # ── Secret VALUES reaching the transcript (claude/CLAUDE.md § Redact) ──
    # Mirrors Rule 1c of the project guard at floor strength. Using a secret is
    # still fine: `secret exec`, passwordCommand wrappers, launchd.
    "Bash(secret reveal *)"
    "Bash(security find-generic-password -w*)"
    "Bash(security find-generic-password * -w*)"
    "Bash(security find-internet-password -w*)"
    "Bash(security find-internet-password * -w*)"
    # Host-decrypted agenix plaintext on macos, and the two OpenTofu state dirs
    # that hold a tunnel connector token (+ an Access service-token secret) in
    # plaintext (CLAUDE.md § Important Notes). A Read deny also blocks Edit/Write.
    "Read(//run/agenix/**)"
    "Read(~/.local/state/nix-config-cf-tunnel/**)"
    "Read(~/.local/state/nix-config-mcp-public/**)"
    "Read(~/.aws/sso/cache/**)"

    # ── Irreversible remote actions an unattended agent must not take ──
    # A merge is a production trigger in more than one repo this Mac works on
    # (e.g. a `main` with no required reviewers). Review and merge stay human.
    "Bash(gh pr merge *)"
    # Both flag positions. `--force-with-lease` stays allowed on purpose: it is
    # the safe way to update an agent's own rebased PR branch, and protected
    # branches are already force-push-proof server-side (GitHub rulesets).
    "Bash(git push --force *)"
    "Bash(git push -f *)"
    "Bash(git push * --force)"
    "Bash(git push * -f)"
  ];
}
