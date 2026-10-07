# Root-owned Claude Code MANAGED settings for `macos` — the fleet's strongest
# agent-policy floor, one tier ABOVE the user-scope floor in
# modules/home/claude-guardrails.nix. It does not replace that file; the two
# tiers are additive, and § WHY THE DUPLICATION IS THE POINT below says why.
#
# WHAT MANAGED SCOPE BUYS — claimed only as far as the SHIPPED BINARY evidences
# it (claude-code 2.1.260, the one source that cannot be stale). The two halves
# of this file lean on DIFFERENT properties, and conflating them is how the wrong
# quote got cited here once already:
#   · The deny list needs UNION, not override. Verbatim, from
#     `allowManagedPermissionRulesOnly`'s own description: "--disallowedTools and
#     other deny and ask rules from the command line or the current session still
#     apply." Deny rules accumulate from every source, so a managed one is simply
#     always among them — and it cannot be taken back in-session: "Cannot delete
#     permission rules from read-only settings".
#   · `attribution` is value-resolved, so it needs the LADDER, and no single
#     string states the general rule. The strongest honest claim: every per-key
#     precedence sentence in 2.1.260 that names the sources puts managed first —
#     `processWrapper`, "Honored from managed settings, a --settings/SDK-supplied
#     settings file, and user settings, in that precedence order"; `modelPicker`,
#     "the highest-precedence of those that defines modelPicker wins outright".
#     None states the reverse. It is belt-and-braces regardless:
#     modules/home/claude-guardrails.nix sets the identical three values at user
#     scope, so the two agree whichever one wins.
# NOT evidence for either, though this header cited it as such: "server-managed >
# MDM (managed plist / HKLM) > managed-settings.json". Read in context it is the
# managed-source composition mode ("first-wins" default vs "merge") describing how
# managed SOURCES compose AMONG THEMSELVES, not the managed-vs-user/project/flag
# ladder. Still worth knowing — this fleet has exactly one managed source, so
# first-wins is a no-op here.
# Either way the floor holds in a session where ~/.claude was never materialised,
# was hand-edited, or was started under `bypassPermissions` — which this fleet's
# VS Code extension and its `claude` terminal profile BOTH do
# (modules/home/default.nix).
#
# THE PATH, read out of that binary's own string table rather than from docs:
# macOS "/Library/Application Support/ClaudeCode/managed-settings.json";
# Linux/WSL "/etc/claude-code/"; Windows "C:/Program Files/ClaudeCode/". A
# future Linux host is therefore a one-line `systemDir` change, not a
# rediscovery.
#
# ── UPSTREAM FIRST ─────────────────────────────────────────────────────────────
# `grepped nix-darwin/modules for etc / Library / file / path, and enumerated
#  options.environment on the live macos config — no option writes an arbitrary
#  /Library file → custom, because both file-placing surfaces are hard-coded to
#  /etc and /Library/Launch*.`
# Read, not recalled, against the PINNED nix-darwin (flake.lock →
# /nix/store/8ggr67sci43hlp8ba6rhjrdhhj5490am-source):
#   · environment.etc — modules/system/etc.nix:19. `system.build.etc` is
#     literally `mkdir -p $out/etc; cd $out/etc; ln -s …`. /etc only, and there
#     is no target-prefix option to redirect it.
#   · environment.launchAgents / launchDaemons / userLaunchAgents —
#     modules/system/launchd.nix:61,69,77. `launchdActivation` hard-codes
#     '/Library/<basedir>/<target>' with basedir ∈ {LaunchAgents, LaunchDaemons}.
#     Reaching ClaudeCode/ would need a `../`-traversing target, i.e. ABUSING
#     the option rather than using it.
#   · The live surface, so "no option exists" is not a grep artifact.
#     options.environment on darwinConfigurations.macos is exactly: darwinConfig
#     defaultPackages enableAllTerminfo etc extraInit extraOutputsToInstall
#     extraSetup interactiveShellInit launchAgents launchDaemons loginShell
#     loginShellInit pathsToLink postBuild profiles shellAliases shellInit shells
#     systemPackages systemPath userLaunchAgents variables. Nothing generic.
# Three NEAR-MISSES rejected on their IMPLEMENTATIONS, named so each is a
# decision rather than an oversight:
#   · system.patches (modules/system/patches.nix:12) activates as
#     `patch --force --reverse --backup -d / -p1` — it edits files that already
#     exist and undoes itself by reversing a diff, so it can neither create a
#     whole new JSON file nor later remove one.
#   · system.defaults.CustomSystemPreferences writes through `defaults` into a
#     preferences DOMAIN, not a JSON file at a path. modules/darwin/core.nix:638
#     already records this exact limitation for Docker's settings-store.
#   · Anthropic's own MDM channel (a com.anthropic.claudecode configuration
#     profile under /Library/Managed Preferences/) needs an MDM to install the
#     profile. This fleet has no MDM.
# Home Manager cannot substitute either: the pinned `programs.claude-code` writes
# only <configDir>/settings.json under $HOME and runs as the USER, so it cannot
# produce a root-owned file at all.
# `no community tool owns this (searched: nix-darwin managed-settings,
#  claude-code managed settings nix, nixpkgs claude managed)` — the only
# publisher-supplied artifacts are Anthropic's Jamf/Intune/GPO MDM templates,
# which are MDM payloads and not Nix.
#
# ── WHY THERE IS NO managed-mcp.json HERE, so nobody re-adds it ────────────────
# Deploying that file SUPPRESSES the claude.ai connectors Claude Code fetches for
# itself, unless `allowAllClaudeAiMcps` is set alongside it — and this fleet runs
# four Gmail connectors plus Drive, Calendar and Slack. The MCP source of truth
# is NOTHING ANY MORE: `modules/shared/mcp.nix` was DELETED 2026-10-02 along with
# the gateway and its Cloudflare portal, and `modules/shared/` itself became
# `modules/home/` (#775). MCP servers now come from an enabled plugin's own
# `.mcp.json`, with a PATH launcher where one needs a Keychain read. ADR-003 §5
# still holds: MCP servers may not overlay. One file, one owner, no MCP.
#
# ── WHY `merge` ALSO GUARDS THE FLOOR AGAINST BEING HOLLOWED OUT ─────────────
# `managedSourcesBehavior = "merge"` below was set to stop a higher-ranked managed
# source SKIPPING this file wholesale. It appears to cover a second case its author
# did not have in mind, recorded here because it bears on which tier a deny lives in.
#
# `allowManagedPermissionRulesOnly` does not OVERRIDE lower-scope rules; it IGNORES
# them — "Ignore permission rules from user, project, and local settings." THE
# MANAGED FILE IS NOT IN THAT LIST. Under the default `first-wins` a remote source
# would skip this file anyway, so the distinction was moot; under `merge` both apply,
# so a deny HERE should survive a remote lock where the same deny in user scope
# would not.
#
# [A] THAT LAST STEP IS AN INFERENCE, NOT A MEASUREMENT — it reads "user, project,
# local" as an exhaustive list. What would settle it: a Team/Enterprise session with
# that key set remotely, then checking whether a managed-FILE deny still binds. A
# GitHub issue search on anthropics/claude-code found ZERO reports either way.
#
# AND IT CHANGES NOTHING BELOW. This argument was raised as a reason to promote the
# `--force` denies into this file, and REJECTED on § WHO IS RESTRAINED's own test:
# promoting them would mean the operator cannot force-push on repos he OWNS without
# a root-owned edit and a rebuild, because 2.1.260 refuses the retraction outright.
# "User scope can be switched off by an org policy" is not a weakness there — it IS
# the override, and it is load-bearing. Read that § before proposing the same move.
#
# One related finding, because it is the fear that usually motivates the move and it
# is UNFOUNDED: an org policy that ALLOWS force-push cannot defeat a user-scope deny.
# Per the permissions docs, "if a tool is denied at any level, no other level can
# allow it" and "deny rules from any scope are evaluated before allow rules." Only
# the ignore-key above can drop a lower rule — which is why it is the one that
# matters, and why it already sits in the deliberately-unset list below.
#
# ── SEVEN MANAGED-ONLY KEYS ARE DELIBERATELY UNSET ────────────────────────────
# Each would be a foot-gun at this strength: `allowManagedPermissionRulesOnly`
# (makes managed the ONLY source of permission rules, silently disabling this
# repo's .claude/settings.json AND the user-scope floor),
# `allowManagedHooksOnly` (this repo's superhook guard and stop-gate are PROJECT
# hooks), `allowManagedMcpServersOnly`, `disableSideloadFlags` (rejects
# --mcp-config / --plugin-dir / --agents), `permissions.defaultMode`,
# `managedMcpServers`, `availableModels`. All verified present in the 2.1.260
# binary — they are unset on purpose, not for lack of a spelling.
#
# ── SCOPE RULE for adding an entry, one notch stricter than the user floor ────
# A `permissions` entry must ALREADY be in modules/home/claude-guardrails.nix,
# AND be pure "never print a secret value" or "never sign work as an AI". Nothing
# that merely narrows a workflow — because there is NO in-session override here:
# deny beats ask beats allow, an allow cannot carve an exception out of a deny,
# and 2.1.260 refuses the retraction outright ("Cannot delete permission rules
# from read-only settings"). Undoing a wrong entry is a rebuild, not a
# /permissions click. The operator's escape hatches are unchanged: a `!`-prefixed
# command and a plain terminal never go through the permission system at all.
#
# ── AMENDMENT (2026-09-30, #674): SUPPLY-CHAIN GATES ARE A SECOND ADMITTED CLASS
# The rule above is written for `permissions`, and it stays exactly as strict
# there. It does not decide the case of a key that gates what THIRD-PARTY CODE may
# be loaded from at all, so this amendment decides it rather than letting an entry
# slip in under a rule that never contemplated it.
#
# Admitted, on three grounds that the excluded workflow-narrowing entries below
# (`gh pr merge *`, the `--force` spellings, the imperative-MCP group) do NOT share:
#
#  1. WHO IS RESTRAINED. Those entries restrain the OPERATOR, to protect him from
#     his own slip — and on his own repos his judgement beats the rule, which is
#     precisely why they are excluded. A supply-chain gate restrains an UNVETTED
#     UPSTREAM's ability to land executable configuration on this machine. The
#     operator's judgement is not the thing being second-guessed.
#  2. THE FAILURE IS SELF-DESCRIBING, not silent. A blocked source says so and
#     names the setting — verbatim from 2.1.268: "Plugins from <owner>/<repo> are
#     blocked by your organization's managed settings (strictKnownMarketplaces or
#     blockedMarketplaces)." Contrast a mis-spelled permission path, which matches
#     NOTHING silently and leaves no floor at all (see § PATHS below). The reason
#     the permissions rule is so strict is that its failures hide; this one's do not.
#  3. THE COST IS BOUNDED AND PRICED. With owner wildcards the gate costs a rebuild
#     only to trust a NEW OWNER, not to add a repo. #674 rejected the all-or-nothing
#     form of exactly this key for exactly that reason.
#
# NOT a licence to widen further. This admits gates on the PROVENANCE of loaded
# code. It does not admit a key because it is merely useful, and it does not
# loosen the `permissions` rule by one character.
#
# ── WHY THE DUPLICATION IS THE POINT, not drift to clean up ───────────────────
# `permissions.deny` lists from several scopes COMBINE (duplicates removed), so
# restating the rules costs nothing and each scope reaches where the other does
# not. User scope reaches the devcontainer and any clone on a machine this Home
# Manager config never touched; managed scope reaches a session whose ~/.claude
# was never written or was hand-edited. Same argument claude-guardrails.nix
# already makes for its own deliberate project-scope duplication, inverted.
#
# ── PATHS: ONLY `//` AND `~/`, AND THAT IS LOAD-BEARING ───────────────────────
# A SINGLE leading `/` anchors at the settings SOURCE, not the filesystem root,
# and what that resolves to for the managed tier is undocumented — upstream's own
# resolution table omits managed settings. A `Read(/run/agenix/**)` spelled that
# way here would resolve somewhere undefined and match NOTHING, silently, which
# by claude-guardrails.nix's own standard is not a weak floor but NO floor. The
# four Read rules below port verbatim from that file precisely because they
# already carry the safe spelling; do not re-spell them.
#
# ── COVERAGE LIMIT ────────────────────────────────────────────────────────────
# Managed settings do NOT reach an Anthropic-hosted cloud session; only
# server-managed settings do. That is a further reason the user- and
# project-scope layers stay put rather than being replaced by this one.
#
# ── VERIFY, because `nix flake check` cannot ──────────────────────────────────
# `/status` inside Claude Code lists `Enterprise managed settings (file)` under
# `Setting sources`. If that line is absent the file is misplaced or unparsed and
# this module enforces nothing, however green the flake check was — 2.1.260's own
# words for that case: "Managed settings document could not be parsed as a JSON
# object; none of its settings are in effect." `pkgs.formats.json` already
# guarantees the bytes PARSE, so what `/status` actually confirms is PLACEMENT.
# The residual gap neither it nor any check in this repo closes is a key this
# build does not recognise: accepted, listed, enforcing nothing.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.claudeManagedSettings;

  systemDir = "/Library/Application Support/ClaudeCode";
  target = "${systemDir}/managed-settings.json";
  ownedMarker = "${systemDir}/.nix-config-owned";

  # The kill switch is only real because the disabled branch DELETES. The marker
  # makes that safe in BOTH directions, and it took three pieces to get there:
  # `removeScript` refuses to delete without it, `ownershipCheck` refuses to
  # write over a file that lacks it, and `installScript` writes it FIRST. Any one
  # of those missing and the marker states an invariant the code does not have.
  ownedMarkerFile = pkgs.writeText "claude-managed-settings-owner" ''
    Written by modules/darwin/claude-managed-settings.nix. It claims
    managed-settings.json in this directory for that module: while this marker is
    present, local.claudeManagedSettings.enable = false may delete that file;
    while it is absent, activation REFUSES to write one. So an MDM payload or a
    hand-placed file here is neither overwritten nor deleted.
  '';

  settingsFile = (pkgs.formats.json { }).generate "claude-managed-settings.json" {
    # ── THE KEY THAT KEEPS THIS WHOLE FILE FROM BEING IGNORED ────────────────
    # Managed SOURCES are ranked, and the default is NOT a merge:
    #   "first-wins, the default: Claude Code uses the highest-ranked source that
    #    delivers at least one policy key and ignores the rest rather than merging
    #    them. […] Claude Code shows NO WARNING for the sources it skips."
    #     — code.claude.com/docs/en/managed-settings
    # Ranking, highest first: (1) remote/server-managed from claude.ai or a Claude
    # apps gateway, (2) MDM or OS policy (the macOS plist), (3) THIS FILE plus
    # managed-settings.d/*.json, (4) the Windows HKCU fallback.
    #
    # This fleet plants rank 3. So a rank-1 or rank-2 source arriving with ONE
    # unrelated policy key would silently void everything below — the
    # secret-value denies, the attribution keys, strictKnownMarketplaces,
    # disableSideloadFlags. Silently: no warning, and `nix flake check`
    # structurally cannot see it either, because this file is PLANTED rather than
    # evaluated.
    #
    # WHY IT IS INERT TODAY, AND WHY THAT IS NOT A GUARANTEE. Measured 2026-10-02:
    #   rank 1  `claude doctor` -> "Managed settings (remote): not fetched —
    #           requires an Enterprise or Team subscription" and "Organization
    #           policy: not applicable to Pro and Max accounts"
    #   rank 2  /Library/Managed Preferences/ DOES NOT EXIST on this Mac
    #   rank 3  managed-settings.json present, no managed-settings.d/
    # So rank 3 is the only managed source present and first-wins cannot fire.
    # The dependency is the ACCOUNT TIER, not this config — the day this account
    # becomes Team or Enterprise, rank 1 starts being fetched and the floor can be
    # skipped without anyone touching the repo.
    #
    # "merge" applies every admin source instead: "on most keys the higher-ranked
    # source's value applies, lists union, and locks take the strictest value."
    # Lists union and locks take the strictest value is exactly the posture a
    # guardrail floor wants — an org policy can only ever ADD to the denies here,
    # never replace them wholesale.
    #
    # Needs Claude Code >= v2.1.242; the fleet runs 2.1.268. It is one of the two
    # CONTROL keys (with wslInheritsWindowsSettings), not a policy key — so a file
    # containing only control keys does not count as "present" and Claude Code
    # moves to the next source. That is harmless here: this file carries plenty of
    # policy keys below.
    #
    # Verify with `/status` in a session: the `Setting sources` line ends in
    # ", merged" when composition is active, and a `Skipped sources` line names any
    # source that was passed over. `claude doctor` does NOT print either line.
    managedSourcesBehavior = "merge";

    # ── AI attribution on git artifacts: OFF (claude/CLAUDE.md § Git authorship)
    # Byte-identical to modules/home/claude-guardrails.nix's user-scope copy.
    # ALL THREE OR NOTHING, and that is upstream's rule rather than a preference:
    # once `commit` or `pr` is set, Claude Code ignores the deprecated
    # `includeCoAuthoredBy` and falls back to its DEFAULT text for whichever of
    # the two was left unset — so a lone `commit = ""` revives the PR footer.
    #
    # `sessionUrl = false` is the OMIT direction, settled against the 2.1.260
    # binary rather than inferred: "Whether to append the claude.ai session link
    # to commits and PRs created from web or Remote Control sessions (default:
    # true). Set to false to omit the Claude-Session trailer and PR-body link."
    # Recorded here because the polarity reads backwards at a glance and has
    # already been queried once; do not "fix" it to true.
    attribution = {
      commit = "";
      pr = "";
      sessionUrl = false;
    };

    permissions.deny = [
      # ── Secret VALUES reaching the transcript ──────────────────────────────
      # This list is the SECRET-VALUE group of
      # modules/home/claude-guardrails.nix, and nothing else. Every entry is
      # fleet-wide policy already written down twice — claude/CLAUDE.md § Redact
      # ("`.age` plaintext", Keychain reads) and CLAUDE.md § Security ("Never
      # display a secret value") — and wrong in every repo, which is what earns
      # a root-owned floor. USING a secret stays fine: `secret exec`,
      # passwordCommand wrappers, launchd.
      #
      # RESTATED, NOT DERIVED, and that is deliberate. The DRY move — filtering
      # the shared list down to these entries by string match — yields `[ ]` the
      # moment an upstream rule is reworded, producing a well-formed and
      # completely EMPTY floor. That is the exact silent-vacuum failure
      # claude-guardrails.nix records in its mcpfinder and `attribution` notes —
      # a rule matching nothing is not a weak floor but NO floor. The cost is
      # real and accepted: an edit to the secret-value rules must touch BOTH —
      # and claude-guardrails.nix carries the matching pointer beside the very
      # group an editor opens, so the duplication is signposted from both ends
      # rather than only from the copy nobody has a reason to open.
      "Bash(secret reveal *)"
      "Bash(security find-generic-password -w*)"
      "Bash(security find-generic-password * -w*)"
      "Bash(security find-internet-password -w*)"
      "Bash(security find-internet-password * -w*)"
      # Host-decrypted agenix plaintext on macos, plus the two OpenTofu state
      # dirs holding a tunnel connector token (and an Access service-token
      # secret) in plaintext. A Read deny also blocks Edit/Write.
      #
      # FOUR AGENIX SPELLINGS, NOT ONE (2026-10-07). `/run` is a SYMLINK on
      # darwin — measured that day: `/run -> private/var/run` and
      # `/run/agenix -> /run/agenix.d/1`. A `Read()` glob matches the path TEXT
      # a tool call carries and does NOT resolve a symlink, so the single
      # `//run/agenix/**` rule that stood here never covered a read spelled
      # `/private/var/run/agenix.d/1/…` — the real file. The other three close
      # that, and they are a WIDENING of this floor, not a restatement of it.
      #
      # The twin list in modules/home/claude-guardrails.nix renders these from
      # modules/_lib/secret-read-paths.nix. This copy stays HAND-WRITTEN on the
      # "RESTATED, NOT DERIVED" rule above, which is about not deriving a floor
      # from something that can silently match nothing — and the
      # `claude-managed-settings` check is what makes the duplication safe: it
      # FAILED THE BUILD when the guardrails half gained these three and this
      # half did not. The cost the note above calls "real and accepted" is
      # exactly that build failure, working as designed.
      "Read(//run/agenix/**)"
      "Read(//run/agenix.d/**)"
      "Read(//private/var/run/agenix/**)"
      "Read(//private/var/run/agenix.d/**)"
      "Read(~/.local/state/nix-config-cf-tunnel/**)"
      "Read(~/.local/state/nix-config-mcp-public/**)"
      "Read(~/.aws/sso/cache/**)"
      # Both flag positions, because `-i/--identity` may precede the verb.
      "Bash(agenix -d*)"
      "Bash(agenix --decrypt*)"
      "Bash(agenix * -d*)"
      "Bash(agenix * --decrypt*)"
      # `nix develop -c` is an environment runner, and upstream deliberately
      # keeps those out of the fixed wrapper list it strips before matching — so
      # the one-shot spelling needs its own pair rather than inheriting above.
      "Bash(nix develop * agenix -d*)"
      "Bash(nix develop * agenix --decrypt*)"
      # `age` matters MORE than `agenix`: agenix is a devShell-only wrapper here,
      # while `age` is brew-installed (hosts/macos.nix) and on PATH in every repo.
      "Bash(age -d*)"
      "Bash(age --decrypt*)"
      "Bash(age * -d*)"
      "Bash(age * --decrypt*)"
      # NOT elevated to this tier, on purpose — they stay at user scope where
      # they already work, because they narrow a WORKFLOW rather than protect a
      # value, and a wrong one here has no in-session undo: the imperative-MCP
      # group (`claude mcp add *`, `Edit(~/.claude.json)`) and the irreversible
      # remote group (`gh pr merge *`, the four `git push --force` spellings).
    ];

    # ── SUPPLY-CHAIN GATE: which marketplace SOURCES may be added at all ───────
    # #674's chosen mitigation (option B-prime). This is the ONE workflow-narrowing
    # family the SCOPE RULE above admits, and the header says why: it restrains an
    # unvetted THIRD PARTY, not the operator.
    #
    # OWNER WILDCARDS are the whole reason this is affordable. `owner/*` is legal
    # ONLY in the managed policy lists, quoted verbatim from the 2.1.268 binary:
    #   "ONLY in the managed-settings policy lists (strictKnownMarketplaces /
    #    blockedMarketplaces) the owner-wildcard form "owner/*" matches every
    #    repository under exactly that owner. Everywhere else (marketplace add,
    #    extraKnownMarketplaces, known_marketplaces.json) the value must name a
    #    single repository — a wildcard is taken literally and fails to clone."
    # So `/plugin` → Add marketplace KEEPS WORKING for any repo under a trusted
    # owner; a rebuild is needed only to trust a NEW OWNER. That is what makes this
    # a gate rather than a padlock, and it is why the all-or-nothing version of this
    # option was rejected.
    #
    # THE GATE DOES NOT REGISTER — the binary's own note on this key:
    #   "this is a policy gate only — it does NOT register marketplaces. To
    #    pre-register allowed marketplaces for users, also set
    #    extraKnownMarketplaces."
    # That half lives in modules/home/claude-plugins.nix. Both are required: this
    # list decides what MAY be added, that one decides what IS added.
    #
    # WHY THE EXACT `git` ENTRIES ARE HERE ALONGSIDE THE WILDCARDS, and do not
    # delete them as redundant: whether a `github`-form wildcard matches a
    # marketplace DECLARED as a `git` source (which all eight of ours are) is
    # INFERRED, not measured. It could not be measured — `strictKnownMarketplaces`
    # enforces only from the real managed file, and CLAUDE_CODE_MANAGED_SETTINGS_PATH
    # does NOT deliver it: an allowlist naming only a nonexistent owner still
    # permitted `kattakath/skills` (measured 2026-09-30, isolated CLAUDE_CONFIG_DIR).
    # So the first activation is the first real test, and these exact entries make
    # that test SAFE: every marketplace the fleet declares today matches one of them
    # literally, whatever the wildcards turn out to do. Strings must match BYTE FOR
    # BYTE — `.git`, a trailing slash and an `ssh://` spelling are different values,
    # and an entry without `ref` does not cover a source that sets one.
    #
    # NEVER let this list reach `[]`, not even transiently: an empty array is not
    # "unset", it is "allow nothing" (upstream's own table), which would block the
    # official marketplace fleet-wide. Edit it in one complete change.
    #
    # `pathPattern` covers the ONE store-path marketplace (xai-grok-build, a
    # `directory` source). An exact path is impossible here for the same reason
    # `allowedMcpServers` was rejected in #674 — the hash rotates on every rebuild
    # and a stale entry fails SILENTLY. `^/nix/store/` is the right trust boundary
    # instead: only the Nix daemon can write there, so a path under it is already
    # something this flake put in place.
    #
    # `skills-dir` is NOT optional. Its own description: "In strictKnownMarketplaces:
    # opt the scan back IN (by default ANY allowlist blocks it)." Omitting it would
    # silently kill the ~/.claude/skills/ auto-load the moment this key appears.
    strictKnownMarketplaces = [
      # Owners trusted wholesale — a new repo under these needs no rebuild.
      {
        source = "github";
        repo = "kattakath/*";
      }
      {
        source = "github";
        repo = "anthropics/*";
      }
      {
        source = "github";
        repo = "upstash/*";
      }
      {
        source = "github";
        repo = "cloudflare/*";
      }
      {
        source = "github";
        repo = "trailofbits/*";
      }
      {
        source = "github";
        repo = "obra/*";
      }

      # The eight declared today, spelled exactly as modules/home/default.nix
      # declares them, so nothing in flight depends on the wildcard inference.
      {
        source = "git";
        url = "https://github.com/kattakath/skills.git";
      }
      {
        source = "git";
        url = "https://github.com/anthropics/claude-plugins-official.git";
      }
      {
        source = "git";
        url = "https://github.com/anthropics/skills.git";
      }
      {
        source = "git";
        url = "https://github.com/upstash/context7.git";
      }
      {
        source = "git";
        url = "https://github.com/cloudflare/skills.git";
      }
      {
        source = "git";
        url = "https://github.com/trailofbits/skills.git";
      }
      {
        source = "git";
        url = "https://github.com/obra/superpowers.git";
      }

      # The store-path marketplace, and the ~/.claude/skills/ auto-load.
      {
        source = "pathPattern";
        pathPattern = "^/nix/store/";
      }
      { source = "skills-dir"; }
    ];
  };

  # The install half of the ownership invariant. `install` on its own will happily
  # clobber an MDM payload and then plant our marker over it, which would make the
  # marker's claim false the moment it mattered, so the refusal has to live
  # somewhere activation can still back out of cleanly.
  #
  # nix-darwin's `checks` slot is exactly that place: spliced at
  # modules/system/activation-scripts.nix:116, BEFORE /etc, launchd, defaults and
  # Homebrew run. A guard in postActivation (:140) would instead abort with the
  # whole system already rewritten and /run/current-system not yet moved — a
  # half-applied generation, traded for nothing. Shape lifted from nix-darwin's
  # own answer to the identical problem, modules/system/etc.nix:81-91: name the
  # file, tell the operator to rename it, exit 2.
  #
  # It also runs from the boot-time activate-system daemon
  # (modules/services/activate-system/default.nix:68), where it lands AFTER
  # /run/current-system is set — so a foreign file planted while the Mac was off
  # costs that boot's `etc` and `keyboard` steps, not the generation. Same blast
  # radius as etc.nix's check, which is upstream's accepted trade.
  ownershipCheck = ''
    if [ -e ${lib.escapeShellArg target} ] && [ ! -e ${lib.escapeShellArg ownedMarker} ]; then
      printf >&2 "\x1B[1;31merror: unowned Claude Code managed settings, aborting activation\x1B[0m\n"
      printf >&2 "  %s\n" ${lib.escapeShellArg target}
      printf >&2 "exists, but this module's ownership marker does not:\n"
      printf >&2 "  %s\n" ${lib.escapeShellArg ownedMarker}
      printf >&2 "so an MDM payload or a hand-placed file owns that path and would be\n"
      printf >&2 "silently overwritten. Check there is nothing critical in it, rename it by\n"
      printf >&2 "adding .before-nix-darwin to the end, and try again — or set\n"
      printf >&2 "local.claudeManagedSettings.enable = false to leave the path alone.\n"
      exit 2
    fi
  '';

  # `install` comes from coreutils, which nix-darwin puts on the activation PATH
  # (modules/system/activation-scripts.nix:17-21, `makeBinPath [ gnugrep
  # coreutils ]`), and activation runs as root (same file, line 94 `export
  # USER=root`). So content, mode AND ownership are ASSERTED on every activation
  # by `install` itself rather than hoped for — a hand-chmod drifts back on the
  # next `activate`. `wheel` is gid 0 on macOS.
  #
  # MARKER BEFORE POLICY, and the order is the whole point. Activation runs under
  # `set -e` + `set -o pipefail` (activation-scripts.nix:88-89), so any one
  # `install` failing ends the run where it stands. Policy-first meant a marker
  # that failed to land (disk full, `chflags uchg`, EIO) stranded a root-owned
  # policy file `removeScript` could then never delete — the kill switch broken by
  # the very activation meant to arm it. Marker-first inverts the worst case to a
  # marker with no policy, which `enable = false` cleans up.
  #
  # escapeShellArg is load-bearing, not style: "Application Support" contains a
  # space, and an unquoted path would write to /Library/Application, exit 0, and
  # leave no policy and no error — a vacuous install.
  installScript = ''
    install -d -m 0755 -o root -g wheel ${lib.escapeShellArg systemDir}
    install -m 0644 -o root -g wheel ${ownedMarkerFile} ${lib.escapeShellArg ownedMarker}
    install -m 0644 -o root -g wheel ${settingsFile} ${lib.escapeShellArg target}
  '';

  # Without this branch `enable = false` would merely stop REWRITING the file:
  # the root-owned copy would survive and keep enforcing forever, and the option
  # would be decorative. `rmdir` only succeeds on an empty directory, so anything
  # else living here survives untouched.
  removeScript = ''
    if [ -e ${lib.escapeShellArg ownedMarker} ]; then
      rm -f ${lib.escapeShellArg target} ${lib.escapeShellArg ownedMarker}
      rmdir ${lib.escapeShellArg systemDir} 2>/dev/null || true
    fi
  '';
in
{
  options.local.claudeManagedSettings.enable = lib.mkEnableOption ''
    root-owned Claude Code managed settings at
    /Library/Application Support/ClaudeCode/managed-settings.json — the tier that
    outranks user, project and `--settings` scope. Disabling it REMOVES the file
    on the next activation, not merely stops rewriting it
  '';

  # Gated on isDarwin like modules/darwin/ollama-daemon.nix, even though only
  # hosts/macos.nix imports this: the path is macOS-specific (§ THE PATH above),
  # so the gate keeps the module honest if it is ever imported more widely.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    # mkAfter, matching modules/system/etc.nix:42: nix-darwin's own
    # `system.checks` (macOS version, primaryUser, build users, Determinate) must
    # run first, and its `checkActivation` early-exit sits at the end of that
    # block — so a `darwin-rebuild check` skips this one, exactly as it skips
    # etc.nix's. Only the enabled branch guards: `removeScript` does its own
    # marker test and never writes.
    system.activationScripts.checks.text = lib.mkAfter (lib.optionalString cfg.enable ownershipCheck);

    # postActivation.text is `types.lines` and MERGES — core.nix and
    # ollama-daemon.nix already define it. No mkBefore/mkAfter: ordering is
    # irrelevant because nothing else in the fleet touches this path.
    system.activationScripts.postActivation.text = if cfg.enable then installScript else removeScript;

    # The rendered policy, surfaced so `checks.<system>.claude-managed-settings`
    # can read the BYTES this module installs rather than re-deriving them — a
    # check that rebuilt the attrset would pass while the file on disk said
    # something else. Inert: `system.build` is a plain attrset of derivations,
    # so nothing is added to the closure or to activation by naming it here.
    # Defined unconditionally, because a check that vanishes when someone sets
    # `enable = false` is a check that stops asking the question at exactly the
    # moment the answer changed.
    system.build.claudeManagedSettings = settingsFile;
  };
}
