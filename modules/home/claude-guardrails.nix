{ pkgs, lib, ... }:
# The GLOBAL guardrail floor for Claude Code — user-scope `permissions.deny` (secret
# egress) and `permissions.ask` (recoverable actions the operator confirms), applied
# in EVERY repo on this Mac, not just this one.
#
# WHY THIS EXISTS. Every decision hook this fleet runs is project-scoped: the
# Write|Edit secret prompt sits in THIS repo's `.claude/settings.json`, and
# `pretooluse-bash-guard`/`stop-gate` arrive as `superhook` plugin hooks that
# find `.claude/hooks/` by convention. A session anywhere else (a work
# repo, `~`) got none of it, while the VS Code extension and the `claude`
# terminal profile start in `bypassPermissions` (default.nix). (The global MCP
# gateway that first forced this was purged 2026-10-02; the project-scope gap remains.)
#
# UPSTREAM FIRST. `programs.claude-code.settings` is `jsonFormat.type`
# (home-manager modules/programs/claude-code/options.nix) — freeform,
# so ANY settings.json key passes through untyped, and module-system list
# merging concatenates `permissions.deny` across modules, so this file ADDS to
# whatever else sets it. Its own example block shows `permissions.deny`. No
# hook, no script, no activation step: Claude Code enforces deny rules itself,
# in every permission mode — `bypassPermissions` skips PROMPTS, and a deny is
# not a prompt.
#
# NOT ONLY DENIES. `settings.attribution` below is the other half of the same
# floor: a policy that lived as prose in claude/CLAUDE.md and therefore had to
# be re-won every session against a harness default that asserts the opposite.
# A setting is won once. The SCOPE RULE below governs both halves.
#
# WHAT A DENY RULE IS NOT. Claude Code's docs are explicit that a Bash deny
# "isn't a security boundary around the program": it matches the command text
# Claude writes (compound commands and `$(…)` included) but not `/usr/bin/x` or
# `sh -c 'x'`. Both halves were MEASURED 2026-10-21 for `env`, as `echo $(env)`,
# `/usr/bin/env` and `bash -c env`, in the environment-dump block below. This is
# a FLOOR against the common, accidental shape — the
# project-scoped superhook guard stays the deeper, tested layer in this repo.
#
# A RULE RESTATED IN `.claude/settings.json` IS NOT DUPLICATION TO CLEAN UP.
# This file is materialised by Home Manager into ~/.claude, which the
# devcontainer deliberately does NOT mount (.devcontainer/devcontainer.json: "No
# volume for ~/.claude (deliberate — don't re-add one)"). Inside that container,
# and in any clone on a machine this HM config never touched, the checked-in
# project copy is the only floor there is.
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
# is darwin-only (default.nix), and the gate keeps nixpi/nixvm byte-identical.
let
  # The secret-path COORDINATES, shared with grok's sandbox so the layers cannot drift.
  # See that file for why this is data rather than a second copy of the rules.
  secretReadPaths = import ../_lib/secret-read-paths.nix;

  # `//` is Claude's ABSOLUTE spelling and `~/` its home-relative one; `/**`
  # makes it a subtree. A Read deny also blocks Edit and Write.
  secretReadDenies =
    map (p: "Read(/${p}/**)") secretReadPaths.absolute
    ++ map (p: "Read(~/${p}/**)") secretReadPaths.underHome;
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  # The ONE failure mode this file's own commentary names as worse than a weak
  # floor: a rule list that is well-formed and EMPTY, which nothing reports. The
  # paths now arrive from another file, so make the vacuum a BUILD error instead
  # of a silent one. Cheap, and it is the condition under which deriving these
  # rules is safe at all.
  assertions = [
    {
      assertion = secretReadDenies != [ ];
      message = "modules/_lib/secret-read-paths.nix yielded no Read denies — the secret-path floor in claude-guardrails.nix would be silently empty.";
    }
  ];

  # ── AI attribution on git artifacts: OFF, as a SETTING (claude/CLAUDE.md
  #    § Git authorship) ──────────────────────────────────────────────────────
  # That section forbids a `Co-Authored-By: Claude` trailer on commits and a
  # "Generated with Claude Code" footer on PR/issue bodies. Claude Code injects
  # a session-start reminder asserting the opposite and claiming to supersede
  # earlier guidance, so the prose rule was an argument the model had to win on
  # every session — and § Git authorship already records the recurring cost of
  # merely FLAGGING that conflict each time (2026-09-12). This states the same
  # policy where the harness reads it, instead of where a model must recall it.
  #
  # UPSTREAM FIRST: grepped the pinned home-manager
  # (modules/programs/claude-code/options.nix) — there is NO typed
  # `programs.claude-code.settings.attribution` option, and none is needed:
  # `settings` is `inherit (jsonFormat) type`, so the attrs below reach
  # settings.json verbatim through `pkgs.formats.json`.
  #
  # VERIFIED AGAINST THE SCHEMA, not from memory — by this file's own standard
  # a key that matches nothing is not a weak setting but NO setting, and it
  # fails silently. `attribution` is a real top-level key in
  # json.schemastore.org/claude-code-settings.json, `additionalProperties:
  # false`, with exactly three sub-keys — `commit` (string), `pr` (string),
  # `sessionUrl` (boolean) — and it is documented at
  # code.claude.com/docs/en/settings-reference § Git and attribution. It landed
  # in claude-code 2.0.62; this fleet runs 2.1.260. Checked 2026-09-21. That
  # schema is not an outside opinion: home-manager stamps its URL into the
  # rendered file as `"$schema"`, so it is the contract this very settings.json
  # declares it satisfies.
  #
  # ALL THREE OR NOTHING. Upstream, verbatim: "Once you set `commit` or `pr`,
  # Claude Code ignores the deprecated `includeCoAuthoredBy` setting and uses
  # its default text for whichever of the two you left unset." So a lone
  # `commit = ""` does not merely leave the PR footer alone — it also REVIVES
  # that footer for anyone who was relying on `includeCoAuthoredBy = false`.
  # `sessionUrl` is a separate `Claude-Session` trailer emitted ONLY from a
  # cloud or Remote Control session, i.e. never visibly from this terminal,
  # which is exactly why it must be declared rather than noticed in a PR later.
  #
  # NOT `includeCoAuthoredBy = false`: deprecated since 2.0.62, blind to
  # `sessionUrl`, and ignored outright once `attribution` is set. It is also
  # the key the pinned home-manager's own `settings` EXAMPLE still shows — the
  # example is stale, the schema is not.
  programs.claude-code.settings.attribution = {
    commit = "";
    pr = "";
    sessionUrl = false;
  };

  programs.claude-code.settings.permissions.deny = [
    # ── Secret VALUES reaching the transcript (claude/CLAUDE.md § Redact) ──
    # Mirrors Rule 1c of the project guard at floor strength. Using a secret is
    # still fine: `secret exec`, passwordCommand wrappers, launchd.
    #
    # EDIT THIS GROUP, EDIT IT TWICE. Every rule from here down to the end of the
    # `age` block is restated verbatim in modules/darwin/claude-managed-settings.nix
    # (root-owned managed scope, the tier above this one). Deriving one list from
    # the other by string match was rejected: it yields `[ ]` the moment a rule is
    # reworded — a well-formed, completely empty floor. That is the silent vacuum
    # the `attribution` note above records: a rule matching nothing is not a weak
    # floor but NO floor, and nothing reports it. `checks.<system>.claude-managed-settings` fails the build when this group
    # gains a rule the managed copy lacks.
    "Bash(secret reveal *)"
    "Bash(security find-generic-password -w*)"
    "Bash(security find-generic-password * -w*)"
    "Bash(security find-internet-password -w*)"
    "Bash(security find-internet-password * -w*)"
    # ENVIRONMENT DUMPS. The keychain-secrets loader exports every bound secret
    # into EVERY shell on this Mac (.zshenv, .bash_profile, $BASH_ENV), so a bare
    # `env` is a secret reveal by another name. On 2026-10-21 an audit subagent's
    # `env | grep -E '^(LANG|LC_)'` printed three API keys, which were rotated.
    # The project guard's Rule 1e (#927) is the deeper, tested layer, but it
    # guards sessions rooted in this repo only; this is what every other repo gets.
    #
    # EXACT MATCH, NO WILDCARD. `Bash(env *)` would deny `env FOO=bar cmd` and
    # `Bash(printenv *)` would deny `printenv LANG`, both quiet and legitimate.
    # Exact entries also carry none of the leading-wildcard cost recorded under
    # the agenix block below.
    #
    # MEASURED, NOT ASSUMED — 2026-10-21, claude-code 2.1.289. These nine as a
    # USER-scope deny, `-p --dangerously-skip-permissions` (so nothing but a deny
    # can block), one fresh session per command. Sealed sandbox: a fake HOME (no
    # loader, no plugin hooks), cwd outside this repo, `env -i` plus one dummy
    # variable. Verdicts are read from each session's tool_result, not the
    # model's prose, and only rows whose tool_use command was byte-identical count:
    #   DENIED   env · env | grep X · true && env · true; env · env 2>&1 ·
    #            env > /dev/null · echo $(env) · nice env | grep X ·
    #            printenv | grep X · set | grep X · export | grep X ·
    #            export -p | grep X · declare -x | grep X · declare -p | grep X ·
    #            typeset -x | grep X · typeset -p | grep X
    #   ALLOWED  printenv NAME · env X=1 /usr/bin/true · set -o pipefail; echo ok ·
    #            export X=1; echo ok   (the over-block controls: all pass)
    #   ALLOWED  /usr/bin/env · bash -c env   (the by-path / by-subshell class
    #            the header already names as out of reach — a FLOOR, not a wall)
    # So the matcher splits on `|`, `&&`, `;` and `$(…)`, drops redirections and
    # strips a leading `nice` (one of the fixed wrappers named under the agenix
    # block) BEFORE the exact compare: an exact entry covers the compound shapes
    # a model actually writes, not just the bare word.
    # Also out of reach, as for Rule 1e: one NAMED variable (`printenv SOME_KEY`,
    # `echo "$SOME_KEY"`) and programs that read the env themselves (python
    # os.environ, node process.env, `jq -n env`). NOT MEASURED: a heredoc whose
    # body has a bare `env` line. Rule 1e blocks that as a known false positive;
    # whether this matcher does too is unknown.
    "Bash(env)"
    "Bash(printenv)"
    "Bash(set)"
    "Bash(export)"
    "Bash(export -p)"
    "Bash(declare -x)"
    "Bash(declare -p)"
    "Bash(typeset -x)"
    "Bash(typeset -p)"
    # Host-decrypted agenix plaintext on macos, and the two OpenTofu state dirs
    # that hold a tunnel connector token (+ an Access service-token secret) in
    # plaintext (CLAUDE.md § Important Notes). A Read deny also blocks Edit/Write.
    #
    # THE mcp-public ENTRY STAYS, and it is NOT leftover cleanup to finish. #737
    # deleted that stack's RENDERER, not the operator's state: nothing in Nix ever
    # created or removes ~/.local/state/nix-config-mcp-public, so a state file
    # written before the teardown can still be sitting there with an Access
    # service-token secret in it. A deny whose target file can still exist is
    # still load-bearing — the rule only dies when the FILE cannot exist. Delete
    # it after deleting the directory, in that order, never the reverse.
    #
    # The `Read(...)` path globs render from modules/_lib/secret-read-paths.nix (shared
    # with grok's sandbox); the `assertions` above make an empty render a build error.
  ]
  ++ secretReadDenies
  ++ [
    # `agenix -d FILE` was the one shape in this family still open, and it is
    # the bluntest of them: it prints an age ciphertext's PLAINTEXT straight
    # into the transcript. Fleet-wide policy already forbids it in two places —
    # claude/CLAUDE.md § Redact names "`.age` plaintext" outright, and
    # CLAUDE.md § Security says "Never display a secret value" — and it is
    # wrong in every repo, so it belongs at this floor and not in a `.claude/`.
    # Verified against the PINNED agenix (ryantm/agenix
    # pkgs/agenix.sh): `-d|--decrypt` sets DECRYPT_ONLY and takes FILE, and the
    # dispatch line appends `-o -`, so the cleartext goes to stdout by
    # construction. `-i/--identity` may PRECEDE it, hence both flag positions —
    # the same reason `security find-generic-password` needs two entries above.
    # No space before `*`, so `-d*` also matches a bare `agenix -d`.
    "Bash(agenix -d*)"
    "Bash(agenix --decrypt*)"
    "Bash(agenix * -d*)"
    "Bash(agenix * --decrypt*)"
    # agenix is NOT on PATH — it exists only in this repo's devShell
    # (modules/parts/devshell.nix), so the one-shot spelling is a `nix develop
    # -c` away and the four rules above never see it. Claude Code strips a
    # FIXED wrapper list before matching (timeout/time/nice/nohup/stdbuf,
    # `command`/`builtin`, `noglob`, flagless `xargs`) and upstream states that
    # environment runners — `direnv exec`, `devbox run`, `mise exec`, `npx`,
    # `docker exec` — are deliberately NOT in it. `nix develop -c` is one of
    # those, so it needs its own pair rather than inheriting the plain ones.
    "Bash(nix develop * agenix -d*)"
    "Bash(nix develop * agenix --decrypt*)"
    # `age -d` matters MORE than `agenix -d`, on the same logic that made
    # `security find-generic-password -w` non-negotiable above: agenix is only
    # a wrapper, while `age` itself is brew-installed on this Mac
    # (hosts/macos.nix brews) and therefore on PATH in every repo, no devShell
    # required. `age --decrypt -i <key> <file>` prints the identical plaintext.
    "Bash(age -d*)"
    "Bash(age --decrypt*)"
    "Bash(age * -d*)"
    "Bash(age * --decrypt*)"
    # DELIBERATELY NOT COVERED, named so the gap is a decision and not a miss:
    #   · `agenix -e FILE` under `EDITOR=cat`. `-e` is the SANCTIONED editing
    #     path (CLAUDE.md § Security), so denying it breaks the documented
    #     workflow to buy back an evasion one env var reopens anyway.
    #   · `* agenix -d*` — a LEADING wildcard would cover every runner at once,
    #     and is rejected on measured cost: the project guard's Rule 1c matched
    #     a literal string anywhere rather than at command position and blocked
    #     its OWN commit message within a minute of being written, then blocked
    #     the fix. A deny rule has no command-position anchor to reach for.
    #   · `/opt/homebrew/bin/age -d`, `sh -c 'agenix -d …'`, and `nix run
    #     github:ryantm/agenix -- -d` — the by-path / by-subshell class the
    #     header already names as out of reach, plus a spelling this fleet has
    #     no reason to produce (agenix is a devShell package here, not an app).
    #   · The ciphertexts themselves. `secrets/*.age` is committed to a PUBLIC
    #     repo, so reading one leaks nothing; the value exists only after a
    #     decrypt, which is the verb these rules name. No `Read(secrets/**)`.
    # And NO catch-all `Read(**)`. A blanket Read deny disables Bash
    # auto-approve across the board — it trades one narrow leak for a
    # permanently noisier session everywhere, which is how a floor gets turned
    # off wholesale by an irritated operator. The seven narrow `Read(...)` path
    # denies above are the shape that holds; a broad one would undo them.
  ];

  # ── ASK, not deny (operator decision 2026-11-02) ──
  # These families stop an action that is RECOVERABLE and that the operator may
  # legitimately want; a hard deny only pushed the agent into workarounds or a
  # handed-over command. They now raise Claude Code's permission prompt instead.
  # `ask` rules prompt in EVERY mode, bypassPermissions included (documented:
  # "actions no mode auto-approves … tools matched by an explicit ask rule"), and
  # in an unattended run (`-p`, cloud routine, dontAsk) an ask becomes a DENY, so
  # nothing here runs unseen. Measured 2026-11-02 on 2.1.296 in a canary repo: a
  # `permissions.ask` match under bypass was refused headless, never silently run.
  # The SECRET families above stay deny on purpose (decision same day): printing a
  # secret value has no undo, and the managed tier mirrors them.
  programs.claude-code.settings.permissions.ask = [
    # ── Imperative MCP adoption (mcp-scout: "installation IS declaration") ──
    # Servers arrive ONLY as Claude Code plugins now (./plugin-mcp.nix) —
    # the gateway that used to be the single source is gone.
    # A runtime add lands in ~/.claude.json, outside flake.lock and every check that
    # can see a declared server. MCP tool prefixes have changed three times without
    # notice, so verify any MCP rule against a live session's tool names, never by reasoning.
    "Bash(claude mcp add *)"
    "Bash(claude mcp add-json *)"
    "Bash(claude mcp add-from-claude-desktop *)"
    "Edit(~/.claude.json)"

    # ── Login persistence and credential config (Edit covers Write too) ──
    # Each of these runs code or grants access at the NEXT login, shell or git
    # call — the persistence shape an injected instruction reaches for. And every
    # one is declared: Home Manager owns ~/.zshrc, ~/.zshenv, ~/.ssh/config and
    # ~/.config/git/config as store symlinks, and launchd agents come from
    # `launchd.agents`. An agent write would swap a declared file for a mutable
    # copy that the next `activate` refuses to clobber. The operator-hand-placed
    # files beside them (`~/.config/git/local.inc`, `~/.config/git/allowed_signers`) are
    # his by CLAUDE.md § Configuration. A change to any of them goes through Nix,
    # or through the operator's own terminal.
    #
    # Added 2026-10-31 after the project Write|Edit validator (.claude/settings.json)
    # was found approving "any file under HOME": that prompt is project-scoped
    # and judged by a model, so it was never the floor for these paths.
    "Edit(~/Library/LaunchAgents/**)"
    "Edit(~/.ssh/**)"
    "Edit(~/.zshrc)"
    "Edit(~/.zshenv)"
    "Edit(~/.zprofile)"
    "Edit(~/.zlogin)"
    "Edit(~/.bashrc)"
    "Edit(~/.bash_profile)"
    "Edit(~/.profile)"
    "Edit(~/.gitconfig)"
    "Edit(~/.config/git/**)"

    # ── OpenTofu state dirs not already denied above ──
    # Tofu state is encrypted at rest but secrets-adjacent, so the operator confirms reads.
    "Read(~/.local/state/nix-config-cf-access-org/**)"
    "Read(~/.local/state/nix-config-cf-zones/**)"
    "Read(~/.local/state/nix-config-gcp-foundation/**)"
    "Read(~/.local/state/nix-config-gcp-budget/**)"
    "Read(~/.local/state/nix-config-hc-checks/**)"

    # ── Secret Manager writes go through `secrets-push`, never raw gcloud ──
    # secrets-push is the only writer that enforces the billable-version cap
    # (keychain-secrets capsule, `backend.maxVersions`). Raw gcloud skips it, and the
    # free tier is 6 versions per BILLING ACCOUNT: Oct 2026 sessions pushed 17 by habit.
    "Bash(gcloud secrets create *)"
    "Bash(gcloud secrets versions add *)"
    "Bash(gcloud --quiet secrets create *)"
    "Bash(gcloud --quiet secrets versions add *)"

    # ── Remote history rewrites ──
    # No `gh pr merge` rule, on purpose (operator, 2026-10-30): branch protection on the
    # forge is the merge gate, and the GitHub MCP's merge tool bypassed a Bash rule anyway.
    # Force-push, both flag positions. `--force-with-lease` stays allowed on purpose: it is
    # the safe way to update an agent's own rebased PR branch, and protected
    # branches are already force-push-proof server-side (GitHub rulesets).
    "Bash(git push --force *)"
    "Bash(git push -f *)"
    "Bash(git push * --force)"
    "Bash(git push * -f)"
  ];
}
