# ---- Checks: `nix flake check` enforces formatting + lint + hooks ------
# Lint/format only, to keep merge CI fast. The host toplevels are
# deliberately NOT checks: BUILDING them (esp. the cold Pi kernel, ~1h) is
# a RELEASE-time concern. Merge CI instead EVALUATES the host configs
# (cheap, catches config/eval errors) without building — see
# .github/workflows/nix-ci.yml.
#
# `checks.formatting` and `checks.pre-commit` are NOT here: they come from the
# treefmt-nix / git-hooks.nix flakeModules in modules/parts/devshell.nix, and
# `checks.deploy-schema` from modules/parts/deploy.nix. flake-parts declares
# `checks` as `lazyAttrsOf types.package` (pinned modules/checks.nix:14), so all
# four files merge into one per-system attrset — and every entry must be a
# derivation, which is why none of these are a bare `runCommand` argument set.
{
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  inherit (config.fleet.identityArgs) loginName;
  # The published-gateway port, for the template-consumer check below. Read from
  # config.fleet — NOT identityArgs, which is the attrset a consumer replaces.
  inherit (config.fleet) publicMcpPort domainName;

  # The ONE shared shape in this file. It was born for `determinate-daemon`,
  # which is literally the same check run against two hosts whose contracts are
  # opposites (see both halves below); `nixpi-security-posture` is the third
  # consumer, and took it because it wants exactly this behaviour — report EVERY
  # broken leg, not the first. That is the bar for reaching for it. Every other
  # check here stays inline: a helper that served two unrelated checks would
  # just hide their differences.
  mkHostContract =
    {
      pkgs,
      name,
      subject,
      expect,
      advice,
    }:
    let
      broken = builtins.filter (e: !e.ok) expect;
    in
    pkgs.runCommand name { } (
      if broken == [ ] then
        ''
          echo "${subject}: ${toString (builtins.length expect)} assertions ok" > "$out"
        ''
      else
        ''
          echo "${name}: ${subject} — broken." >&2
          ${lib.concatMapStringsSep "\n" (e: ''echo "  ✘ ${e.name}" >&2'') broken}
          echo "" >&2
          ${lib.concatMapStringsSep "\n" (l: ''echo "${l}" >&2'') advice}
          exit 1
        ''
    );
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks =
        lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          # ---- bootstrap.sh is the ONE script no derivation wraps ------------
          #
          # Every other script in this tree is a `writeShellApplication`, which
          # shellchecks it at build time. `bootstrap.sh` cannot be: it runs on a
          # Mac that has no Nix yet, so it is plain bash copied out-of-band
          # through `curl … | bash`. That makes it the single highest-stakes
          # unlinted file here — it runs as the user, calls sudo, and deletes an
          # APFS volume.
          #
          # It carried a gate until 2026-09-15 (the `key-recovery-bootstrap`
          # derivation, which went with packages/key-recovery.nix). This is that
          # gate, standing on its own rather than riding a package that happened
          # to also ship the script.
          #
          # Since 2026-09-16 it also asserts the ONE invariant bootstrap.sh shares
          # with the flake. bootstrap.sh computes the clone directory from
          # `--flake` (`$HOME/Developer/github.com/$FLAKE_OWNER/$FLAKE_REPO`,
          # :144) while modules/parts/hosts.nix:19 computes the
          # /etc/nix-darwin symlink target from config.fleet's orgName/repoName —
          # two independent derivations of one path. hosts.nix:16 states the
          # consequence itself: the symlink "silently dangles if they ever
          # disagree", activation still SUCCEEDS, and `darwin-rebuild` then
          # ignores the broken link. So `activate`, the documented everyday
          # command, resolves its flake through a pointer at nothing and says
          # nothing. Shellcheck cannot see that; a string comparison can.
          bootstrap-lint =
            let
              expectedPrefix = "Developer/github.com/${config.fleet.orgName}/${config.fleet.repoName}";
              expectedFlake = "github:${config.fleet.orgName}/${config.fleet.repoName}";
              script = builtins.readFile ../../bootstrap.sh;
              problems =
                lib.optional (
                  !lib.hasInfix ''FLAKE_DEFAULT="${expectedFlake}"'' script
                ) "bootstrap.sh's FLAKE_DEFAULT is not ${expectedFlake}"
                ++ lib.optional (
                  !lib.hasInfix ''REPO_DIR="$HOME/Developer/github.com/$FLAKE_OWNER/$FLAKE_REPO"'' script
                ) "bootstrap.sh no longer builds the clone path as $HOME/Developer/github.com/<owner>/<repo>";
            in
            pkgs.runCommand "bootstrap-lint" { nativeBuildInputs = [ pkgs.shellcheck ]; } (
              ''
                shellcheck --shell=bash ${../../bootstrap.sh}
              ''
              + (
                if problems == [ ] then
                  ''
                    echo "bootstrap.sh clones to ~/${expectedPrefix}, which is what hosts.nix symlinks /etc/nix-darwin at" > "$out"
                  ''
                else
                  ''
                    echo "bootstrap-lint: bootstrap.sh and the flake disagree about where this repo lives." >&2
                    ${lib.concatStringsSep "\n" (map (x: ''echo "  ✘ ${x}" >&2'') problems)}
                    echo "modules/parts/hosts.nix builds /etc/nix-darwin -> ~/${expectedPrefix}/flake.nix." >&2
                    echo "A disagreement leaves that symlink DANGLING, and a dangling one is silent:" >&2
                    echo "activation succeeds and darwin-rebuild ignores the broken link." >&2
                    exit 1
                  ''
              )
            );

          # ---- The shell-init ORDERING contract, tested for the first time ----
          #
          # TWO modules write into the SAME three home-manager options, and the
          # whole correctness argument is which one lands first:
          #
          #   modules/features/keychain-secrets/module.nix  lib.mkAfter  (= 1500)
          #     exports every registered Keychain secret into the shell.
          #   modules/shared/claude-bedrock-gate.nix        lib.mkOrder 1600
          #     reads CLAUDE_CODE_USE_BEDROCK and unsets it when no AWS identity
          #     resolves from ~/.aws/config.
          #
          # Run the gate BEFORE the loader and it sees an UNSET variable and does
          # nothing at all — the failure is silent, degrades Claude Code to a
          # provider it cannot reach, and shows up as "no model responds", not as
          # a broken shell. Nothing checked it: 1500 is implicit in `mkAfter`,
          # 1600 is a bare literal in another file, and neither side type-checks
          # the other. Absorbing keychain-secrets (ADR-002 wave 4) is what made
          # this testable — the two halves are now in one evaluation.
          #
          # It reads the REAL macos config, not a fixture, for the same reason
          # nixpi-firmware-names reads the real nixpi: a fixture would pin the
          # numbers this check already knows and prove nothing about the host.
          # Darwin-only because both halves are darwin-gated.
          #
          # The loader's marker is DERIVED from `loaderRelPath` rather than
          # restated, so this cannot go stale if the default ever legitimately
          # moves.
          bedrock-gate-after-loader =
            let
              hm = config.flake.darwinConfigurations.macos.config.home-manager.users.${loginName};
              loaderMark = hm.local.keychainSecrets.loaderRelPath;
              # From claude-bedrock-gate.nix's `gateShell`. A shell variable
              # PRIVATE to that snippet, so it marks the gate without pinning the
              # test's shape: it used to be `CLAUDE_CODE_USE_BEDROCK+x` (a
              # presence test, correct while anthropics/claude-code#8063 made
              # every string truthy) and became a truthiness `case` once that was
              # fixed. This check is about ORDERING, not about how the gate
              # decides, so it should survive the next such change too.
              gateMark = "__bedrock_on";

              surfaces = {
                "programs.zsh.envExtra (~/.zshenv)" = hm.programs.zsh.envExtra;
                "programs.bash.profileExtra (~/.bash_profile)" = hm.programs.bash.profileExtra;
                "programs.bash.bashrcExtra (~/.bashrc)" = hm.programs.bash.bashrcExtra;
              };

              # Ordering without an index-of: split on the loader line, then ask
              # whether the gate appears in what came BEFORE it.
              verdict =
                text:
                if !(lib.hasInfix loaderMark text) then
                  "the Keychain loader line is missing entirely"
                else if !(lib.hasInfix gateMark text) then
                  "the Bedrock gate is missing entirely"
                else if lib.hasInfix gateMark (builtins.head (lib.splitString loaderMark text)) then
                  "the Bedrock gate runs BEFORE the Keychain loader"
                else
                  null;

              broken = lib.filterAttrs (_: v: v != null) (lib.mapAttrs (_: verdict) surfaces);
            in
            pkgs.runCommand "bedrock-gate-after-loader" { } (
              if broken == { } then
                ''
                  echo "shell-init order ok on ${toString (lib.length (lib.attrNames surfaces))} surfaces: loader (mkAfter/1500) then bedrock gate (mkOrder 1600)" > "$out"
                ''
              else
                ''
                  echo "bedrock-gate-after-loader: the shell-init ordering contract broke." >&2
                  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: ''echo "  ✘ ${k}: ${v}" >&2'') broken)}
                  echo "" >&2
                  echo "modules/shared/claude-bedrock-gate.nix uses lib.mkOrder 1600 and MUST" >&2
                  echo "run after modules/features/keychain-secrets/module.nix's lib.mkAfter" >&2
                  echo "(= mkOrder 1500), which is what exports CLAUDE_CODE_USE_BEDROCK from" >&2
                  echo "the Keychain in the first place. Reversed, the gate reads an unset" >&2
                  echo "variable, does nothing, and Claude Code silently keeps a Bedrock" >&2
                  echo "route it cannot use. Fix the priorities; do not relax this." >&2
                  exit 1
                ''
            );
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          # ---- Claude Desktop only accepts the stdio shape ----------------------
          #
          # modules/shared/claude-desktop.nix renders the MCP hub into Desktop's
          # claude_desktop_config.json. Desktop's parser is the narrowest client
          # in the fleet: {command, args, env} and nothing else — a `url` or
          # `type` key is rejected by its schema and the entry silently vanishes
          # from the app. The module's shim transform is what keeps that from
          # happening, and a future hub change (a new transport key, an upstream
          # transformMcpServer that stops stripping `type`) would break it
          # without any eval error. So: read the REAL rendering from the macos
          # config and assert its shape, plus the two agreements the module
          # makes with the rest of the tree — every gateway endpoint is present
          # (parity with Claude Code is the whole point), and desktop-commander
          # is not (it is a Desktop Extension already; twice = 20 duplicate tools).
          # The check that replaces two deleted assertions, and catches the
          # direction they could not.
          #
          # `local.mcpGateway.public` used to name a SUBSET to publish, and an
          # assertion refused a name the gateway did not host. It could not refuse
          # the opposite — a newly HOSTED server nobody remembered to publish —
          # which is exactly the silent failure worth guarding once "publish
          # everything" became the rule.
          #
          # terranix renders outside any host's module system and cannot read the
          # roster back, so `config.fleet.publicMcpServers` is a hand-kept mirror.
          # This makes the mirror mechanical: set equality, both directions.
          mcp-published-parity =
            let
              hm = config.flake.darwinConfigurations.macos.config.home-manager.users.${loginName};
              hosted = lib.naturalSort hm.local.mcpGateway.hostedServers;
              published = lib.naturalSort config.fleet.publicMcpServers;
              missing = lib.subtractLists published hosted;
              extra = lib.subtractLists hosted published;
              problems =
                lib.optional (
                  missing != [ ]
                ) "hosted but NOT published (terranix will never register them): ${toString missing}"
                ++ lib.optional (
                  extra != [ ]
                ) "published but NOT hosted (terranix registers a dead upstream): ${toString extra}";
            in
            pkgs.runCommand "mcp-published-parity" { } (
              if problems == [ ] then
                "echo 'mcp: hosted roster == fleet.publicMcpServers (${toString (lib.length hosted)} servers)' > $out"
              else
                ''
                  echo "mcp-published-parity: the gateway roster and config.fleet.publicMcpServers disagree." >&2
                  ${lib.concatMapStringsSep "\n" (x: ''echo "  ${x}" >&2'') problems}
                  echo "" >&2
                  echo "  Both must list every hosted server. Fix modules/parts/identity.nix" >&2
                  echo "  or the server set in modules/shared/mcp.nix." >&2
                  exit 1
                ''
            );

          # The reachability arm must be sourced from the GATEWAY, never from the
          # rendering it is checking. Until 2026-09-22 it was: `endpoints` read
          # `local.mcpGateway.endpoints`, the 26 loopback URLs, and the check
          # asserted every one reached Desktop. #572 deleted that option and
          # repointed the line at `renderedServers` — the same attrset as
          # `servers` — so `missing` became `filter (n: !(servers ? n))
          # (attrNames servers)`, which is `[ ]` for every possible input. The
          # arm went on reporting success while asserting nothing.
          #
          # There is no per-server endpoint set to compare against any more, so
          # the invariant that replaces it is the one the collapse created: the
          # portal URL mcp.nix builds must be what Desktop actually dials. That
          # still crosses a module boundary, which is the whole point — a check
          # whose two sides come from one expression can only ever pass.
          claude-desktop-config-shape =
            let
              hm = config.flake.darwinConfigurations.macos.config.home-manager.users.${loginName};
              servers = hm.local.claudeDesktop.renderedServers;
              portalEndpoint = hm.local.mcpGateway.portalEndpoint;
              # Flatten every rendered entry's argv; the portal is an mcp-remote
              # shim, so its URL rides in `args`, not in a `url` key (Desktop's
              # schema rejects one — that is what toStdioShim exists for).
              renderedArgs = lib.concatMap (s: s.args or [ ]) (builtins.attrValues servers);
              badShape = lib.filterAttrs (
                _: s: !(s ? command && s ? args) || s ? url || s ? type || !(s ? env && s.env ? NIX_CONFIG_MANAGED)
              ) servers;
              problems =
                lib.optional (
                  badShape != { }
                ) "non-stdio or unmarked entries: ${toString (builtins.attrNames badShape)}"
                ++
                  lib.optional (!(builtins.elem portalEndpoint renderedArgs))
                    "Desktop dials no entry at the gateway's portalEndpoint (${portalEndpoint}) — it would start with zero fleet servers"
                ++ lib.optional (
                  servers ? desktop-commander
                ) "desktop-commander rendered (it is a Desktop Extension already)";
            in
            pkgs.runCommand "claude-desktop-config-shape" { } (
              if problems == [ ] then
                ''
                  echo "claude-desktop: ${toString (lib.length (builtins.attrNames servers))} stdio-shaped entries, dialling the gateway portal at ${portalEndpoint}" > "$out"
                ''
              else
                ''
                  echo "claude-desktop-config-shape: the Desktop rendering broke its contract." >&2
                  ${lib.concatStringsSep "\n" (map (p: ''echo "  ✘ ${p}" >&2'') problems)}
                  echo "See modules/shared/claude-desktop.nix (toStdioShim / excludeServers)." >&2
                  exit 1
                ''
            );

          # ---- Rule 1d names the Pi in JavaScript, twice --------------------
          #
          # `.claude/hooks/pretooluse-bash-guard.js` is the ONLY mechanical block
          # on the fleet's most expensive irreversible failure: a build on the
          # LIVE Pi's SD card, recoverable only by physically reflashing it
          # (~40 min, docs/nixpi-sd-flashing-runbook.md). It identifies the Pi
          # with a literal regex, `nixpi(?:\.kattakath\.com|\.local)?`, because a
          # hook is plain node with no access to this flake.
          #
          # The hostname comes from nixosConfigurations and the domain from
          # config.fleet.domainName. Rename either and the guard matches nothing
          # — and the hook FAILS OPEN by construction (its catch emits
          # `{"decision":"approve"}`), so a non-match and a crash are
          # indistinguishable from "allowed". The rule-1d test suite carries the
          # SAME literal by hand, so it would keep passing against a guard that no
          # longer matches the real host. Two copies, one green CI, zero guard.
          #
          # This cannot make the hook read Nix, but it can make the rename LOUD:
          # a domain or host change now fails the build until both copies follow.
          rule1d-guard-knows-the-pi =
            let
              guard = builtins.readFile ../../.claude/hooks/pretooluse-bash-guard.js;
              suite = builtins.readFile ../../.claude/hooks/tests/rule1d-no-build-on-nixpi.sh;
              piName = "nixpi";
              # As it appears INSIDE the regex literal, where dots are escaped.
              escapedDomain = lib.replaceStrings [ "." ] [ "\\." ] domainName;
              problems =
                lib.optional (
                  !(config.flake.nixosConfigurations ? ${piName})
                ) "nixosConfigurations.${piName} is gone — rule 1d guards a host that no longer exists"
                ++
                  lib.optional (!(lib.hasInfix piName guard && lib.hasInfix escapedDomain guard))
                    "the guard's PI_HOSTS does not name ${piName}.${domainName} — it now matches NOTHING, and the hook fails open"
                ++
                  lib.optional (!(lib.hasInfix "${piName}.${domainName}" suite))
                    "the rule-1d suite does not exercise ${piName}.${domainName}, so it would pass against a disarmed guard";
            in
            pkgs.runCommand "rule1d-guard-knows-the-pi" { } (
              if problems == [ ] then
                ''
                  echo "rule 1d and its suite both name ${piName}.${domainName}" > "$out"
                ''
              else
                ''
                  echo "rule1d-guard-knows-the-pi: the nixpi build-block is out of sync with the fleet." >&2
                  ${lib.concatStringsSep "\n" (map (p: ''echo "  ✘ ${p}" >&2'') problems)}
                  echo "Update PI_HOSTS in .claude/hooks/pretooluse-bash-guard.js AND the PI=" >&2
                  echo "assignment in .claude/hooks/tests/rule1d-no-build-on-nixpi.sh." >&2
                  exit 1
                ''
            );

          # ---- The composition API, exercised AS A STRANGER WOULD -------------
          #
          # `lib.mkDarwin` / `lib.mkNixos` are published outputs (flakehub-publish
          # ships this flake `visibility: public`), and both grew a consumer hole
          # that nothing in the tree could see, because every in-tree caller is
          # the operator and passes the fleet's own values.
          #
          #   2026-09-15  mkDarwin { hostname = "macos"; } gave a stranger the
          #               operator's host: an admin account, two runner lanes,
          #               34 casks.                                  (c4a522a)
          #   2026-09-16  publicMcpPort was routed through identityArgs — the one
          #               attrset a consumer REPLACES — so a template-shaped
          #               four-field identity turned `local.mcpGateway.public`
          #               into "attribute 'publicMcpPort' missing", and only once
          #               they enabled the feature.
          #   2026-09-16  mkNixos still handed out `users.users.<operator>` with
          #               the operator's SSH key and trusted-users.
          #
          # Every one of those EVALUATED cleanly for the fleet. So this check
          # calls the builders the way templates/default/flake.nix does — a
          # neutral host, an identity with exactly the four fields the template
          # documents, nothing else — and FORCES the attributes that carry the
          # failure. Eval-only, which is all it needs to be: each of the three was
          # an eval error or an eval-visible value, and `nix flake check` is
          # eval-only too.
          #
          # Forcing the right leaf is load-bearing. `home.stateVersion` and the
          # agent's `.enable` both pass while the port is missing; only the argv
          # that embeds the port pulls it in.
          template-consumer =
            let
              # EXACTLY what templates/default/flake.nix documents. Do not add a
              # field here to make a failure go away — that is the bug.
              consumerIdentity = {
                loginName = "stranger";
                fullName = "A Stranger";
                userEmail = "stranger@example.invalid";
                domainName = "example.invalid";
              };

              mac = config.flake.lib.mkDarwin {
                system = "aarch64-darwin";
                hostname = "generic-darwin";
                identity = consumerIdentity;
                # No `users.users.stranger.home` here any more: hosts/generic-darwin.nix
                # declares the account itself since 2026-09-20 (ADR-004 §9.9). Adding it
                # by hand was what hid the gap from this check.
                extraModules = [
                  {
                    home-manager.users.stranger = {
                      home.stateVersion = "24.05";
                      # The opt-in that used to explode was `local.mcpGateway.public`,
                      # removed 2026-09-22 with the second proxy. What this check
                      # actually guards is that a template consumer can EVALUATE the
                      # gateway at all — the original failure was a missing
                      # identityArg, not anything about publishing — so it now reads
                      # the option that replaced it.
                      local.mcpGateway.telegram.enable = false;
                    };
                  }
                ];
              };
              macHm = mac.config.home-manager.users.stranger;

              box = config.flake.lib.mkNixos {
                system = "aarch64-linux";
                hostname = "generic-linux";
                identity = consumerIdentity;
                # Deliberately NO operatorSshKey — a consumer does not pass one.
                extraModules = [
                  {
                    system.stateVersion = "24.05";
                    networking.hostName = "strangerbox";
                  }
                ];
              };
              boxUsers = box.config.users.users;

              problems =
                # Forces publicMcpPort through the agent's argv.
                lib.optional (
                  !lib.any (a: a == toString publicMcpPort) macHm.launchd.agents.mcp-gateway.config.ProgramArguments
                ) "the gateway agent does not bind publicMcpPort for a template consumer"
                ++ lib.optional (
                  boxUsers ? ${loginName}
                ) "mkNixos created the OPERATOR's account (${loginName}) on a consumer's host"
                ++ lib.optional (
                  boxUsers.stranger.openssh.authorizedKeys.keys != [ ]
                ) "mkNixos granted SSH keys a consumer never asked for"
                ++ lib.optional (lib.elem loginName box.config.nix.settings.trusted-users) "mkNixos put the operator in a consumer's nix trusted-users";
            in
            pkgs.runCommand "template-consumer" { } (
              if problems == [ ] then
                ''
                  echo "mkDarwin + mkNixos evaluate for a four-field template identity, and leak no operator state" > "$out"
                ''
              else
                ''
                  echo "template-consumer: the published composition API leaks or breaks." >&2
                  ${lib.concatStringsSep "\n" (map (p: ''echo "  ✘ ${p}" >&2'') problems)}
                  echo "See modules/parts/compose.nix — identityArgs is REPLACED by a consumer;" >&2
                  echo "fleet constants belong in mkHomeManagerModule's inherit list instead." >&2
                  exit 1
                ''
            );

          # ---- Determinate owns this daemon, so `nix.*` here is INERT ---------
          #
          # PRs #542/#543 put the whole fleet on Determinate Nix. On the Mac the
          # module's contract is SUBTRACTIVE: `determinateNix.enable` implies
          # `nix.enable = false`, so nix-darwin renders no /etc/nix/nix.conf at
          # all and determinate-nixd owns the daemon outright. Every consequence
          # of that is invisible to the evaluator:
          #
          #   - anything written to `nix.settings` on this host is DROPPED. Not
          #     an error, not a warning — the option still type-checks, still
          #     evaluates, and renders nothing. That is why the Cachix
          #     substituter and the operator's trusted-users grant live in
          #     `determinateNix.customSettings` (modules/parts/compose.nix), and
          #     why this asserts they are STILL there. A future edit that
          #     "tidies" them back onto nix.settings evaluates clean and quietly
          #     un-trusts the operator — whose only documented escape from the
          #     nixpi narinfo negative-cache trap is a client-side
          #     --narinfo-cache-negative-ttl that an untrusted daemon discards.
          #   - `nix.linux-builder` stays unusable, because it REQUIRES
          #     nix.enable = true (nix-darwin#1505). Flipping `nix.enable` back is
          #     therefore not a small change: it takes nix.conf off Determinate.
          #   - `external-builders` is reserved — Determinate renders it itself
          #     for the native Linux builder and customSettings asserts on it.
          #     Upstream's assert is the real gate; this line exists so the rule
          #     is legible NEXT TO the settings that are allowed, rather than
          #     discovered by tripping it.
          #
          # Darwin-gated to the CI leg that already evaluates this host
          # (.github/workflows/nix-ci.yml). The nixpi half lives in the isLinux
          # block below and asserts the OPPOSITE things, on purpose.
          #
          # NOT COVERED: this reads the Nix-side declaration only. It cannot see
          # whether determinate-nixd is actually running, whether the account
          # entitlement at dtr.mn/features is live, or whether the local daemon
          # is logged in to FlakeHub — and that last one is what makes
          # `native-linux-builder` silently vanish. Those are runtime facts; the
          # runbook owns them (docs/new-mac-runbook.md).
          determinate-daemon =
            let
              mac = config.flake.darwinConfigurations.macos.config;
              custom = mac.determinateNix.customSettings or { };
            in
            mkHostContract {
              inherit pkgs;
              name = "determinate-daemon";
              subject = "macos: Determinate owns /etc/nix/nix.conf";
              expect = [
                {
                  name = "determinateNix.enable is true (the darwin module is in the module list)";
                  ok = mac.determinateNix.enable or false;
                }
                {
                  name = "nix.enable is false — nix-darwin must NOT render a second nix.conf";
                  ok = !(mac.nix.enable or true);
                }
                {
                  name = "the Cachix substituter is routed through customSettings, where it is not silently dropped";
                  ok = (custom.extra-substituters or [ ]) != [ ];
                }
                {
                  name = "its trusted public key rides the same path";
                  ok = (custom.extra-trusted-public-keys or [ ]) != [ ];
                }
                {
                  name = "the operator is in extra-trusted-users, or the daemon discards their client settings";
                  ok = (custom.extra-trusted-users or [ ]) != [ ];
                }
                {
                  name = "external-builders is NOT hand-set (reserved; Determinate renders it)";
                  ok = !(custom ? external-builders);
                }
              ];
              advice = [
                "modules/parts/compose.nix sets determinateNix.enable, which implies"
                "nix.enable = false. With it off, nix-darwin renders NO /etc/nix/nix.conf,"
                "so every nix.settings line on this host is silently inert — the cache, the"
                "trusted-users grant and the rest belong in determinateNix.customSettings."
                "Do not 'fix' this by re-enabling nix.enable; that takes the daemon back"
                "from determinate-nixd. See PRs #542/#543 and CLAUDE.md, aarch64-linux builds."
              ];
            };

          # ---- The managed floor is not silently empty -------------------------
          #
          # modules/darwin/claude-managed-settings.nix installs a ROOT-OWNED policy
          # file that outranks user and project scope, and its secret-value denies
          # are a hand-maintained DUPLICATE of the user-scope list in
          # modules/shared/claude-guardrails.nix. That duplication is deliberate —
          # deriving one from the other yields [ ] the moment a rule is reworded,
          # and a well-formed EMPTY floor is the failure this repo has recorded
          # twice — but a duplicate with no gate drifts the first time only one
          # side is edited.
          #
          # This reads the BYTES the module installs (system.build.claudeManagedSettings,
          # the very derivation the activation script copies) rather than rebuilding
          # the attrset, because a check that re-derives its subject agrees with
          # itself while the file on disk says something else.
          #
          # THE CLASSIFIER IS ITSELF GATED, and that is the point. `secretRules`
          # below selects the secret-value family out of the user list by pattern.
          # If a future reword made that pattern match NOTHING, the superset test
          # would pass over an empty set — the exact vacuum this check exists to
          # catch, reintroduced inside the check. So the count is asserted first:
          # the classifier must keep finding at least as many rules as it finds
          # today, or this check fails and asks to be re-read.
          #
          # NOT COVERED: that Claude Code ACCEPTS every key. `pkgs.formats.json`
          # guarantees the bytes parse, and a superset test guarantees nothing was
          # dropped — but an unrecognised key is accepted, listed and enforces
          # nothing, which only `/status` on the running Mac can reveal. That step
          # is in docs/new-mac-runbook.md, and it is a runtime fact, not an eval one.
          claude-managed-settings =
            let
              mac = config.flake.darwinConfigurations.macos.config;
              hm = mac.home-manager.users.${loginName};
              userDeny = hm.programs.claude-code.settings.permissions.deny or [ ];
              # The secret-value family, by the verbs that PRINT a secret.
              secretRules = builtins.filter (
                r:
                builtins.match ".*(secret reveal|find-generic-password|find-internet-password|agenix|/run/agenix).*" r
                != null
              ) userDeny;
              # Today's count, pinned. Raise it deliberately when the family grows;
              # a DROP means either a real retraction or a reworded rule the pattern
              # above no longer sees, and both deserve a human.
              minSecretRules = 12;
            in
            pkgs.runCommand "claude-managed-settings"
              {
                managed = mac.system.build.claudeManagedSettings;
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                if [ "${toString (builtins.length secretRules)}" -lt "${toString minSecretRules}" ]; then
                  echo "claude-managed-settings: the secret-rule CLASSIFIER now matches only ${toString (builtins.length secretRules)} rules (expected >= ${toString minSecretRules})." >&2
                  echo "" >&2
                  echo "This check filters modules/shared/claude-guardrails.nix's deny list by pattern to" >&2
                  echo "decide what the managed floor must also carry. A shrinking match means a rule was" >&2
                  echo "reworded out of the pattern, not that policy relaxed — so the superset test below" >&2
                  echo "would have started passing over a smaller set. Re-read both lists, then either fix" >&2
                  echo "the pattern or lower minSecretRules on purpose." >&2
                  exit 1
                fi

                jq -e 'type == "object"' "$managed" > /dev/null

                managedDeny=$(jq -r '.permissions.deny // [] | .[]' "$managed")
                if [ -z "$managedDeny" ]; then
                  echo "claude-managed-settings: the MANAGED permissions.deny list is EMPTY." >&2
                  echo "A well-formed, root-owned, completely empty floor is the silent-vacuum failure" >&2
                  echo "modules/shared/claude-guardrails.nix records twice. Restore the rules." >&2
                  exit 1
                fi

                missing=0
                while IFS= read -r rule; do
                  [ -n "$rule" ] || continue
                  if ! printf '%s\n' "$managedDeny" | grep -qxF "$rule"; then
                    echo "  MISSING from the managed floor: $rule" >&2
                    missing=1
                  fi
                done <<< "${lib.concatStringsSep "\n" secretRules}"

                if [ "$missing" -ne 0 ]; then
                  echo "" >&2
                  echo "claude-managed-settings: modules/shared/claude-guardrails.nix denies the rules above," >&2
                  echo "but modules/darwin/claude-managed-settings.nix does not. The two lists are a" >&2
                  echo "deliberate duplicate (deriving one yields [ ] on a reword), so an edit to one" >&2
                  echo "must be made in the other. Add them and re-run." >&2
                  exit 1
                fi

                echo "managed floor carries all ${toString (builtins.length secretRules)} secret-value rules from the user scope" > "$out"
              '';
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # ---- The four names a reflash depends on, pinned ---------------------
          #
          # ADR-002 wave 3 moved the Cloudflare Tunnel connector in-tree as a
          # capsule. The dangerous edit there is not a behaviour change — it is a
          # RENAME, because three separate modules agree on strings and nothing
          # type-checks the agreement:
          #
          #   hosts/nixpi.nix orders the firmware-planted token
          #     `before`/`requiredBy` "cloudflared-connector.service", a name the
          #     CAPSULE owns.
          #   local.firmwareProvisioning derives "firmware-file-<key>.service"
          #     from each attribute key, and hosts/nixpi.nix's supplicant override
          #     names "firmware-file-wifi.service" back by hand.
          #   The /run targets are the handoff between the firmware partition and
          #     the two consumers.
          #
          # A rename anywhere in that triangle still EVALUATES, still passes
          # `nix flake check`, and still passes `--dry-activate` on a card that was
          # provisioned before the rename — the units are already on disk. It only
          # bites on the NEXT FLASH, when the ordering edge silently no longer
          # exists: the connector starts before its token is copied, or the Wi-Fi
          # supplicant before its conf. On a headless Pi reachable ONLY through
          # that connector, that is a ~40-minute trip to the shelf and a full
          # verified re-flash (docs/nixpi-sd-flashing-runbook.md).
          #
          # Values measured against the live config on 2026-09-12, before the
          # capsule move. Linux-only for the same reason the capsule's own check
          # is: `nixpi` is an aarch64-linux host and CI evaluates it on that leg.
          nixpi-firmware-names =
            let
              c = config.flake.nixosConfigurations.nixpi.config;
              svc = c.systemd.services;

              # EVERY lookup goes through these, and that is the point. Reading
              # `svc.cloudflared-connector` directly makes the FIRST failure mode
              # this check exists to catch — a renamed unit — come out as
              # `error: attribute 'cloudflared-connector' missing` from inside a
              # trivial-builder stack trace, instead of the explanation below.
              # Measured: it does exactly that. A guard that degrades into an
              # eval error is a guard whose message nobody reads.
              unit = n: svc.${n} or { };
              has = n: svc ? ${n};
              orders = n: field: lib.elem "cloudflared-connector.service" ((unit n).${field} or [ ]);

              expect = [
                {
                  name = "unit firmware-file-cloudflared-token.service exists";
                  ok = has "firmware-file-cloudflared-token";
                }
                {
                  name = "unit firmware-file-wifi.service exists";
                  ok = has "firmware-file-wifi";
                }
                {
                  name = "unit cloudflared-connector.service exists";
                  ok = has "cloudflared-connector";
                }
                {
                  name = "connector reads /run/cloudflared-token as its EnvironmentFile";
                  ok =
                    (unit "cloudflared-connector").serviceConfig.EnvironmentFile or null == "/run/cloudflared-token";
                }
                {
                  name = "the planted token is ordered before cloudflared-connector.service";
                  ok = orders "firmware-file-cloudflared-token" "before";
                }
                {
                  name = "cloudflared-connector.service requires the planted token";
                  ok = orders "firmware-file-cloudflared-token" "requiredBy";
                }
                {
                  name = "supplicant reads /run/wpa_supplicant-firmware.conf";
                  ok = c.networking.supplicant.wlan0.configFile.path == "/run/wpa_supplicant-firmware.conf";
                }
                {
                  name = "supplicant is gated on /run/wpa_supplicant-firmware.conf existing";
                  ok =
                    (unit "supplicant-wlan0").unitConfig.ConditionPathExists or null
                    == "/run/wpa_supplicant-firmware.conf";
                }
                {
                  name = "supplicant is ordered after firmware-file-wifi.service";
                  ok = lib.elem "firmware-file-wifi.service" ((unit "supplicant-wlan0").after or [ ]);
                }
              ];
              broken = builtins.filter (e: !e.ok) expect;
            in
            pkgs.runCommand "nixpi-firmware-names" { } (
              if broken == [ ] then
                ''
                  echo "nixpi firmware/connector contract: ${toString (builtins.length expect)} assertions ok" > "$out"
                ''
              else
                ''
                  echo "nixpi-firmware-names: the firmware -> /run -> consumer contract broke." >&2
                  ${lib.concatMapStringsSep "\n" (e: ''echo "  ✘ ${e.name}" >&2'') broken}
                  echo "" >&2
                  echo "These names are agreed by STRING across hosts/nixpi.nix," >&2
                  echo "modules/features/cloudflared-connector/ and" >&2
                  echo "modules/features/firmware-secrets/. A break here evaluates fine" >&2
                  echo "and --dry-activates fine on an" >&2
                  echo "ALREADY-PROVISIONED card; it only surfaces on the next flash, as a" >&2
                  echo "Pi that never brings its tunnel up. Fix the name, do not relax this." >&2
                  exit 1
                ''
            );

          # ---- Determinate owns this daemon TOO — and `nix.*` stays LIVE ------
          #
          # The mirror of the darwin `determinate-daemon` above, and the whole
          # reason it is a separate list: it is NOT the same contract. The pinned
          # input's modules/nixos.nix is ADDITIVE — it swaps `nix.package` for
          # Determinate's Nix, points nix-daemon's ExecStart at determinate-nixd,
          # and merely RETARGETS the generated conf to /etc/nix/nix.custom.conf,
          # which the nixd-managed /etc/nix/nix.conf includes. `nix.settings`
          # therefore keeps applying, and both modules/nixos/core.nix and
          # modules/shared/nix-cache.nix are written assuming exactly that.
          #
          # The expensive failure guarded here is ONE substituter.
          # install.determinate.systems is the only cache holding the prebuilt
          # aarch64-linux Determinate Nix (verified 2026-09-21 in nix-cache.nix:
          # a HIT there, a MISS on cache.nixos.org AND on Cachix). Lose that line
          # — by dropping the module, by copying the darwin side's
          # `nix.enable = false` across, or by editing nix-cache.nix — and
          # nixpi's closure now contains a Nix that must be COMPILED FROM C++
          # SOURCE. On a Pi 4 that CLAUDE.md says must never build at all, that is
          # the ~40-minute reflash (docs/nixpi-sd-flashing-runbook.md), arrived at
          # without a single eval error and without failing `nix flake check`.
          #
          # Every lookup goes through `or`, for the reason nixpi-firmware-names
          # states directly above: drop the module and `config.determinate` stops
          # existing, so a direct read degrades into "attribute 'determinate'
          # missing" inside a trivial-builder stack trace instead of the
          # explanation below. A guard whose message nobody reads is not a guard.
          #
          # NOT COVERED: `nix.settings` being live is asserted, not the content of
          # /etc/nix/nix.conf on the running Pi — the file is rendered at
          # activation and this is eval. It also says nothing about nixvm, which
          # gets the same module and would be a second (cheap) host to add if it
          # ever stops being throwaway.
          determinate-daemon =
            let
              pi = config.flake.nixosConfigurations.nixpi.config;
              # toString, not lib.any: the option is a LIST here but is a bare
              # string in plenty of systemd modules, and the check should survive
              # that rather than throw. Only the bool escapes, so the store path
              # inside never becomes a build input of this derivation.
              execStart = toString (pi.systemd.services.nix-daemon.serviceConfig.ExecStart or "");
              subs = pi.nix.settings.extra-substituters or [ ];
            in
            mkHostContract {
              inherit pkgs;
              name = "determinate-daemon";
              subject = "nixpi: Determinate runs the daemon, nix.settings still applies";
              expect = [
                {
                  name = "determinate.enable is true (the nixosModule is in the module list)";
                  ok = pi.determinate.enable or false;
                }
                {
                  name = "nix.package is Determinate's Nix, not nixpkgs'";
                  ok = (pi.nix.package.pname or "") == "determinate-nix";
                }
                {
                  name = "nix-daemon.service execs determinate-nixd";
                  ok = lib.hasInfix "determinate-nixd" execStart;
                }
                {
                  name = "the generated nix.conf is retargeted to nix/nix.custom.conf";
                  ok = (pi.environment.etc."nix/nix.conf".target or null) == "nix/nix.custom.conf";
                }
                {
                  name = "nix.enable is still TRUE — unlike darwin, nix.settings must keep rendering";
                  ok = pi.nix.enable or false;
                }
                {
                  name = "install.determinate.systems is a substituter, or this Pi BUILDS Nix from source";
                  ok = lib.elem "https://install.determinate.systems" subs;
                }
              ];
              advice = [
                "modules/parts/compose.nix wires determinate.nixosModules.default into"
                "every NixOS host, and modules/shared/nix-cache.nix supplies the ONE"
                "substituter that has a prebuilt aarch64-linux Determinate Nix."
                "Without both, nixpi's next generation compiles Nix from C++ source on an"
                "SD card that CLAUDE.md says must never build. Fix the wiring; do not"
                "relax this, and never answer it by building on the Pi."
              ];
            };
        }
        // {
          # ---- The two indexes CLAUDE.md promises to keep, kept -----------------
          #
          # CLAUDE.md opens by calling itself "an index, not an encyclopedia" and
          # binds the author: "When you change repo shape, update the one-liner
          # here AND the section there." Nothing enforced that, and both halves had
          # already drifted when this was written (2026-09-21):
          #
          #   · hosts/generic-darwin.nix and hosts/generic-linux.nix — load-bearing
          #     (templates/default/flake.nix builds on them, and checks.template-consumer
          #     is the gate that keeps a stranger's identity working) — appeared in
          #     NEITHER CLAUDE.md nor docs/repo-map.md. Zero hits in both.
          #   · docs/private-home-modules.md — 11 live references across .nix and
          #     other docs — was linked from neither index.
          #
          # Both are readDir-vs-readFile, the same shape as capsule-registry, and
          # both are identical and cheap on BOTH systems, so they sit in the
          # ungated block for the reason secrets-sync gives: an eval plus an echo
          # with nothing platform-specific in either half.
          #
          # SUBSTRING, not a parsed list. A parser over CLAUDE.md's prose would
          # break on every table reflow and become the thing people delete. The
          # question worth mechanising is only "is this file NAMED anywhere the
          # reader would look" — a file nobody mentions is the failure; the exact
          # sentence is a human's call.
          #
          # The substring test is `grep -F` IN THE BUILDER — NOT lib.hasInfix at
          # eval time. Do not "simplify" it back. hasInfix compiles to
          # `builtins.match ".*<needle>.*"`, and a leading `.*` makes std::regex
          # recurse once per input character: against docs/repo-map.md (175 KB)
          # that is ~175k stack frames, which overflows the nix-eval-jobs worker
          # and SIGSEGVs — reported as "possible infinite recursion", which it is
          # not. It fails on aarch64-linux while PASSING on aarch64-darwin (the
          # two std::regex implementations size their frames differently), so it
          # reads as a one-platform mystery rather than an input-size ceiling.
          # Measured 2026-09-21: docs-indexed shipped green on the Mac and was
          # red on the Linux leg of every nix-ci run from the commit that added
          # it. grep -F is a fixed-string scan — no stack growth, no regex
          # metacharacters to escape — and a 175 KB search belongs in a builder
          # anyway. hosts-documented only escaped the crash by short-circuiting
          # on CLAUDE.md first; it is one unmentioned host away from the same
          # SIGSEGV, so both moved.
          #
          # NOT COVERED: that the mention is TRUE or current. A row naming a file
          # and describing it wrongly passes both checks. These catch absence, not
          # rot — and rot is what /hygiene and a reader are for.
          hosts-documented =
            let
              hostFiles = lib.naturalSort (
                lib.attrNames (
                  lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) (builtins.readDir ../../hosts)
                )
              );
            in
            pkgs.runCommand "hosts-documented"
              {
                indexes = [
                  ../../CLAUDE.md
                  ../../docs/repo-map.md
                ];
              }
              ''
                undocumented=()
                for f in ${lib.escapeShellArgs hostFiles}; do
                  hit=
                  for idx in $indexes; do
                    if grep -qF -- "$f" "$idx"; then
                      hit=1
                      break
                    fi
                  done
                  [ -n "$hit" ] || undocumented+=("$f")
                done

                if [ ''${#undocumented[@]} -eq 0 ]; then
                  echo "hosts/: all ${toString (lib.length hostFiles)} host profiles are named in CLAUDE.md or docs/repo-map.md" > "$out"
                  exit 0
                fi

                echo "hosts-documented: host profiles that no index names." >&2
                printf '  %s\n' "''${undocumented[@]}" >&2
                echo "" >&2
                echo "CLAUDE.md calls itself an index and binds the author to update it when repo" >&2
                echo "shape changes. A host file named nowhere is invisible to the next reader and" >&2
                echo "to every agent that reads CLAUDE.md as its map. Name it in the hosts/ row of" >&2
                echo "CLAUDE.md, or in the matching section of docs/repo-map.md, and re-run." >&2
                exit 1
              '';

          docs-indexed =
            let
              docFiles = lib.naturalSort (
                lib.attrNames (
                  lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n && n != "repo-map.md") (
                    builtins.readDir ../../docs
                  )
                )
              );
            in
            pkgs.runCommand "docs-indexed"
              {
                indexes = [
                  ../../CLAUDE.md
                  ../../docs/repo-map.md
                ];
              }
              ''
                unlinked=()
                for f in ${lib.escapeShellArgs docFiles}; do
                  hit=
                  for idx in $indexes; do
                    if grep -qF -- "$f" "$idx"; then
                      hit=1
                      break
                    fi
                  done
                  [ -n "$hit" ] || unlinked+=("$f")
                done

                if [ ''${#unlinked[@]} -eq 0 ]; then
                  echo "docs/: all ${toString (lib.length docFiles)} documents are referenced from CLAUDE.md or repo-map.md" > "$out"
                  exit 0
                fi

                echo "docs-indexed: documents no index references." >&2
                printf '  docs/%s\n' "''${unlinked[@]}" >&2
                echo "" >&2
                echo "An unlinked document is one nobody finds and nobody updates, which is how a" >&2
                echo "runbook rots into a trap. Link it from CLAUDE.md's Documentation list or from" >&2
                echo "docs/repo-map.md. repo-map.md itself is exempt: it is the index, not an entry." >&2
                exit 1
              '';

          # ---- nixpi's security posture, which until now only PROSE held ------
          #
          # modules/nixos/core.nix:46-102 carries three careful paragraphs on why
          # sshd binds loopback only, why `openFirewall = false` is the knob that
          # actually keeps 22 shut, and why the TCP allow-list stays tiny. A
          # comment cannot fail a build. Every one of those lines is a one-token
          # edit away from reopening the LAN path that the Cloudflare Access
          # application in front of nixpi.<domain> is meant to be the only way
          # through — and Access enforces at the EDGE, so a LAN connection to
          # port 22 is not merely unauthenticated, it produces NO ACCESS LOG AT
          # ALL. There is nothing to notice afterwards. That is what makes this
          # worth an eval-time gate rather than a comment.
          #
          # Each leg names its own silent-failure mode:
          #
          #   openFirewall — upstream's default is TRUE (pinned nixpkgs
          #     nixos/modules/services/networking/ssh/sshd.nix:312, and :874 feeds
          #     cfg.ports straight into allowedTCPPorts). It is false ONLY because
          #     core.nix:55 says so, so deleting that one line reopens 22 on the
          #     LAN with no other file changing.
          #   listenAddresses NON-EMPTY is its own leg, and deliberately comes
          #     before the all-loopback leg: an EMPTY list emits no ListenAddress
          #     line at all, and OpenSSH then binds the WILDCARD. `all isLoopback
          #     [ ]` is true — the vacuous pass would assert the exact opposite of
          #     the truth. The loopback leg is then a sorted EQUALITY rather than
          #     a subset test, so it also proves both families are still bound.
          #   the RENDERED ListenAddress lines are a leg of their own, because
          #     reading the listenAddresses OPTION is not the same as reading what
          #     sshd will parse. `services.openssh.extraConfig` is where upstream
          #     puts its OWN generated block (mkOrder 0, sshd.nix:893-902); an
          #     operator's text merges AFTER it (types.lines, :749-752), and
          #     sshd.nix:85-89 cats the whole string into sshd_config verbatim.
          #     sshd treats ListenAddress CUMULATIVELY, so
          #     `extraConfig = "ListenAddress 0.0.0.0"` adds a wildcard bind while
          #     listenAddresses — and therefore every option-reading leg here —
          #     stays exactly as it was. Measured: all thirteen legs this check
          #     had before went green under precisely that override. The corollary
          #     is why the leg PARSES rather than greps: `hasInfix "ListenAddress"
          #     extraConfig` is TRUE on a healthy host, because upstream's own
          #     generated block lives in the same string.
          #   no explicit `port` on a listen address, because nixpkgs renders
          #     `ListenAddress ::1:22` UNBRACKETED (sshd.nix:901). OpenSSH reads
          #     that as the address ::0.1.0.34, the v6 bind fails EADDRNOTAVAIL,
          #     and sshd SURVIVES (a failed bind is fatal only if EVERY bind
          #     fails) — so v6 loopback silently vanishes. Measured with
          #     `sshd -G`; the transcript is at core.nix:65-74.
          #   the firewall allow-list is FOUR legs, not one. nixpi runs the
          #     IPTABLES backend (networking.nftables.enable is false, measured),
          #     and firewall-iptables.nix renders the same `-j nixos-fw-accept`
          #     rule from three independent inputs: allowedTCPPorts (:164-165),
          #     allowedTCPPortRanges (:182-183), and — for both of those — the
          #     PER-INTERFACE sets, since every one of those loops walks
          #     `cfg.allInterfaces`, which is `interfaces` merged under a
          #     "default" key (firewall.nix:305-311). Measured: a
          #     `[ { from = 22; to = 22; } ]` range and an
          #     `interfaces.eth0.allowedTCPPorts = [ 22 ]` EACH reopened 22 with
          #     the allowedTCPPorts leg still green. `trustedInterfaces` is the
          #     fourth and bluntest: :149 accepts ALL traffic arriving on a named
          #     interface, no port list consulted. Upstream sets it to [ "lo" ]
          #     itself (firewall.nix:334), so the leg pins that value rather than
          #     emptiness.
          #   buildMachines empty is a SEPARATE leg from distributedBuilds,
          #     because upstream says in its own words that the latter does not
          #     inhibit the former: nixos/modules/config/nix-remote-build.nix:227,
          #     with :248 rendering /etc/nix/machines on `buildMachines != [ ]`
          #     alone. A stale machines file then sits there for any later
          #     `--builders @/etc/nix/machines` to pick up. `nix.settings.builders`
          #     is a third leg because upstream nulls it only WHILE
          #     distributedBuilds is false (:253) — reading the rendered value
          #     catches an edit that re-enables one without the other.
          #
          # The TCP leg pins [ 80 ] rather than [ ], because that is the truth:
          # hosts/nixpi.nix:215 opens the Caddy ORIGIN port (443 omitted — TLS
          # terminates at Cloudflare's edge) and core.nix:100's [ ] MERGES with
          # it. Port 80 is therefore genuinely reachable on the LAN today; this
          # check's job is to make WIDENING that list loud, not to bless its
          # current width. A legitimate new port means editing this literal on
          # purpose — that friction is the feature, so do not answer a failure
          # here by deleting the leg.
          #
          # Why not nixpkgs' own `assertions`: its only natural home is
          # modules/nixos/core.nix, which nixvm and every `lib.mkNixos` consumer
          # also import — baking "exactly one open TCP port" in there breaks a
          # stranger's host, the precise leak the template-consumer check above
          # exists to prevent. `assertions` also reports one message where
          # mkHostContract reports every broken leg. This is a FLEET contract
          # about one named host, not a host contract.
          #
          # Every lookup goes through `or`, with the default chosen to FAIL —
          # `allowedTCPPorts or null`, never `or [ ]` — for the reason
          # nixpi-firmware-names gives above: a dropped module must produce THIS
          # message, not "attribute missing" from inside a trivial-builder stack
          # trace.
          #
          # `or` does NOT cover a listen address's `addr`, and assuming it did
          # was a live bug here. The submodule declares `addr` as `nullOr str`
          # with default null (sshd.nix:325-328), so the attribute always EXISTS:
          # `a.addr or ""` never fires, and a malformed entry reached
          # `null < "127.0.0.1"` — a throw, which is precisely the
          # trivial-builder stack trace the paragraph above refuses to emit. The
          # addresses are therefore collected, swept for null by a leg of their
          # own, and only then compared. `&&` is lazy in its right operand, and
          # BOTH guarded legs need that: the same malformed entry also makes
          # upstream's own render throw, because sshd.nix:901 interpolates
          # `addr` straight into a string ("cannot coerce null to a string",
          # measured), and the rendered-ListenAddress leg is the one thing here
          # that forces extraConfig.
          #
          # Ungated, like secrets-sync below and unlike the two nixpi checks in
          # the isLinux block above: this is an eval plus an echo, with nothing
          # aarch64-linux about either half. Both legs are worth paying for
          # because the edits it guards are made ON the Mac — Linux-gating it
          # would let an operator relax core.nix, run `/eval` clean, and learn
          # otherwise only from CI minutes later. Cost measured 2026-09-21: one
          # extra nixpi module eval on the darwin leg (~1 s here; nothing else on
          # that leg forces this config — rule1d-guard-knows-the-pi above reads
          # only whether the ATTRIBUTE exists), and no aarch64-linux build,
          # because only numbers and strings escape into the derivation.
          #
          # NOT COVERED: this is EVAL, not runtime — no `sshd -G`, no
          # `iptables -S`, and an already-flashed Pi keeps whatever its current
          # generation has until the next deploy. Four further paths are known
          # and deliberately ungated:
          #
          #   `networking.firewall.extraCommands` — the iptables backend's raw
          #     escape hatch (firewall-iptables.nix:235, option at :290). It is
          #     already NON-EMPTY on nixpi (the nat module contributes its own
          #     teardown preamble), so there is no empty-string baseline to
          #     assert, and a hand-written
          #     `ip46tables -A nixos-fw --dport 22 -j nixos-fw-accept` inside it
          #     is invisible to every leg above.
          #   `extraInputRules` — not a path on this host at all: it exists only
          #     in firewall-nftables.nix (:24-26, rendered at :179), and nixpi is
          #     on iptables. Flipping networking.nftables.enable moves the whole
          #     rule set to a renderer none of these legs read, so that flip needs
          #     new legs rather than an edit to these.
          #   UDP, ports and ranges both. The failure this check exists to catch
          #     is an unauthenticated, unlogged path to sshd, and sshd is TCP.
          #   the rest of sshd_config. A `Port` smuggled through extraConfig is
          #     harmless here — the binds stay loopback and the allow-list is
          #     pinned — but nothing above reads, say, a `Match` block that
          #     relaxes one of the auth settings.
          #
          # It cannot see the MAC side either, so "nixpi must never BUILD" stays
          # owned by .claude/hooks/pretooluse-bash-guard.js Rule 1d and
          # deploy.nix's `remoteBuild = false`; note too that buildMachines ON
          # nixpi would make it a build CLIENT dispatching work OUT, not a
          # builder — the build legs here are about a leaf host growing outbound
          # build trust (an SSH build key on an SD card, activation newly
          # depending on a reachable builder) and about that stray
          # /etc/nix/machines, NOT about the Pi compiling. Nothing here stops the
          # Pi compiling locally either: nix.settings max-jobs is "auto" today,
          # so a cache miss still grinds the SD card; `max-jobs = 0` in
          # hosts/nixpi.nix is the change that would mechanise that, and it is
          # deliberately not asserted from here. The Access application itself
          # lives in Cloudflare's API (infra/cloudflare/nixpi-tunnel.nix) and its
          # 2026-08-20 disappearance was invisible to eval then and still is. And
          # it says nothing about nixvm, which shares modules/nixos/core.nix.
          #
          # Values measured against the live config on 2026-09-21.
          # The watchdog and the firmware-secrets capsule share three facts, and
          # NOTHING but this check makes them agree: the runtime wpa config path,
          # the card filename behind it, and the unit that consumes it. Rename any
          # of them in one place and the watchdog keeps evaluating, keeps starting,
          # and silently rewrites or restarts the wrong thing — the failure only
          # shows up during an outage, which is the one moment nobody can debug it
          # (no LAN sshd, tunnel down, SD card in another room).
          #
          # Ungated on purpose, like nixpi-security-posture below: every edit it
          # guards is made ON the Mac, so Linux-gating it would let `/eval` pass
          # clean and leave the operator to learn otherwise from CI minutes later.
          # Only strings escape into the derivation, so it costs no aarch64-linux
          # build.
          uplink-watchdog-paths-agree =
            let
              pi = config.flake.nixosConfigurations.nixpi.config;
              w = pi.local.uplinkWatchdog;
              wifi = pi.local.firmwareProvisioning.files.wifi or null;
              problems =
                lib.optional (
                  !w.enable
                ) "local.uplinkWatchdog is disabled on nixpi — the fallback ladder is dead code"
                ++ lib.optional (
                  wifi == null
                ) "local.firmwareProvisioning.files.wifi is gone — the watchdog rewrites a file nothing plants"
                ++ lib.optionals (wifi != null) (
                  lib.optional (toString w.wpaRuntimeConf != toString wifi.target)
                    "watchdog wpaRuntimeConf (${toString w.wpaRuntimeConf}) != firmware wifi target (${toString wifi.target})"
                  ++
                    lib.optional (!(lib.hasSuffix wifi.source (toString w.wpaSourceConf)))
                      "watchdog wpaSourceConf (${toString w.wpaSourceConf}) does not end in the planted filename (${wifi.source})"
                  ++
                    lib.optional (!(builtins.elem w.supplicantUnit (wifi.before or [ ])))
                      "watchdog restarts ${w.supplicantUnit}, which is not among the units the planted file is ordered before"
                );
            in
            pkgs.runCommand "uplink-watchdog-paths-agree" { } (
              if problems == [ ] then
                ''
                  echo "uplink watchdog agrees with firmware provisioning on ${toString w.wpaRuntimeConf}" > "$out"
                ''
              else
                ''
                  echo "uplink-watchdog-paths-agree: the watchdog and firmware provisioning disagree." >&2
                  ${lib.concatStringsSep "\n" (map (x: ''echo "  ✘ ${x}" >&2'') problems)}
                  echo "Fix modules/nixos/uplink-watchdog.nix or hosts/nixpi.nix so both name the same file." >&2
                  exit 1
                ''
            );

          nixpi-security-posture =
            let
              pi = config.flake.nixosConfigurations.nixpi.config;
              fw = pi.networking.firewall or { };
              ssh = pi.services.openssh or { };
              sshSettings = ssh.settings or { };
              listen = ssh.listenAddresses or [ ];
              sshPorts = ssh.ports or [ ];
              # null, not [ ]: "the module vanished" must read as BROKEN, and the
              # legs below refuse to compare against it rather than throw.
              tcp = fw.allowedTCPPorts or null;
              tcpRanges = fw.allowedTCPPortRanges or null;
              trusted = fw.trustedInterfaces or null;
              # `allInterfaces`, not `interfaces`: it is the internal option the
              # backend actually iterates (firewall.nix:305-311), so a future
              # upstream route into those same loops surfaces here as a new key
              # rather than slipping past a read of the user-facing option.
              interfaceKeys = lib.attrNames (fw.allInterfaces or { });

              sortStrings = lib.sort (a: b: a < b);
              addrs = map (a: a.addr or null) listen;
              addrsWellFormed = !(lib.elem null addrs);

              # Parse the MERGED extraConfig — upstream's generated block plus
              # whatever was appended after it — back into the addresses sshd
              # will bind. sshd reads keywords case-insensitively and accepts
              # `=` as a separator, hence the lowercase and the character class;
              # a leading `#` is not whitespace, so comments do not match.
              listenArg =
                l:
                let
                  m = builtins.match "[[:space:]]*listenaddress[[:space:]=]+([^[:space:]]+).*" (lib.toLower l);
                in
                if m == null then null else builtins.head m;
              renderedAddrs = lib.remove null (map listenArg (lib.splitString "\n" (ssh.extraConfig or "")));

              loopback = [
                "127.0.0.1"
                "::1"
              ];
              caddyOrigin = [ 80 ]; # hosts/nixpi.nix:215
            in
            mkHostContract {
              inherit pkgs;
              name = "nixpi-security-posture";
              subject = "nixpi: loopback-only sshd, one open port, no build trust";
              expect = [
                {
                  name = "the firewall is enabled at all";
                  ok = fw.enable or false;
                }
                {
                  name = "the TCP allow-list is EXACTLY the Caddy origin port — it has not grown";
                  ok = tcp == caddyOrigin;
                }
                {
                  name = "the TCP port-RANGE allow-list is empty — a range reaches the same accept rule";
                  ok = tcpRanges == [ ];
                }
                {
                  name = "no per-interface allow-list exists — only the 'default' pseudo-interface";
                  ok = interfaceKeys == [ "default" ];
                }
                {
                  name = "trustedInterfaces is loopback alone — a trusted interface accepts EVERYTHING on it";
                  ok = trusted == [ "lo" ];
                }
                {
                  name = "no sshd port appears in the TCP allow-list";
                  ok = tcp != null && sshPorts != [ ] && !(lib.any (p: lib.elem p tcp) sshPorts);
                }
                {
                  name = "services.openssh.openFirewall is false (upstream defaults it TRUE)";
                  ok = !(ssh.openFirewall or true);
                }
                {
                  name = "listenAddresses is NON-EMPTY — an empty list is the WILDCARD bind";
                  ok = listen != [ ];
                }
                {
                  # No backticks in any leg name or advice line — see the note in
                  # secrets-sync below: they land inside a double-quoted echo in
                  # the builder, where bash runs them as command substitution and
                  # the quoted text silently DISAPPEARS from the message.
                  name = "every listen address carries a string addr — it defaults to null, which no sort can order";
                  ok = addrsWellFormed;
                }
                {
                  name = "sshd binds loopback only, and BOTH families";
                  ok = addrsWellFormed && sortStrings addrs == loopback;
                }
                {
                  name = "the RENDERED ListenAddress lines are loopback only — none smuggled through extraConfig";
                  ok = addrsWellFormed && sortStrings renderedAddrs == loopback;
                }
                {
                  name = "no listen address carries an explicit port (it renders unbracketed)";
                  ok = lib.all (a: (a.port or null) == null) listen;
                }
                {
                  name = "sshd refuses passwords";
                  ok = !(sshSettings.PasswordAuthentication or true);
                }
                {
                  name = "sshd refuses keyboard-interactive";
                  ok = !(sshSettings.KbdInteractiveAuthentication or true);
                }
                {
                  name = "root may not log in over ssh";
                  ok = (sshSettings.PermitRootLogin or "yes") == "no";
                }
                {
                  name = "nix.distributedBuilds is off";
                  ok = !(pi.nix.distributedBuilds or true);
                }
                {
                  name = "nix.buildMachines is empty — it alone renders /etc/nix/machines";
                  ok = (pi.nix.buildMachines or null) == [ ];
                }
                {
                  name = "the rendered nix.settings.builders is null";
                  ok = (pi.nix.settings.builders or "missing") == null;
                }
              ];
              advice = [
                "modules/nixos/core.nix:46-102 owns the sshd and firewall half;"
                "hosts/nixpi.nix:215 owns the one open port (Caddy's origin, 80)."
                "sshd is reachable ONLY through the on-host tunnel connector, which"
                "dials localhost:22. Reopening 22 on the LAN, or binding the wildcard,"
                "walks straight around the Cloudflare Access application — Access runs"
                "at the EDGE, so such a connection is unauthenticated AND unlogged."
                "A port RANGE, a per-interface list and a trusted interface all reach"
                "the same iptables accept rule, which is why each has its own leg."
                "The build legs keep this leaf host free of outbound build trust and"
                "of a stray /etc/nix/machines. Fix the config; do not relax this."
              ];
            };

          # ---- The rules file and the ciphertexts beside it, joined by a human -
          #
          # `secrets/secrets.nix` is consumed by exactly ONE thing — the `agenix`
          # CLI — and is never imported into a host config, so nothing in this
          # flake has ever forced it to agree with the directory it describes.
          # Its top-level keys ARE the filenames, the .age files sit next to it,
          # and the join between the two lists is performed by eye.
          #
          # Both directions fail silently, and differently:
          #
          #   on disk, undeclared : `agenix -r` — the re-key you run after
          #     changing recipients — iterates the RULES, not the directory. A
          #     ciphertext the rules do not name is skipped, so it keeps its old
          #     recipient set while its siblings move to the new one. Nothing says
          #     so until a host cannot decrypt it at activation.
          #   declared, absent    : `agenix -e <name>` CREATES a missing file
          #     rather than complaining, so a typo'd key here reads as "that
          #     secret was never set up" instead of "you have been editing a file
          #     the fleet does not read".
          #
          # The fleet's concrete exposure is the pair that must move TOGETHER:
          # gh-app-dontsell-ai-key.age and gh-app-fleet-key.age hold identical key
          # material on purpose (one GitHub App, two owning users — the
          # `_github-runner` daemons vs. the login-user Tart agents; secrets.nix
          # carries the full why), so rotating the App key means re-encrypting
          # BOTH. Dropping one from the rules is precisely how that becomes a
          # one-sided rotation, and the half that was skipped is the half nobody
          # looks at until CI stops registering runners.
          #
          # NOT COVERED, and deliberately: this compares NAMES. It cannot see
          # whether a ciphertext's real age recipients match the `publicKeys` list
          # beside it — an `agenix -e` after a recipient edit with no `-r` leaves
          # exactly that disagreement — nor that the two gh-app-* files still hold
          # the same key material. Both need the private key, which this sandbox
          # does not have and must not.
          #
          # Ungated: it is a readDir plus two list comparisons, identical and
          # cheap on both systems, and the rules file is not platform-specific.
          secrets-sync =
            let
              onDisk = lib.attrNames (
                lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".age" n) (builtins.readDir ../../secrets)
              );
              declared = lib.attrNames (import ../../secrets/secrets.nix);
              unlisted = lib.subtractLists declared onDisk;
              absent = lib.subtractLists onDisk declared;
              # No backticks in any of these strings: they land inside a
              # double-quoted `echo` in the builder, where bash runs them as
              # command substitution and the quoted tool name silently
              # DISAPPEARS from the message (measured while proving this check
              # can fail). Quote command names with '' instead.
              problems =
                map (
                  f: "secrets/${f} is COMMITTED but secrets.nix does not declare it — 'agenix -r' will skip it"
                ) unlisted
                ++ map (f: "secrets.nix DECLARES ${f}, but no such ciphertext exists under secrets/") absent;
            in
            pkgs.runCommand "secrets-sync" { } (
              if problems == [ ] then
                ''
                  echo "secrets/: ${toString (lib.length onDisk)} .age files on disk, and secrets.nix declares exactly those ${toString (lib.length declared)}" > "$out"
                ''
              else
                ''
                  echo "secrets-sync: secrets/secrets.nix and secrets/ disagree." >&2
                  ${lib.concatStringsSep "\n" (map (p: ''echo "  ✘ ${p}" >&2'') problems)}
                  echo "" >&2
                  echo "The rules file is the ONLY index agenix has: a file it does not name is" >&2
                  echo "never re-keyed, and a name with no file is silently created on first edit." >&2
                  echo "Note gh-app-dontsell-ai-key.age and gh-app-fleet-key.age must BOTH be" >&2
                  echo "listed — same App key, two owning users, so a rotation touches both." >&2
                  exit 1
                ''
            );

          # THERE IS NO `flake-inputs-follows` CHECK, and that is a finding, not
          # an omission. The job — prove the hand-maintained `follows` graph in
          # flake.lock is deduped — is owned upstream by `nix-auto-follow`
          # (--check mode), and the Motto weights an off-the-shelf tool ~2x. But
          # the PINNED nixpkgs does not package it: measured 2026-09-21 against
          # rev dc5d91f8, `nix-auto-follow` is absent from
          # legacyPackages.{aarch64-darwin,aarch64-linux}, and the only
          # "auto-follow" string anywhere under pkgs/ belongs to an unrelated
          # lean-modules update script.
          #
          # The three ways to have it anyway are all worse than not having it:
          # vendoring the tool, fetching it at eval time (which makes an
          # eval-only check reach the network), or hand-rolling a lock-graph
          # walker — the last being exactly the reinvented wheel the Motto
          # rejects, over a file format Nix may change under us. Add the check
          # the day nixpkgs packages the tool; until then a `follows` edit stays
          # what CLAUDE.md says it is — shape-only, `nix flake lock`, never a
          # bare `nix flake update`.
          #
          # Note also that a naive dedupe checker would be WRONG here anyway:
          # `flake-parts` is a direct input whose `nixpkgs-lib` cannot be
          # `follows = ""` (that REBINDS to this flake rather than removing), so
          # any adopted tool must be shown to tolerate that case before it gates
          # anything.

          claude-md-budget = pkgs.runCommand "claude-md-budget" { } ''
            limit=40000
            size=$(wc -c < ${../../CLAUDE.md} | tr -d " ")
            if [ "$size" -gt "$limit" ]; then
              echo "claude-md-budget: CLAUDE.md is $size BYTES, over the $limit-byte" >&2
              echo "context-lint budget it documents for itself." >&2
              echo "" >&2
              echo "CLAUDE.md is an INDEX. The full per-path detail belongs in" >&2
              echo "docs/repo-map.md — move a section there and leave the one-liner," >&2
              echo "rather than raising this limit reflexively." >&2
              exit 1
            fi
            echo "CLAUDE.md: $size/$limit bytes"
            touch "$out"
          '';

          # NOTE: `hm-launchd-drift` lived here until 2026-09-14. It pinned the
          # sha256 of home-manager's modules/launchd/default.nix so the 560-line
          # vendored fork of that file could not silently fall behind upstream.
          # Both retired together: home-manager 87c391f added
          # `launchd.agents.<name>.launcher.{name,shell}`, which expresses what the
          # fork existed to do, so modules/shared/launchd-launcher.nix now sets
          # three upstream options instead. There is nothing vendored left to drift.

          # Structural lint (ast-grep). A CHECK, deliberately not a treefmt
          # formatter: treefmt-nix ships no ast-grep program, and the pre-commit
          # hook IS the `nix fmt` wrapper — a report-only checker in that slot
          # would block every commit with a diagnostic no `nix fmt` can fix. Rules
          # + rationale: sgconfig.yml and ast-grep/rules/*.yml (they mechanise
          # CLAUDE.md § Conventions "Paths — two axes" and
          # .claude/rules/launchd-naming.md, which were prompt-only until now).
          #
          # `${self}` is the git-tracked tree, so the walk sees exactly what CI
          # sees. Two non-obvious flags:
          #   --no-ignore hidden : ast-grep SKIPS dot-dirs by default, which would
          #     silently exclude .claude/hooks/*.js — i.e. a green check that
          #     linted nothing. Verified: without it the JS rule finds zero files.
          #   `test` before `scan` : the valid/invalid fixtures in
          #     ast-grep/rule-tests/ prove each rule still FIRES, so a typo'd
          #     pattern fails loudly instead of passing vacuously.
          # HOME is set because ast-grep resolves a user config dir on startup and
          # $HOME is unset in the sandbox.
          ast-grep = pkgs.runCommand "ast-grep" { nativeBuildInputs = [ pkgs.ast-grep ]; } ''
            export HOME="$TMPDIR"
            cd ${self}
            ast-grep test --skip-snapshot-tests
            ast-grep scan --no-ignore hidden --color=never .
            touch "$out"
          '';

          # THE USERSCRIPT GATE IS GONE (2026-09-14), and its absence is the
          # point, not an oversight.
          #
          # It linted the `kattakath-userscripts` input: a .user.js is never
          # parsed at build time - Nix only copies it into the store - so a
          # syntax error shipped silently and surfaced as Violentmonkey's
          # useless "Syntax error?" toast with no line number. It caught a real
          # one (backticks inside a CSS comment nested in a GM_addStyle template
          # literal) and a real missing @license.
          #
          # Every script it covered has since been PUBLISHED - the last,
          # google-photos-icon-nav, is greasyfork.org/scripts/595764 - and the
          # input repository was deleted, so the check had no operand left.
          # Re-pointing it at `${self}` would have been the exact failure the
          # old comment here warned about: a green build over an empty
          # directory, which is strictly worse than no gate at all.
          #
          # The rulebook did not move. It is still page-lab's
          # `scripts/userscript-meta-lint.sh`, and it still runs on every push -
          # in the two repositories that now own the scripts
          # (github:ismailkattakath/userscripts, github:izzykatt/userscripts),
          # whose CI runs that same script plus eslint. One rulebook, run where
          # the content is: the same principle that moved the gate here in the
          # first place, applied once more.
          #
          # The `local.ungoogledChromium.userScripts` OPTION in
          # modules/shared/chromium.nix stays, unused and documented. If a
          # script is ever declared again, restore this gate with it.

          # page-lab's OWN integrity, distinct from the userscript gate that
          # used to sit above: that one asked "are the shipped scripts
          # publishable", this one asks "is the plugin itself sound". Three things, each a real past failure
          # mode rather than ceremony:
          #  1. every .mjs/.js parses and every .sh is syntactically valid — a
          #     plugin script is never executed by a build, so a syntax error
          #     otherwise ships silently and only surfaces mid-session.
          #  2. the envelope fixtures self-test, INCLUDING the two NEGATIVE ones.
          #     A validator that cannot reject is decoration; this is the check
          #     that keeps the pick contract load-bearing.
          #  3. containment: the rename gate. A stale `plugins/userscript-author`
          #     or `chrome-devtools@` path is invisible until someone follows it.
          page-lab =
            pkgs.runCommand "page-lab"
              {
                nativeBuildInputs = with pkgs; [
                  nodejs
                  bash
                ];
              }
              ''
                rc=0
                pl=${inputs.kattakath-ai}/plugins/page-lab
                for f in "$pl"/scripts/*.mjs "$pl"/scripts/lib/*.mjs "$pl"/scripts/*.js; do
                  node --check "$f" || { echo "  ✘ does not parse: $f" >&2; rc=1; }
                done
                for f in "$pl"/scripts/*.sh; do
                  bash -n "$f" || { echo "  ✘ bad shell syntax: $f" >&2; rc=1; }
                done

                node "$pl"/scripts/pick-validate.mjs --self-test \
                  "$pl"/scripts/fixtures || rc=1

                # Two gates over THIS repo. page-lab's tree moved out; nix-config's
                # prose and its source literals did not, and a stale one is exactly
                # the drift this catches.
                #
                #  (a) pre-merge plugin ids — userscript-author / chrome-devtools@,
                #      from the 2026-09 merge that produced page-lab.
                #  (b) pre-EXTRACTION source literals — a `../plugins/…` or
                #      `../../skills/rag` still resolves to NOTHING in this tree after
                #      2026-09-12. Matched as RELATIVE LITERALS on purpose, not as bare
                #      substrings: `${inputs.kattakath-ai}/plugins/page-lab`
                #      is the CORRECT new form and contains "plugins/page-lab", so a
                #      substring grep would flag the fix as the bug.
                #
                # facts.md RECORDS old names as history; this file CARRIES the grep so
                # it matches its own source.
                cd ${self}
                if grep -rn 'plugins/userscript-author\|plugins/chrome-devtools\|chrome-devtools@' \
                     --exclude-dir=.git --exclude=facts.md --exclude=checks.nix . ; then
                  echo "  ✘ stale pre-merge plugin id above" >&2
                  rc=1
                fi
                if grep -rn '\.\./plugins/\|\.\./skills/rag\|\.\./skills/nix-dev-toolkit\|\.\./skills/android-phone\|\.\./userscripts/' \
                     --exclude-dir=.git --exclude=checks.nix . ; then
                  echo "  ✘ repo-relative literal pointing at an EXTRACTED tree above" >&2
                  echo "    those live in pinned inputs now — see flake.nix" >&2
                  rc=1
                fi

                [ "$rc" = 0 ] || { echo "page-lab integrity check FAILED" >&2; exit 1; }
                touch "$out"
              '';
        };
    };
}
