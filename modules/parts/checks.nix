# ---- Checks: `nix flake check` enforces formatting + lint + hooks ------
# Lint/format only, to keep merge CI fast. The host toplevels are
# deliberately NOT checks: BUILDING them (esp. the cold Pi kernel, ~1h) is
# too slow for merge CI (nixpi's toplevel is built by warm-nixpi-cache.yml;
# see docs/map/hosts.md). Merge CI instead EVALUATES the host configs
# (cheap, catches config/eval errors) without building — see
# .github/workflows/nix-ci.yml.
#
# `checks.formatting` and `checks.pre-commit` are NOT here: they come from the
# treefmt-nix / git-hooks.nix flakeModules in modules/parts/devshell.nix, and
# `checks.deploy-schema` from modules/parts/deploy.nix. flake-parts declares `checks` as
# `lazyAttrsOf types.package` (pinned modules/checks.nix:14), so every file that
# declares checks merges into one per-system attrset — and every entry must be a derivation,
# which is why none of these are a bare `runCommand` argument set.
{
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  inherit (config.fleet.identityArgs) loginName;
  # Read from config.fleet — NOT identityArgs, which is the attrset a consumer replaces.
  inherit (config.fleet) domainName;

  # ---- the documentation INDEXES, in one place -----------------------------
  #
  # DERIVED, not listed: CLAUDE.md, docs/repo-map.md and every docs/map/*.md.
  # The per-path detail lives in the map files (hosts/ in docs/map/hosts.md,
  # docs/*.md in docs/map/docs-index.md), so a hand-listed set rots on a MOVE.
  # readDir means a twelfth domain file is an index the moment it exists — the same reason nix-ci.yml's `legs` job reads the host
  # systems out of the flake rather than restating them. Two shapes because the two consumers differ: hosts-documented
  # greps STORE PATHS, docs-indexed resolves link targets relative to each
  # index's own directory inside `${self}` and so needs REPO-RELATIVE names.
  mapIndexNames = lib.naturalSort (
    lib.attrNames (
      lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir ../../docs/map)
    )
  );
  docIndexNames = [
    "CLAUDE.md"
    "docs/repo-map.md"
  ]
  ++ map (n: "docs/map/${n}") mapIndexNames;
  docIndexPaths = [
    ../../CLAUDE.md
    ../../docs/repo-map.md
  ]
  ++ map (n: ../../docs/map + "/${n}") mapIndexNames;

  # ---- GENERATED documentation (ADR-012 § 5 step 5) --------------------------
  #
  # Hand-kept inventories rot; 75 of 146 line citations once had. So the two lists a
  # reader most needs exactly right — which hosts exist on which system, and which
  # `nix run .#<app>` exists on which system — are RENDERED from the flake into a marked
  # block in docs/map/entry-points.md. `hosts-documented` fails when the committed block
  # differs from this render, and `nix run .#docs-generate` rewrites the block.
  #
  # Facts only, no prose column: a role or description column would be prose again, and
  # CLAUDE.md § Overview keeps that. Not `nixosOptionsDoc`: ADR-002 §9.5 measured it and
  # held it back ("At `warningsAreErrors = false` it is a gate that cannot fail", and
  # `home-manager.users` renders as one opaque row), and a host or app list needs none of
  # it. The checks inventory is NOT rendered: a check reading `attrNames` of the checks
  # set it belongs to recurses.
  #
  # ADR-014 § 5 step 2 made it N named spans: `generatedBlocks` maps a span name to the doc
  # that holds it and the lines between its markers. ONE check (`hosts-documented`) proves
  # every span equals its render, and ONE writer (`docs-generate`) rewrites every span, both
  # from the same `render`, so the two cannot disagree. A new span is one attribute here.
  generatedMarkers = name: {
    begin = "<!-- BEGIN GENERATED: ${name}, regenerate with: nix run .#docs-generate -->";
    end = "<!-- END GENERATED: ${name} -->";
  };
  generatedBlocks =
    lib.mapAttrs
      (
        name: b:
        let
          m = generatedMarkers name;
        in
        b
        // {
          inherit (m) begin end;
          render =
            lib.concatStringsSep "\n" (
              [
                m.begin
                ""
              ]
              ++ b.lines
              ++ [
                ""
                m.end
              ]
            )
            + "\n";
        }
      )
      {
        flake-outputs = {
          doc = "docs/map/entry-points.md";
          lines = flakeOutputsLines;
        };
      };
  # One TSV row per span (name, repo-relative doc, doc in the store, render, begin, end):
  # what the check and the writer both loop over.
  generatedManifest =
    pkgs:
    pkgs.writeText "generated-blocks.tsv" (
      lib.concatStrings (
        lib.mapAttrsToList (
          name: b:
          "${name}\t${b.doc}\t${../.. + "/${b.doc}"}\t${pkgs.writeText "${name}.md" b.render}\t${b.begin}\t${b.end}\n"
        ) generatedBlocks
      )
    );
  flakeOutputsLines =
    let
      code = s: "`${s}`";
      hostRow =
        output: name: c:
        let
          profile = "hosts/${name}.nix";
        in
        "| ${code name} | ${code output} | ${code c.pkgs.stdenv.hostPlatform.system} | ${
          if builtins.pathExists (../../hosts + "/${name}.nix") then code profile else "—"
        } |";
      hostRows =
        lib.mapAttrsToList (hostRow "darwinConfigurations") config.flake.darwinConfigurations
        ++ lib.mapAttrsToList (hostRow "nixosConfigurations") config.flake.nixosConfigurations;
      appSystems = lib.attrNames config.flake.apps;
      appNames = lib.naturalSort (
        lib.unique (lib.concatMap (s: lib.attrNames config.flake.apps.${s}) appSystems)
      );
      appRow =
        n:
        "| ${code n} | "
        + lib.concatMapStringsSep " | " (s: if config.flake.apps.${s} ? ${n} then "yes" else "") appSystems
        + " |";
    in
    [
      "| Host | Output | System | Profile |"
      "|---|---|---|---|"
    ]
    ++ hostRows
    ++ [
      ""
      ("| App | " + lib.concatMapStringsSep " | " code appSystems + " |")
      ("|---|" + lib.concatMapStrings (_: "---|") appSystems)
    ]
    ++ map appRow appNames;

  # The ONE shared shape in this file. It was born for `determinate-daemon-{macos,nixpi}`,
  # which is literally the same check run against two hosts whose contracts are
  # opposites (see both halves below). The bar for reaching for it: the check
  # wants exactly this behaviour — report EVERY broken leg, not the first.
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
    { pkgs, self', ... }:
    {
      checks =
        lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          # ---- bootstrap.sh is the highest-stakes unwrapped script, not the ONLY one -
          #
          # Two tracked `.sh` files are `builtins.readFile`d into a
          # `writeShellApplication` and so shellchecked by BUILDING it
          # (packages/design-tokens/build.sh, packages/email-signature/signature.sh).
          # The others are unwrapped:
          #
          #   bootstrap.sh                 gated — by this check.
          #   scripts/drv-snapshot.sh      gated — by `drv-snapshot-lint`, in the
          #     ungated block below.
          #   modules/features/keychain-secrets/tests/grammar.sh
          #     gated — by `keychain-secrets-grammar-lint`, in the capsule's own
          #     ./checks/ dir. It cannot be a derivation (its assertions need a login
          #     Keychain the build sandbox has not got), but "cannot be RUN" is not
          #     "cannot be CHECKED" — shellcheck needs no Keychain.
          #   .claude/hooks/tests/*.sh DELIBERATELY NOT LINTED, and the only entry
          #     here left that way on purpose. claude-config-lint.yml RUNS every one
          #     under `gate`, so a failure blocks a merge — strictly stronger evidence
          #     than a lint. Shellcheck adds nothing on top: its findings there are
          #     SC2016 "expressions don't expand in single quotes" (plus an SC1003) in
          #     the single-quoted `ck`/`nothrow` cases, and every one is a FALSE
          #     POSITIVE by construction — those quotes hold the literal command text
          #     the guard is asked to judge (`ck block 'echo $(secret
          #     reveal K)'`), and expanding them would mean running it. Linting them
          #     would cost a standing disable-directive tax on every new test case and
          #     two more rows in `nix flake show` and the acceptance baseline.
          #
          # And there is no blanket fallback: treefmt.nix is REWRITE-only by design
          # and enables no shellcheck or shfmt, so the only shellcheck this tree has
          # is `writeShellApplication`'s, actionlint's `-shellcheck` over `run:`
          # blocks, and the checks named above.
          #
          # SHELLCHECK IS A BASH GATE, NOT A SHELL GATE. It refuses zsh outright
          # (SC1071, "ShellCheck only supports sh/bash/dash/ksh"), so nothing here
          # covers a `.zsh` file or a zsh-shebanged script — and zsh's lack of
          # implicit IFS field splitting makes `for f in $files` a silent one-shot
          # loop that exits 0, exactly the class of bug a lint is wanted for. No
          # tracked `.sh` file is zsh today, so the gap is latent rather than live; it
          # goes live the day someone adds a zsh script.
          #
          # bootstrap.sh still earns being named first. It CANNOT be wrapped: it runs
          # on a Mac that has no Nix yet, so it is plain bash copied out-of-band
          # through `curl … | bash` — and it runs as the user, calls sudo, and
          # deletes an APFS volume.
          #
          # It carried a gate until 2026-09-15 (the `key-recovery-bootstrap`
          # derivation, which went with packages/key-recovery.nix). This is that
          # gate, standing on its own rather than riding a package that happened
          # to also ship the script.
          #
          # Since 2026-09-16 it also asserts the ONE invariant bootstrap.sh shares
          # with the flake. bootstrap.sh computes the clone directory from
          # `--flake` (`$HOME/Developer/github.com/$FLAKE_OWNER/$FLAKE_REPO`)
          # while modules/parts/hosts.nix's `operatorFlakeRelPath` computes the
          # /etc/nix-darwin symlink target from config.fleet's orgName/repoName —
          # two independent derivations of one path. hosts.nix's comment states the
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
          #   modules/home/claude-bedrock-gate.nix        lib.mkOrder 1600
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
                  echo "modules/home/claude-bedrock-gate.nix uses lib.mkOrder 1600 and MUST" >&2
                  echo "run after modules/features/keychain-secrets/module.nix's lib.mkAfter" >&2
                  echo "(= mkOrder 1500), which is what exports CLAUDE_CODE_USE_BEDROCK from" >&2
                  echo "the Keychain in the first place. Reversed, the gate reads an unset" >&2
                  echo "variable, does nothing, and Claude Code silently keeps a Bedrock" >&2
                  echo "route it cannot use. Fix the priorities; do not relax this." >&2
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
                  # ONE joined needle: the host and its domain as they sit side by side
                  # in the regex. Two separate substrings pass on the ~20 comment
                  # mentions of the host even when the PI_HOSTS literal is broken.
                  lib.optional (!(lib.hasInfix "${piName}(?:\\.${escapedDomain}" guard))
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

          # nixpi's journal redaction (modules/_lib/log-redactions.nix) fed real-shaped
          # lines through GO's `regexp` — Alloy's own engine — in Alloy's order. The 2026-11-03
          # hygiene audit found the old pattern redacting clock times and missing every
          # compressed IPv6 address; each case below pins one side of that.
          log-redaction =
            let
              patterns = import ../_lib/log-redactions.nix;
              canary = import ../_lib/redaction-canary.nix;
              cases = [
                # [ input expected ]
                [
                  "2026/11/03 12:34:56 started"
                  "2026/11/03 12:34:56 started"
                ]
                [
                  "took 1:02:03"
                  "took 1:02:03"
                ]
                [
                  "fe80::1 up"
                  "<ip6> up"
                ]
                [
                  "from 2001:db8::1 port 22"
                  "from <ip6> port 22"
                ]
                [
                  "2607:f2c0:e000::1234"
                  "<ip6>"
                ]
                [
                  "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
                  "<ip6>"
                ]
                [
                  "fe80::1%wlan0"
                  "<ip6>%wlan0"
                ]
                [
                  "bssid aa:bb:cc:dd:ee:ff"
                  "bssid <mac>"
                ]
                [
                  "AA-BB-CC-DD-EE-FF"
                  "<mac>"
                ]
                [
                  "std::vector<int> fmt::Display"
                  "std::vector<int> fmt::Display"
                ]
                [
                  "Failed password from 10.1.2.3 port 5"
                  "Failed password from <ip> port 5"
                ]
                [
                  "listening on ::1"
                  "listening on ::1"
                ]
                # The active canary's own line must come out fully redacted, or its
                # "arrived unredacted" rule would fire every day.
                [
                  "${canary.marker} ${lib.concatStringsSep " " canary.values}"
                  "${canary.marker} <ip6> <ip6> <mac>"
                ]
              ];
              main = pkgs.writeText "redact.go" ''
                package main

                import (
                	"encoding/json"
                	"fmt"
                	"os"
                	"regexp"
                )

                type pat struct{ Name, Expr, Replace string }

                func main() {
                	var ps []pat
                	var cs [][2]string
                	json.Unmarshal([]byte(os.Getenv("PATTERNS")), &ps)
                	json.Unmarshal([]byte(os.Getenv("CASES")), &cs)
                	bad := 0
                	for _, c := range cs {
                		got := c[0]
                		for _, p := range ps {
                			got = regexp.MustCompile(p.Expr).ReplaceAllLiteralString(got, p.Replace)
                		}
                		if got != c[1] {
                			bad++
                			fmt.Fprintf(os.Stderr, "  ✘ %q -> %q, want %q\n", c[0], got, c[1])
                		}
                	}
                	if bad > 0 {
                		os.Exit(1)
                	}
                	fmt.Printf("%d lines, %d patterns: all redacted as expected\n", len(cs), len(ps))
                }
              '';
            in
            pkgs.runCommand "log-redaction"
              {
                nativeBuildInputs = [ pkgs.go ];
                PATTERNS = builtins.toJSON patterns;
                CASES = builtins.toJSON cases;
              }
              ''
                export HOME="$TMPDIR" GOCACHE="$TMPDIR/go-cache" GO111MODULE=off
                cp ${main} redact.go
                go run redact.go > "$out"
              '';

          # The bash guard's TERRANIX_MUTATING_APP is DERIVED from the `-apply` suffix, so a
          # new stack is nudged the day it lands — but the per-stack worst case is a
          # hand-kept JS map, and it missed grafana and github once. Every `*-apply`
          # package must have a key there, or the nudge ships without its worst case.
          terranix-guard-knows-every-apply =
            let
              guard = builtins.readFile ../../.claude/hooks/pretooluse-bash-guard.js;
              stacks = map (lib.removeSuffix "-apply") (
                lib.filter (lib.hasSuffix "-apply") (lib.attrNames self'.packages)
              );
              # A key sits in the map as `"cf-zones":` or, when a bare identifier, `grafana:`.
              known = s: lib.hasInfix "\n  \"${s}\": " guard || lib.hasInfix "\n  ${s}: " guard;
              missing = lib.filter (s: !(known s)) stacks;
            in
            pkgs.runCommand "terranix-guard-knows-every-apply" { } (
              if missing == [ ] then
                ''
                  echo "TERRANIX_APPLY_WORST_CASE names every *-apply stack" > "$out"
                ''
              else
                ''
                  echo "terranix-guard-knows-every-apply: no worst case for: ${lib.concatStringsSep " " missing}" >&2
                  echo "Add each to TERRANIX_APPLY_WORST_CASE in .claude/hooks/pretooluse-bash-guard.js." >&2
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
          # Every one of those EVALUATED cleanly for the fleet. So this check calls
          # the builders the way templates/default/flake.nix does and FORCES the
          # attributes that carry the failure. Eval-only, which is all it needs to
          # be: each of the three was an eval error or an eval-visible value, and
          # `nix flake check` is eval-only too.
          #
          # It READS the template rather than re-implementing its identity, because
          # nothing else covers it:
          #
          #   · `nix flake check`'s built-in templates schema validates that
          #     `templates.default.path` is a path and `description` is a string. It
          #     never evaluates the scaffolded flake.
          #   · templates/default/flake.nix pins `inputs.nix-config.url =
          #     "github:kattakath/nix-config"`, i.e. PUBLISHED main. Evaluating it as
          #     a flake would therefore test whatever is already released, not the
          #     working tree — the one thing a merge gate must not do.
          #
          # Without it, a renamed identity field in the template ships green and the
          # first to find out is a stranger running `nix flake init -t`.
          #
          # HOW IT READS IT. `import` the template's flake.nix (it is a plain Nix
          # file) and call its `outputs` with a STUB engine whose `lib.mkDarwin` is
          # the identity function. That CAPTURES the real argument attrset the
          # template passes — system, hostname, identity, extraModules — from the
          # file, with no regex and no second copy. The captured args then go into
          # THIS tree's `config.flake.lib.mkDarwin`, which is what "override the pin
          # to the working tree" means in a pure eval: the stub is the only way to
          # swap the published engine for this one without `builtins.getFlake` (impure)
          # or a CLI `--override-input` (unavailable inside a check).
          #
          # REJECTED: parsing the identity attrset out of the file as TEXT. It would
          # answer the field-name question and nothing else — the values would still
          # never reach a builder, so `hostname` and `extraModules` would stay
          # unexercised, and a regex over Nix source is a parser this repo would then
          # own. Importing the file reads it as what it is.
          #
          # THE FIELD-SET LEG IS A PRECONDITION, not just another leg, and the order
          # is load-bearing. `identity` reaches the builders through `specialArgs`,
          # which is outside the module type system by construction (identity.nix says
          # so), so a renamed field does NOT fail as an option error — it fails as
          # `attribute 'fullName' missing` from inside modules/home/default.nix, a
          # trivial-builder stack trace with no mention of the template. So the field
          # set is compared FIRST, against `lib.attrNames config.fleet.identityArgs` —
          # authoritative because that submodule is CLOSED (a fifth field fails in
          # identity.nix before it can reach a consumer) — and the deep legs are
          # wrapped in `lib.optionals fieldsAgree`, which never forces them when the
          # names already disagree. Measured 2026-10-02: renaming `fullName` to
          # `fullname` in the template turns this check RED with a named message
          # instead of that stack trace.
          #
          # Forcing the right leaf is load-bearing for the rest. `home.stateVersion`
          # and an agent's `.enable` both pass while an identityArg is missing;
          # `home-manager.extraSpecialArgs` is the seam where all four values land, so
          # comparing it against the captured identity proves every field — domainName
          # included, which has no other observable leaf on `generic-darwin`.
          #
          # NOT COVERED: that the scaffolded flake works as a FLAKE. Its `apps` output
          # and its `self` reference are never forced (the stub `throw`s for both), and
          # nothing here fetches `inputs.nix-config` — so a broken `apps.macos` or a
          # bad input ref beyond the url string is still only found by running
          # `nix flake init -t` for real.
          template-consumer =
            let
              # The template, as Nix rather than as text. A SOURCE PATH LITERAL, so
              # `./hosts/macos.nix` inside it resolves next to it in the store copy.
              templateFlake = import ../../templates/default/flake.nix;

              captured =
                (templateFlake.outputs {
                  # Only the template's `apps` output reads these, and this check
                  # forces `darwinConfigurations` alone. `throw` rather than a dummy:
                  # if the template ever starts reading them on THIS path, that must
                  # be a loud failure asking for this check to be taught, not a quiet
                  # evaluation against a lie.
                  self = throw "checks.template-consumer: the template's `self` is a flake-time value this check does not have";
                  nix-config = {
                    # The capture. Returns the argument set instead of building it.
                    lib.mkDarwin = args: args;
                    inputs = throw "checks.template-consumer: the template's nixpkgs is only needed by its `apps` output, which this check does not force";
                  };
                }).darwinConfigurations.macos;

              templateIdentity = captured.identity;
              templateLogin = templateIdentity.loginName;

              # The engine's accepted field set, read from the CLOSED submodule's
              # value rather than restated. Both lists come from `attrNames`, so they
              # are sorted and a plain `==` is a set comparison.
              engineFields = lib.attrNames config.fleet.identityArgs;
              templateFields = lib.attrNames templateIdentity;
              fieldsAgree = templateFields == engineFields;

              mac = config.flake.lib.mkDarwin captured;
              macHm = mac.config.home-manager.users.${templateLogin};

              # The same consumer, but with its host NAMED "macos" — which
              # hosts/generic-darwin.nix tells it to set for a bare darwin-rebuild.
              # Operator-only gates read local.operatorHost
              # (modules/darwin/operator-host.nix), never the hostname, so this
              # must still get none of them.
              namedMacos = config.flake.lib.mkDarwin (
                captured
                // {
                  extraModules = (captured.extraModules or [ ]) ++ [ { networking.hostName = "macos"; } ];
                }
              );
              namedHm = namedMacos.config.home-manager.users.${templateLogin};

              # mkNixos is the other half of the published API and the template does
              # NOT call it, so it rides the captured identity: these legs are the
              # 2026-09-16 operator-account leak, kept rather than dropped for want of
              # a template that exercises them.
              box = config.flake.lib.mkNixos {
                system = "aarch64-linux";
                hostname = "generic-linux";
                identity = templateIdentity;
                # Deliberately NO operatorSshKey — a consumer does not pass one.
                extraModules = [
                  {
                    system.stateVersion = "24.05";
                    networking.hostName = "templatebox";
                  }
                ];
              };
              boxUsers = box.config.users.users;

              fieldList = f: lib.concatStringsSep ", " f;

              # `alwaysOnIds` in modules/home/claude-plugins.nix (sorted, so `==`
              # against `attrNames` is a set comparison). Written out
              # rather than read back: the check pins what a consumer MUST get, and a
              # change to the floor should have to change this line on purpose.
              consumerPluginFloor = [
                "brain-signals@kattakath"
                "nix-flake-kit@kattakath"
                "superhook@kattakath"
              ];

              problems =
                lib.optional (!fieldsAgree)
                  "templates/default/flake.nix's 'identity' declares { ${fieldList templateFields} }, but fleet.identityArgs accepts { ${fieldList engineFields} } — a consumer scaffolded from this template cannot evaluate"
                ++
                  lib.optional (templateFlake.inputs.nix-config.url != config.fleet.flakeRef)
                    "the template pins '${templateFlake.inputs.nix-config.url}', not ${config.fleet.flakeRef} — 'nix flake init -t' would scaffold a flake pointing at the wrong engine"
                ++ lib.optionals fieldsAgree (
                  # Forces the whole darwin + home-manager fixpoint for the TEMPLATE's
                  # own arguments.
                  lib.optional (
                    templateLogin == loginName
                  ) "the template ships the OPERATOR's login (${loginName}) as its placeholder identity"
                  ++
                    lib.optional
                      (
                        builtins.intersectAttrs templateIdentity mac.config.home-manager.extraSpecialArgs
                        != templateIdentity
                      )
                      "the template's identity does not survive into home-manager.extraSpecialArgs — some field is dropped or rewritten between mkDarwin and the home profile"
                  ++ lib.optional (
                    macHm.programs.git.settings.user.name != templateIdentity.fullName
                    || macHm.programs.git.settings.user.email != templateIdentity.userEmail
                  ) "the consumer's git identity is not the one the template declares"
                  ++
                    lib.optional
                      (mac.config.users.users ? ${loginName} || mac.config.system.primaryUser != templateLogin)
                      "the template's 'hostname' selected a host that creates the OPERATOR's account (${loginName}) — this is the 2026-09-15 regression, via the template"
                  ++
                    lib.optional
                      (
                        namedMacos.config.local.operatorHost
                        || namedHm.home.activation ? emailSignature
                        || namedHm.local.claudeOtel.enable
                      )
                      "a consumer whose host is NAMED 'macos' got operator-only behaviour — gate on local.operatorHost, never the hostname"
                  # Plugin choices are runtime state, not fleet shape: a consumer
                  # renders the always-on floor and nothing else. Compared on the RENDERED keys, so a personal id
                  # reaching the consumer by any path goes red, not just via `declared`.
                  ++
                    lib.optional
                      (lib.attrNames macHm.programs.claude-code.settings.enabledPlugins != consumerPluginFloor)
                      "the consumer's enabledPlugins are { ${fieldList (lib.attrNames macHm.programs.claude-code.settings.enabledPlugins)} }, expected only the always-on floor { ${fieldList consumerPluginFloor} } — gate the operator's plugin ids on local.operatorHost"
                  # The operator's personal CLIs (his data paths and Keychain items) are
                  # gated on local.operatorHost in modules/home/default.nix; a platform gate
                  # (isDarwin) would hand them to every consumer's Mac.
                  ++ (
                    let
                      # buku (his bookmark DB), jobspy (his job search), resend (his Keychain key);
                      # the generic dev CLIs next to them stay on every Mac by decision (#1028).
                      operatorOnlyTools = [
                        "buku"
                        "jobspy"
                        "resend"
                      ];
                      leaked = lib.filter (n: lib.elem n operatorOnlyTools) (map lib.getName macHm.home.packages);
                    in
                    lib.optional (leaked != [ ])
                      "the consumer's home.packages carry the operator's own CLIs { ${fieldList leaked} } — gate them on local.operatorHost (isMacosHost), not the platform"
                  )
                  ++ lib.optional (
                    boxUsers ? ${loginName}
                  ) "mkNixos created the OPERATOR's account (${loginName}) on a consumer's host"
                  ++ lib.optional (
                    boxUsers.${templateLogin}.openssh.authorizedKeys.keys != [ ]
                  ) "mkNixos granted SSH keys a consumer never asked for"
                  ++ lib.optional (lib.elem loginName box.config.nix.settings.trusted-users) "mkNixos put the operator in a consumer's nix trusted-users"
                );
            in
            pkgs.runCommand "template-consumer" { } (
              if problems == [ ] then
                ''
                  echo "templates/default/flake.nix's own arguments build mkDarwin (+ mkNixos on the same identity): ${fieldList templateFields}, host ${captured.hostname}, no operator state" > "$out"
                ''
              else
                ''
                  echo "template-consumer: the published composition API leaks or breaks." >&2
                  ${lib.concatStringsSep "\n" (map (p: ''echo "  ✘ ${p}" >&2'') problems)}
                  echo "" >&2
                  echo "This check READS templates/default/flake.nix and builds with its own" >&2
                  echo "arguments; fix the template or the engine, never this literal — there" >&2
                  echo "isn't one any more. See modules/parts/compose.nix (identityArgs is" >&2
                  echo "REPLACED by a consumer; fleet constants belong in" >&2
                  echo "mkHomeManagerModule's inherit list) and modules/parts/identity.nix" >&2
                  echo "(the CLOSED submodule that defines the accepted field set)." >&2
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
          # Darwin-only (CI runs it on the advisory darwin leg: docs/map/ci.md
          # § Residual risk). The nixpi half lives in the isLinux block below
          # and asserts the OPPOSITE things, on purpose.
          #
          # The HOST IS IN THE NAME, and that is load-bearing (2026-10-18). Both
          # halves were once called `determinate-daemon`, and a shared name read as
          # "linux builds it", so the macos contract went ungated. Invariant: a check name present on two systems
          # must come from ONE source block; a per-host contract carries its host.
          #
          # NOT COVERED: this reads the Nix-side declaration only. It cannot see
          # whether determinate-nixd is actually running, whether the account
          # entitlement at dtr.mn/features is live, or whether the local daemon
          # is logged in to FlakeHub — and that last one is what makes
          # `native-linux-builder` silently vanish. Those are runtime facts; the
          # runbook owns them (docs/new-mac-runbook.md).
          determinate-daemon-macos =
            let
              mac = config.flake.darwinConfigurations.macos.config;
              custom = mac.determinateNix.customSettings or { };
            in
            mkHostContract {
              inherit pkgs;
              name = "determinate-daemon-macos";
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
          # modules/home/claude-guardrails.nix. That duplication is deliberate —
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
              # The secret-value family: the verbs that PRINT a secret and the paths that HOLD one. The
              # environment dumps are matched as WHOLE rules, anchored at both
              # ends: they are exact-match denies, and a bare `env|set|export`
              # substring would also count unrelated rules and inflate the total.
              secretRules = builtins.filter (
                r:
                builtins.match ".*(secret reveal|find-generic-password|find-internet-password|agenix|\\(age |/run/agenix|/\\.local/state/nix-config-|/\\.aws/sso/cache).*" r
                != null
                ||
                  builtins.match "Bash\\((env|printenv|set|export|export -p|declare -[xp]|typeset -[xp])\\)" r != null
              ) userDeny;
              # Today's count, pinned. Raise it deliberately when the family grows;
              # a DROP means either a real retraction or a reworded rule the pattern
              # above no longer sees, and both deserve a human.
              minSecretRules = 31;
              # The SECOND hand-kept duplicate in that file: strictKnownMarketplaces'
              # exact `git` entries restate every non-store marketplace source the
              # home profile declares, and a source missing there is REFUSED at
              # `marketplace add`. Store paths are the home module's own isStorePath
              # split (claude-plugins.nix), covered by the `pathPattern` entry.
              gitMarketplaces = builtins.filter (s: !(lib.hasPrefix "/nix/store/" s)) (
                map (m: m.source) (lib.attrValues hm.local.claudePlugins.marketplaces)
              );
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
                  echo "This check filters modules/home/claude-guardrails.nix's deny list by pattern to" >&2
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
                  echo "modules/home/claude-guardrails.nix records twice. Restore the rules." >&2
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
                  echo "claude-managed-settings: modules/home/claude-guardrails.nix denies the rules above," >&2
                  echo "but modules/darwin/claude-managed-settings.nix does not. The two lists are a" >&2
                  echo "deliberate duplicate (deriving one yields [ ] on a reword), so an edit to one" >&2
                  echo "must be made in the other. Add them and re-run." >&2
                  exit 1
                fi

                if [ "${toString (builtins.length gitMarketplaces)}" -eq 0 ]; then
                  echo "claude-managed-settings: no git marketplace read from local.claudePlugins.marketplaces —" >&2
                  echo "the allowlist leg below would pass over an empty set. Re-read that option." >&2
                  exit 1
                fi
                allowedGit=$(jq -r '.strictKnownMarketplaces // [] | .[] | select(.source == "git") | .url' "$managed")
                unlisted=0
                while IFS= read -r url; do
                  [ -n "$url" ] || continue
                  if ! printf '%s\n' "$allowedGit" | grep -qxF "$url"; then
                    echo "  NOT in strictKnownMarketplaces: $url" >&2
                    unlisted=1
                  fi
                done <<< "${lib.concatStringsSep "\n" gitMarketplaces}"

                if [ "$unlisted" -ne 0 ]; then
                  echo "" >&2
                  echo "claude-managed-settings: local.claudePlugins.marketplaces declares the sources above," >&2
                  echo "but modules/darwin/claude-managed-settings.nix's strictKnownMarketplaces has no" >&2
                  echo "byte-identical git entry for them, so 'marketplace add' is refused by policy." >&2
                  echo "Add the exact URL there; the list is restated, not derived, on purpose." >&2
                  exit 1
                fi

                # The reverse leg: an exact `git` entry no declared marketplace uses is a
                # stale trust grant — the restated list outlived the source it was for.
                stale=0
                while IFS= read -r url; do
                  [ -n "$url" ] || continue
                  if ! printf '%s\n' "${lib.concatStringsSep "\n" gitMarketplaces}" | grep -qxF "$url"; then
                    echo "  NOT a declared marketplace: $url" >&2
                    stale=1
                  fi
                done <<< "$allowedGit"

                if [ "$stale" -ne 0 ]; then
                  echo "" >&2
                  echo "claude-managed-settings: modules/darwin/claude-managed-settings.nix's" >&2
                  echo "strictKnownMarketplaces allows the git sources above, but" >&2
                  echo "local.claudePlugins.marketplaces declares none of them. Remove the entry," >&2
                  echo "or declare the marketplace it was added for." >&2
                  exit 1
                fi

                echo "managed floor carries all ${toString (builtins.length secretRules)} secret-value rules from the user scope, and allows exactly the ${toString (builtins.length gitMarketplaces)} declared git marketplaces" > "$out"
              '';

          # ---- The nixpi Wi-Fi roster is DATA, read at provision time --------------
          #
          # The SSIDs `nixpi-wifi-creds` ranks into `priority=` blocks were a list in
          # identity.nix until 2026-11-02; the global no-data rule moved them to a
          # hand-placed, Drive-backed file (packages/nixpi-provision.nix § THE ROSTER).
          # A check cannot grep for values it must not contain, so this pins the
          # MECHANISM, both halves:
          #   * STRUCTURE — no `config.fleet` binding and no argument of the provisioning
          #     package is named for Wi-Fi/SSIDs, so the slot that held them is gone.
          #   * BEHAVIOUR — the BUILT tool reads the roster from its env/XDG path, in
          #     array order, lets --ssid replace it, and FAILS CLOSED (absent, unparsable,
          #     empty, blank SSID) without printing a conf. Every case stops before the
          #     Keychain lookup succeeds (a fixture SSID has no item), so the sandbox
          #     needs no Keychain and no networksetup.
          nixpi-wifi-roster =
            let
              wifiNamed = names: lib.filter (n: builtins.match ".*(wifi|ssid).*" (lib.toLower n) != null) names;
              slots =
                wifiNamed (lib.attrNames config.fleet)
                ++ wifiNamed (lib.attrNames (builtins.functionArgs (import ../../packages/nixpi-provision.nix)));
              bin = "${self'.packages.nixpi-wifi-creds}/bin/nixpi-wifi-creds";
            in
            pkgs.runCommand "nixpi-wifi-roster" { } (
              if slots != [ ] then
                ''
                  echo "nixpi-wifi-roster: a Wi-Fi roster slot is back in the repo: ${toString slots}" >&2
                  echo "  The SSIDs are the operator's data — packages/nixpi-provision.nix § THE ROSTER." >&2
                  exit 1
                ''
              else
                ''
                  fail() { echo "nixpi-wifi-roster: $*" >&2; exit 1; }
                  # case NAME EXPECTED-STDERR CMD... — must exit non-zero, print NOTHING on
                  # stdout (no half conf), and say EXPECTED on stderr.
                  case_() {
                    name=$1 want=$2; shift 2
                    if "$@" > out.txt 2> err.txt; then fail "$name: exited 0"; fi
                    [ ! -s out.txt ] || fail "$name: printed a conf on stdout"
                    grep -qF -- "$want" err.txt || { cat err.txt >&2; fail "$name: stderr lacks: $want"; }
                    echo "ok  $name" >> "$out"
                  }
                  export HOME="$PWD/home" XDG_CONFIG_HOME="$PWD/xdg"
                  mkdir -p "$HOME" xdg/nix-config
                  dflt="$PWD/xdg/nix-config/nixpi-wifi-roster.json"

                  case_ "absent, default XDG path" "no Wi-Fi roster at $dflt" env -u NIXPI_WIFI_ROSTER ${bin}
                  case_ "absent, NIXPI_WIFI_ROSTER" "no Wi-Fi roster at $PWD/nope.json" env NIXPI_WIFI_ROSTER="$PWD/nope.json" ${bin}
                  printf '{' > bad.json
                  case_ "unparsable" "is not a valid roster" env NIXPI_WIFI_ROSTER="$PWD/bad.json" ${bin}
                  printf '{"networks":[]}' > empty.json
                  case_ "empty networks" "is not a valid roster" env NIXPI_WIFI_ROSTER="$PWD/empty.json" ${bin}
                  printf '{"networks":[{"ssid":"fixture-primary"},{"ssid":""}]}' > blank.json
                  case_ "blank ssid" "is not a valid roster" env NIXPI_WIFI_ROSTER="$PWD/blank.json" ${bin}

                  printf '%s' '{"networks":[{"ssid":"fixture-primary","role":"primary"},{"ssid":"fixture-failover","role":"failover"}]}' > "$dflt"
                  case_ "valid roster read in order" "no saved password for 'fixture-primary'" env -u NIXPI_WIFI_ROSTER ${bin}
                  case_ "--ssid replaces the roster" "no saved password for 'fixture-oneoff'" env -u NIXPI_WIFI_ROSTER ${bin} --ssid fixture-oneoff
                ''
            );
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # ---- Determinate owns this daemon TOO — and `nix.*` stays LIVE ------
          #
          # The mirror of the darwin `determinate-daemon-macos` above, and the whole
          # reason it is a separate list: it is NOT the same contract. The pinned
          # input's modules/nixos.nix is ADDITIVE — it swaps `nix.package` for
          # Determinate's Nix, points nix-daemon's ExecStart at determinate-nixd,
          # and merely RETARGETS the generated conf to /etc/nix/nix.custom.conf,
          # which the nixd-managed /etc/nix/nix.conf includes. `nix.settings`
          # therefore keeps applying, and both modules/nixos/core.nix and
          # modules/nixos/nix-cache.nix are written assuming exactly that.
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
          # states (in the ungated block below): drop the module and `config.determinate` stops
          # existing, so a direct read degrades into "attribute 'determinate'
          # missing" inside a trivial-builder stack trace instead of the
          # explanation below. A guard whose message nobody reads is not a guard.
          #
          # NOT COVERED: `nix.settings` being live is asserted, not the content of
          # /etc/nix/nix.conf on the running Pi — the file is rendered at
          # activation and this is eval. It also says nothing about nixvm, which
          # gets the same module and would be a second (cheap) host to add if it
          # ever stops being throwaway.
          determinate-daemon-nixpi =
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
              name = "determinate-daemon-nixpi";
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
                "every NixOS host, and modules/nixos/nix-cache.nix supplies the ONE"
                "substituter that has a prebuilt aarch64-linux Determinate Nix."
                "Without both, nixpi's next generation compiles Nix from C++ source on an"
                "SD card that CLAUDE.md says must never build. Fix the wiring; do not"
                "relax this, and never answer it by building on the Pi."
              ];
            };
        }
        // {
          # The li run-metadata allowlist (modules/_lib/li-runs-pipeline.nix) run through the
          # REAL otelcol-contrib, with the same attrsets the Mac's collector ships with. Every
          # fixture is synthetic and carries the things that must never leave: a text slug in
          # the path, URLs and paths in msg, a page excerpt, an address-shaped path, a
          # free-text framework line and a non-JSON line. The test fails if any of them, or
          # any key outside the allowlist, reaches the exporter.
          li-runs-allowlist =
            let
              pipe = import ../_lib/li-runs-pipeline.nix {
                runsDir = "RUNS_DIR";
                storageDir = "STORAGE_DIR";
              };
              runFile = "2026-01-02T03_04_05Z-fetch-ads-desktop-abc123.log.jsonl";
              line = builtins.toJSON;
              at = "2026-01-02T03:04:06.123Z";
              base = e: {
                inherit at;
                event = e;
                level = "info";
                logger = "tool_x.run";
                msg = "see https://site.invalid/cat/list-a/region-b/secret-slug-words-12345678";
              };
              fixtures = [
                (base "start" // { run_id = "ignored"; })
                (
                  base "run_card"
                  // {
                    card = {
                      command = "fetch-ads";
                      stage = "2/7";
                      purpose = "free text purpose";
                      live_log.path = "/cloud/someone@mail.invalid/My Drive/x.log.jsonl";
                      scale = {
                        eta_s = 60;
                        per_minute = 7;
                        planned = {
                          ad = 3;
                          robots = 1;
                        };
                        blocking = "free text blocking";
                      };
                      triggered_by = {
                        user = "someone";
                        proxy = "vpn.host.invalid:1080";
                      };
                    };
                  }
                )
                (
                  base "preflight"
                  // {
                    egress = {
                      loc = "XX";
                      trace_url = "https://trace.invalid/cdn-cgi/trace";
                    };
                  }
                )
                (
                  base "request"
                  // {
                    kind = "ad";
                    path = "/cat/list-a/region-b/secret-slug-words-12345678";
                    final_path = "/cat/list-a/region-b/secret-slug-words-12345678";
                    status = 200;
                    ms = 1482.7;
                    hops = 0;
                    counts.ad_pages = 1;
                  }
                )
                (
                  base "request"
                  // {
                    kind = "ad";
                    path = "/cat/list-a/region-b/other-slug-words-87654321";
                    status = null;
                    ms = 10.2;
                  }
                )
                (
                  base "request"
                  // {
                    kind = "list";
                    path = "/cat/list-a/region-b";
                    page = 10;
                    status = 200;
                    ms = 900.1;
                  }
                )
                (base "gone" // { reason = "expired_notice"; })
                (
                  base "challenge"
                  // {
                    level = "warning";
                    reason = "signin_wall";
                    path = "/cat/list-a/region-b/secret-slug-words-12345678";
                    evidence = {
                      status = 200;
                      hops = 0;
                      excerpt = "page excerpt text";
                      title = "page title text";
                      cf_ray = "ray-id";
                      snapshot = "STATE:snap/x.html.gz";
                    };
                  }
                )
                (
                  base "subresources"
                  // {
                    msg = "site sub-resources per page: blocked 15.0 / answered 39.8 / sent 9.0 (4 pages)";
                  }
                )
                (base "probe" // { msg = "probe clean"; })
                (
                  base "stop"
                  // {
                    level = "warning";
                    code = 6;
                    msg = "stopped (exit 6): 3 challenges for site.invalid within 0:10:00 (last: unexpected_page at https://site.invalid/cat/list-a/region-b/secret-slug-words-12345678 aborted";
                    counts = {
                      ad_pages = 57;
                      robots = 2;
                    };
                  }
                )
              ];
              rawLines = map line fixtures ++ [
                (line {
                  inherit at;
                  level = "info";
                  logger = "framework.crawler";
                  msg = "free text with https://site.invalid/cat/list-a/region-b/secret-slug-words-12345678";
                })
                "not json at all https://site.invalid/secret-slug-words"
              ];
              want = builtins.length fixtures;
              config = {
                inherit (pipe) extensions receivers processors;
                exporters.file.path = "OUT_FILE";
                service = {
                  extensions = lib.attrNames pipe.extensions;
                  telemetry.metrics.level = "none";
                  pipelines."logs/li_runs" = pipe.pipeline // {
                    exporters = [ "file" ];
                  };
                };
              };
              assertPy = pkgs.writeText "li-runs-assert.py" ''
                import json, sys
                out, allow, want = sys.argv[1], set(json.loads(sys.argv[2])), int(sys.argv[3])
                def val(v):
                    return next(iter(v.values())) if v else None
                recs = []
                for raw in open(out):
                    for rl in json.loads(raw)["resourceLogs"]:
                        res = {a["key"]: val(a["value"]) for a in rl["resource"].get("attributes", [])}
                        for sl in rl["scopeLogs"]:
                            for lr in sl["logRecords"]:
                                a = {x["key"]: val(x["value"]) for x in lr.get("attributes", [])}
                                recs.append((res, val(lr["body"]), a))
                bad = []
                if len(recs) != want: bad.append(f"{len(recs)} records, want {want}")
                blob = json.dumps(recs)
                for s in ("slug", "://", "mail.invalid", "excerpt", "title text", "STATE:", "free text", "vpn.host", "ray-id", "someone", "not json"):
                    if s in blob: bad.append(f"leaked {s!r}")
                for res, body, a in recs:
                    if res != {"service.name": "li-runs"}: bad.append(f"resource {res}")
                    if body != a.get("event"): bad.append(f"body {body!r}")
                    extra = set(a) - allow
                    if extra: bad.append(f"{a.get('event')}: keys outside the allowlist {sorted(extra)}")
                    if a.get("run_id") != "2026-01-02T03:04:05Z-fetch-ads-desktop-abc123": bad.append(f"run_id {a.get('run_id')}")
                by = {}
                for _, b, a in recs: by.setdefault(b, []).append(a)
                ad = [a for a in by.get("request", []) if a.get("req_kind") == "ad"]
                if sorted(a.get("ad_id") for a in ad) != ["12345678", "87654321"]: bad.append(f"ad ids {ad}")
                if [a.get("redirected") for a in ad if "redirected" in a] != [False]: bad.append("redirected")
                if not any(a.get("status") == "none" for a in ad): bad.append("status none")
                if by["challenge"][0].get("ad_id") != "12345678": bad.append("challenge ad_id")
                st = by["stop"][0]
                if (st.get("stop_reason"), st.get("stop_scope"), st.get("c_ad_pages")) != ("unexpected_page", "budget", 57): bad.append(f"stop {st}")
                if by["subresources"][0].get("sub_answered") != "39.8": bad.append("subresources")
                if by["probe"][0].get("result") != "clean": bad.append("probe")
                if by["preflight"][0].get("result") != "passed": bad.append("preflight")
                if by["run_card"][0].get("planned_ad") != 3: bad.append("run_card")
                if bad:
                    print("\n".join("  x " + b for b in bad), file=sys.stderr); sys.exit(1)
                print(f"{len(recs)} records, {len(allow)} allowed keys: nothing outside the allowlist left")
              '';
            in
            pkgs.runCommand "li-runs-allowlist"
              {
                nativeBuildInputs = [
                  (import ../_lib/otelcol-contrib.nix pkgs)
                  pkgs.python3
                ];
                CONFIG = builtins.toJSON config;
                LINES = lib.concatStringsSep "\n" rawLines + "\n";
              }
              ''
                mkdir runs storage
                export HOME="$TMPDIR"
                printf '%s' "$CONFIG" | sed -e "s#RUNS_DIR#$PWD/runs#" -e "s#STORAGE_DIR#$PWD/storage#" \
                  -e "s#OUT_FILE#$PWD/out.jsonl#" -e 's#"start_at":"end"#"start_at":"beginning"#' > config.json
                printf '%s' "$LINES" > runs/${runFile}
                otelcol-contrib --config config.json > collector.log 2>&1 &
                pid=$!
                for _ in $(seq 1 60); do
                  [ "$(grep -o '"timeUnixNano"' out.jsonl 2>/dev/null | wc -l)" -ge ${toString want} ] && break
                  sleep 0.5
                done
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                [ -s out.jsonl ] || { cat collector.log >&2; echo "no output" >&2; exit 1; }
                python3 ${assertPy} out.jsonl '${builtins.toJSON pipe.allowlist}' ${toString want} > "$out"
              '';

          # ---- the hook scripts, type-checked against Anthropic's OWN hook types ----
          #
          # `.claude/hooks/*.js` speak the hook protocol by hand: they parse the event
          # JSON from stdin and print a decision object. `// @ts-check` + JSDoc typedefs
          # imported from `@anthropic-ai/claude-agent-sdk` (PreToolUseHookInput,
          # StopHookInput, SyncHookJSONOutput, and the `sdk-tools` BashInput /
          # FileWriteInput / FileEditInput) make tsc check both ends of that protocol, plus
          # `strict` over everything in between. Types only: the scripts still run under
          # plain `node`, with no dependency, and the annotations are comments.
          #
          # Pins: typescript is nixpkgs' own (7.0.2 at this pin) — the native compiler,
          # so no node in the closure; every compiler option is explicit in
          # .claude/hooks/tsconfig.json, because TS 6/7 flipped the defaults. The npm
          # pins live with the tree: packages/hook-types-node-modules.nix, which the
          # devShell also links into the worktree for the editor (packages/link-hook-types.nix).
          #
          # Why a flake check, not an `npx tsc` step in claude-config-lint.yml: the
          # `actionlint` precedent below — the tool comes from this repo's pinned
          # nixpkgs, one less supply-chain edge, and the gate runs locally in
          # `nix flake check` instead of only in CI.
          #
          # The hook types are plain object types and resolve fully (proven 2026-11-07:
          # a wrong `hook_event_name` literal, a number `command` and `decision: "allow"`
          # each failed).
          hook-types =
            let
              hooks = lib.fileset.toSource {
                root = ../../.claude/hooks;
                fileset = lib.fileset.unions [
                  (lib.fileset.fileFilter (f: f.hasExt "js") ../../.claude/hooks)
                  ../../.claude/hooks/tsconfig.json
                ];
              };
            in
            pkgs.runCommand "hook-types" { nativeBuildInputs = [ pkgs.typescript ]; } ''
              cp -r ${hooks} hooks
              chmod -R u+w hooks
              # A symlink to the store tree, the same shape link-hook-types gives the editor.
              ln -s ${self'.packages.hook-types-node-modules} hooks/node_modules
              if ! tsc -p hooks; then
                echo "" >&2
                echo "hook-types: fix the type errors above in .claude/hooks/*.js. Annotations are" >&2
                echo "JSDoc only — never change what a hook does to satisfy the checker." >&2
                exit 1
              fi
              echo "hook-types: $(ls hooks/*.js | wc -l | tr -d " ") hook scripts type-check (strict) against ${self'.packages.hook-types-node-modules.name}" > "$out"
            '';

          # ---- Workflow literals that restate a fleet fact -----------------------
          #
          # GitHub Actions YAML cannot import Nix, so two fleet facts are RE-TYPED in
          # .github/workflows/: the Cachix public key (every `extra-trusted-public-keys`
          # line) and the heartbeat slug + cron of the two scheduled workflows that ping
          # healthchecks.io. A second copy is a bug with a delayed fuse, so these gate
          # the copies against the one source (config.fleet.cachixKey,
          # config.fleet.heartbeats) instead of trusting them. Rendering the YAML from
          # Nix was the alternative; it loses because a workflow is proven only by the
          # run it changes, and a generated file would still need this comparison to
          # catch a hand edit.
          cachix-key-parity =
            let
              dir = ../../.github/workflows;
              files = lib.attrNames (
                lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".yml" n) (builtins.readDir dir)
              );
              # Every `<cache>.cachix.org-1:<base64>` literal in a file.
              keysIn =
                n:
                map builtins.head (
                  builtins.filter builtins.isList (
                    builtins.split "([a-z0-9-]+\\.cachix\\.org-1:[A-Za-z0-9+/=]+)" (builtins.readFile (dir + "/${n}"))
                  )
                );
              found = lib.concatMap (n: map (k: { inherit n k; }) (keysIn n)) files;
              wrong = builtins.filter (e: e.k != config.fleet.cachixKey) found;
            in
            mkHostContract {
              inherit pkgs;
              name = "cachix-key-parity";
              subject = "every workflow's Cachix key literal equals config.fleet.cachixKey";
              expect = [
                {
                  name = "at least one workflow carries the key (else this check proves nothing)";
                  ok = found != [ ];
                }
              ]
              ++ map (e: {
                name = "${e.n}: ${e.k} != config.fleet.cachixKey";
                ok = false;
              }) wrong;
              advice = [
                "The key is defined once, in modules/parts/identity.nix (cachixKey). Fix the"
                "workflow literal to match it; rotate the key there first, then here."
              ];
            };

          heartbeat-workflow-parity =
            let
              dir = ../../.github/workflows;
              # slug -> the workflow that pings it. Kept HERE, not as a field on the
              # registry type: it is a fact about this repo's YAML, not about a check.
              pingers = {
                nix-config-update-flake-lock = "update-flake-lock.yml";
                nix-config-gitleaks = "gitleaks.yml";
                nix-config-grafana-rollup = "grafana-rollup.yml";
              };
              # Scheduled workflows that deliberately ping NO heartbeat, each with its reason.
              # Every other workflow with a `cron:` must be a pinger above, so a new scheduled
              # job cannot go silent unwatched.
              unwatched = {
                # A sweeper, not a job with an outcome: a missed run delays an arming that the
                # next run (or a manual click) does, and the PRs it arms are visible anyway.
                "arm-dependabot.yml" = "best-effort sweeper; a missed run only delays the next arming";
                # A probe whose FAILURE is the signal (a failed scheduled run emails the owner).
                # What it cannot report is its own silence; making it a pinger needs a
                # fleet.heartbeats entry and an hc-checks apply (FOLLOW-UP).
                "mcp-portal-probe.yml" = "a failed run is the alert; a heartbeat waits on an hc-checks apply";
              };
              cronFiles = builtins.filter (n: lib.hasInfix "cron:" (builtins.readFile (dir + "/${n}"))) (
                lib.attrNames (
                  lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".yml" n) (builtins.readDir dir)
                )
              );
              pingerFiles = lib.attrValues pingers;
              unwatchedCron = builtins.filter (n: !(lib.elem n pingerFiles) && !(unwatched ? ${n})) cronFiles;
              # slug -> the in-repo file that pings it from the Mac. A fact about this
              # repo's files, like `pingers`. Each entry is a `period`, so there is no
              # cron to compare: the legs are "registered" + "names the slug".
              agentPingers = {
                # the launchd agent nix-terranix-drift; its package holds the slug default
                nix-config-terranix-drift = ../../packages/terranix-drift.nix;
              };
              hb = config.fleet.heartbeats;
              agentLegs = lib.concatLists (
                lib.mapAttrsToList (slug: file: [
                  {
                    name = "${slug} is in fleet.heartbeats with a period";
                    ok = (hb.${slug} or null) != null && hb.${slug}.period != null;
                  }
                  {
                    name = "${baseNameOf file} pings the slug ${slug}";
                    ok = lib.hasInfix "\"${slug}\"" (builtins.readFile file);
                  }
                ]) agentPingers
              );
              legs = lib.concatLists (
                lib.mapAttrsToList (
                  slug: file:
                  let
                    text = builtins.readFile (dir + "/${file}");
                    entry = hb.${slug} or null;
                  in
                  [
                    {
                      name = "${slug} is in fleet.heartbeats with a cron schedule";
                      ok = entry != null && entry.schedule != null;
                    }
                    {
                      name = "${slug}: timezone is UTC, the only zone GitHub cron runs in";
                      ok = entry != null && entry.timezone == "UTC";
                    }
                    {
                      name = "${file} schedules the registry cron (${toString (entry.schedule or "")})";
                      ok = entry != null && lib.hasInfix "cron: \"${toString entry.schedule}\"" text;
                    }
                    {
                      name = "${file} pings the slug ${slug}";
                      ok = lib.hasInfix "/\${PING_KEY}/${slug}" text;
                    }
                  ]
                ) pingers
              );
              # A new `nix-config-*` entry is a workflow pinger by naming convention, so
              # it must be added to `pingers` (or `agentPingers`) above or this check
              # cannot see it.
              unmapped = builtins.filter (
                n: lib.hasPrefix "nix-config-" n && !(pingers ? ${n}) && !(agentPingers ? ${n})
              ) (lib.attrNames hb);
            in
            mkHostContract {
              inherit pkgs;
              name = "heartbeat-workflow-parity";
              subject = "the workflow heartbeat pingers match fleet.heartbeats (slug + cron)";
              expect =
                legs
                ++ agentLegs
                ++ [
                  {
                    name = "every nix-config-* heartbeat has a pinger in pingers or agentPingers (unmapped: ${toString unmapped})";
                    ok = unmapped == [ ];
                  }
                  {
                    name = "every workflow with a cron: is a pinger or listed in unwatched (neither: ${toString unwatchedCron})";
                    ok = unwatchedCron == [ ];
                  }
                ];
              advice = [
                "modules/parts/heartbeats.nix is the registry; the workflow's `cron:` and its"
                "Heartbeat ping step's slug must restate it exactly, or the check alerts on a"
                "schedule the workflow does not run (or never hears its pings)."
              ];
            };

          # ---- Linting the acceptance harness WITHOUT packaging it ---------------
          #
          # scripts/drv-snapshot.sh is the second test suite (CLAUDE.md § Testing):
          # it captures `nix flake show --json` plus every host toplevel, package and
          # check drvPath, so a refactor can be accepted on an empty diff. It is
          # deliberately NOT a flake package — that would add a `packages` row to the
          # very output set it measures — and the cost of that was silence: its header
          # told the operator to run `nix develop -c shellcheck` BY HAND, so the one
          # script in this repo whose job is to catch unintended change was the one
          # nothing checked.
          #
          # A shellcheck gate does not need a package. This is `bootstrap-lint`'s
          # shape with the string-comparison half removed: shellcheck over a SOURCE
          # PATH LITERAL, which copies one file into the store and builds a
          # derivation that is not an output of anything.
          #
          # WHY THIS DOES NOT PERTURB THE BASELINE, which is the whole reason the
          # script is unpackaged. The harness compares `outputs.tsv` by
          # `<category>:<system>:<name>` -> drvPath, and keeps an explicit exclusion
          # list for entries that "change on EVERY commit for reasons that have
          # nothing to do with a wave" — formatting, ast-grep, pre-commit and the
          # rest, all of which take `self` as a source input so their hash tracks the
          # working tree. This check takes ONE FILE, not `self`: its drvPath moves
          # only when drv-snapshot.sh itself moves. So it behaves exactly like
          # `bootstrap-lint`, which has sat unexcluded in every baseline since the
          # harness existed. Adding it is a one-time, named, two-row delta (one per
          # system) — re-baseline once; do not add it to EXCLUDE_RE, which is for
          # per-commit churn this is not.
          #
          # Ungated rather than darwin-only (bootstrap-lint is darwin-only because
          # bootstrap.sh bootstraps a Mac): shellcheck's verdict on plain bash is
          # platform-independent, and the harness is a dev tool either leg can run.
          #
          # NOT COVERED: that the harness WORKS. shellcheck is a syntax and
          # quoting lint; it cannot tell whether `--compare` still diffs the right
          # files.
          #
          # #768 IS THE MEASUREMENT. `--compare` walked a hand-maintained list of
          # filenames, so once [redacted] was retired and the script stopped
          # writing `personal.tsv`, every CLEAN run reported REJECTED — for weeks,
          # shellcheck-clean the whole time, because a wrong list of filenames is
          # perfectly valid bash. That exemplar is now HISTORY, not a standing
          # defect: #768 derives the set from the capture it has just taken, and a
          # clean run prints ACCEPTED with exit 0 again.
          #
          # The CLASS it proved is not fixed and cannot be, which is why this note
          # stays. A `--compare` that compared ZERO files, or diffed the capture
          # against itself, would be exactly as shellcheck-clean as the bug above.
          # Running the harness on a change meant to move code without changing
          # what the fleet builds is still the only test of that.
          drv-snapshot-lint =
            pkgs.runCommand "drv-snapshot-lint" { nativeBuildInputs = [ pkgs.shellcheck ]; }
              ''
                shellcheck --shell=bash ${../../scripts/drv-snapshot.sh}
                echo "scripts/drv-snapshot.sh is shellcheck-clean" > "$out"
              '';

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
          # SUBSTRING for hosts-documented, a RESOLVED LINK for docs-indexed —
          # and that split is a 2026-10-02 correction, not the original design.
          #
          # The substring rule was written for both, and the reasoning still holds
          # for hosts-documented: a parser over CLAUDE.md's prose would break on
          # every table reflow and become the thing people delete, so the only
          # question worth mechanising is "is this file NAMED anywhere the reader
          # would look". A host profile is named in prose and in table cells, never
          # linked, so there is no target to resolve and nothing better to test.
          #
          # For docs/*.md it was WRONG, and measurably so. A document is always
          # referenced as a markdown LINK, and a substring test cannot tell a
          # working link from a broken one. docs/repo-map.md carried 38 links
          # written `](docs/<name>.md)` from INSIDE docs/, every one resolving to
          # docs/docs/<name>.md — a directory that has never existed — and
          # docs-indexed was GREEN on all 38, because `secrets-and-keychain.md` is
          # a substring of `docs/secrets-and-keychain.md`. The gate proved the
          # filename was MENTIONED somewhere in the index and was read as proving
          # the document was reachable from it. Those are different claims, and
          # only the second is worth a build failure.
          #
          # So docs-indexed now requires a link whose target RESOLVES to the file.
          # That is strictly stronger and it is still not a prose parser: it reads
          # link targets, which are syntax, and ignores every word around them.
          # docs-links-resolve below is the companion gate — same resolution
          # question asked of EVERY link in every tracked markdown file, rather
          # than only of links pointing at docs/.
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
                indexes = docIndexPaths;
                # The second half (ADR-012 § 5 step 5): the GENERATED host + app block
                # must equal the render. A diff in the builder, never lib.hasInfix — the
                # SIGSEGV note above. Extending this check rather than adding a sibling
                # keeps it inside drv-snapshot's EXCLUDE_RE, which already lists it.
                manifest = generatedManifest pkgs;
              }
              ''
                ${lib.optionalString (hostFiles == [ ] || docIndexPaths == [ ]) ''
                  echo "hosts-documented: VACUOUS — ${toString (lib.length hostFiles)} host files, ${toString (lib.length docIndexPaths)} indexes. An empty side is never a pass." >&2
                  exit 1
                ''}
                stale=
                while IFS=$'\t' read -r name doc docPath render begin end; do
                  awk -v b="$begin" -v e="$end" '
                    $0 == b { f = 1 } f { print } $0 == e { f = 0 }
                  ' "$docPath" > committed.md
                  if ! diff -u committed.md "$render" > generated.diff; then
                    echo "hosts-documented: the GENERATED $name span in $doc differs from the flake." >&2
                    if [ ! -s committed.md ]; then
                      echo "  Its BEGIN/END GENERATED markers are missing." >&2
                    fi
                    cat generated.diff >&2
                    stale=1
                  fi
                done < "$manifest"
                if [ -n "$stale" ]; then
                  echo "" >&2
                  echo "The flake changed under a generated span. Regenerate every span:" >&2
                  echo "  nix run .#docs-generate" >&2
                  exit 1
                fi
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
                  echo "hosts/: all ${toString (lib.length hostFiles)} host profiles are named in one of the ${toString (lib.length docIndexPaths)} documentation indexes; every generated span (${lib.concatStringsSep ", " (lib.attrNames generatedBlocks)}) matches the flake" > "$out"
                  exit 0
                fi

                echo "hosts-documented: host profiles that no index names." >&2
                printf '  %s\n' "''${undocumented[@]}" >&2
                echo "" >&2
                echo "CLAUDE.md calls itself an index and binds the author to update it when repo" >&2
                echo "shape changes. A host file named nowhere is invisible to the next reader and" >&2
                echo "to every agent that reads CLAUDE.md as its map. Name it in the hosts/ row of" >&2
                echo "CLAUDE.md, or in docs/map/hosts.md, and re-run." >&2
                exit 1
              '';

          # ADR-014 § 5 step 3. infra.md's stack table keeps prose columns (state, credential,
          # blast radius), which are judgment and stay hand-written. Its ROW SET is a fact, and
          # modules/_lib/terranix-stacks.nix owns it (every wrapper's state_dir reads it), so
          # this gates the rows both ways instead of generating a second copy of the table.
          # CLAUDE.md's infra/ row points here rather than listing stacks (the copy that
          # missed `cf-ai-search`, hygiene NH-A-map-drift 2026-11-25).
          infra-stacks-documented =
            let
              names = lib.naturalSort (import ../_lib/terranix-stacks.nix).names;
            in
            pkgs.runCommand "infra-stacks-documented"
              {
                doc = ../../docs/map/infra.md;
                want = pkgs.writeText "stacks.txt" (lib.concatMapStrings (n: n + "\n") names);
              }
              ''
                ${lib.optionalString (names == [ ]) ''
                  echo "infra-stacks-documented: VACUOUS — terranix-stacks.nix lists no stacks." >&2
                  exit 1
                ''}
                # The table opens at its `| Stack | State |` header and ends at the first
                # non-table line. Column 1 is the stack name in backticks.
                awk '/^\| Stack \| State \|/ { t = 1; next }
                     t && !/^\|/ { exit }
                     t && /^\| `/ { split($0, c, "`"); print c[2] }' "$doc" | sort > have.txt
                sort "$want" > want.txt
                if [ ! -s have.txt ]; then
                  echo "infra-stacks-documented: no stack table (| Stack | State | header) in docs/map/infra.md." >&2
                  exit 1
                fi
                if ! diff -u want.txt have.txt > rows.diff; then
                  echo "infra-stacks-documented: docs/map/infra.md's stack table and modules/_lib/terranix-stacks.nix disagree." >&2
                  echo "  - = a stack with no row; + = a row for no stack." >&2
                  cat rows.diff >&2
                  exit 1
                fi
                echo "infra.md: all ${toString (lib.length names)} terranix stacks have a row, and every row is a stack" > "$out"
              '';

          # ADR-014 § 4 B — value once. A literal that has a binding is written ONLY in that
          # binding; docs and comments name the binding. Each entry reads its value from the
          # evaluated config (never a second literal here), and the check fails if the value,
          # as a whole word, appears in any tracked file but `home`, or twice in `home`.
          # fleetAppId first: hygiene found its digits ~10 times (NH-C-fact-twice, 2026-11).
          values-once =
            let
              entries = [
                {
                  name = "fleetAppId";
                  home = "hosts/macos.nix";
                  value = toString self.darwinConfigurations.macos.config.local.macosGithubRunner.appId;
                }
              ];
            in
            pkgs.runCommand "values-once"
              {
                nativeBuildInputs = [
                  pkgs.gnugrep
                  pkgs.coreutils
                ];
              }
              ''
                cd ${self}
                bad=
                ${lib.concatMapStrings (e: ''
                  hits=$(grep -rnwF --exclude-dir=.git -- ${lib.escapeShellArg e.value} . | grep -v -F -- "./${e.home}:" || true)
                  inHome=$(grep -cwF -- ${lib.escapeShellArg e.value} ${lib.escapeShellArg e.home} || true)
                  if [ -n "$hits" ] || [ "$inHome" != 1 ]; then
                    echo "values-once: ${e.name}'s value must appear once, in ${e.home} (found $inHome there)." >&2
                    [ -n "$hits" ] && printf '%s\n' "$hits" | sed 's/^/  copy: /' >&2
                    bad=1
                  fi
                '') entries}
                if [ -n "$bad" ]; then
                  echo "Name the binding instead of writing its value." >&2
                  exit 1
                fi
                echo "values-once: ${lib.concatMapStringsSep ", " (e: e.name) entries} each written once" > "$out"
              '';

          # ADR-014 § 4 C, mechanized. A paragraph in one live agent-facing doc that is a
          # near-copy of one in another fails; scope, method and the measurement that set the
          # threshold are in the script's header. Pure Python over the source, no network.
          docs-near-duplicates =
            pkgs.runCommand "docs-near-duplicates" { nativeBuildInputs = [ pkgs.python3 ]; }
              ''
                python3 -I ${../../scripts/near-duplicates.py} ${self} > "$out"
              '';

          # SUBJECTS include docs/map/ since the 2026-10-02 split. `readDir
          # ../../docs` filtered on `t == "regular"`, and `map` is a DIRECTORY —
          # so the eleven domain files would have escaped this check entirely, by
          # the very commit that created them. That is the capsule-registry
          # lesson in reverse: not a gate that forgot a new file, but a gate whose
          # scope a reorganisation silently shrank.
          #
          # docs/map/*.md are BOTH subjects and indexes, deliberately. Index,
          # because the detail they now hold is what CLAUDE.md and repo-map.md
          # used to carry — docs/map/docs-index.md is where every docs/*.md
          # annotation lives, so excluding it would fail this check on a pure
          # move. Subject, because an unreachable domain file is exactly the rot
          # this check exists to catch, and nothing else would notice: the budget
          # gate proves a file is *gated*, not that a reader can *find* it. There
          # is no self-satisfaction loophole — a file's own breadcrumb points up
          # at ../repo-map.md, never at itself.
          #
          # ---- SCOPE: what this gate answers, and what it does NOT -------------
          #
          # It answers exactly ONE question: is every document under docs/ named
          # by a link, in one of the indexes, whose target RESOLVES to that
          # document's own path. Subjects are the `.md` REGULAR files in docs/
          # (minus docs/repo-map.md, the root index, which is not an entry) plus
          # each docs/map/*.md. Indexes are CLAUDE.md, docs/repo-map.md and every
          # docs/map/*.md. Measured on this tree 2026-10-02: 49 subjects, 13
          # indexes, green.
          #
          # NOT in scope, and each omission is someone else's question:
          #   · WHETHER THE TARGET EXISTS. `realpath -m` is purely lexical, so a
          #     link to a deleted file still resolves to a path — it simply will
          #     not equal any subject. Existence is docs-links-resolve's question,
          #     over every link in every tracked .md rather than only the ones
          #     aimed at docs/.
          #   · FRAGMENT-ONLY LINKS (`#section`) and URL-SCHEMED targets (https:,
          #     mailto:) are DROPPED before resolving — neither can name a file in
          #     this repo. A heading that no longer exists is prose rot, not a
          #     broken index entry.
          #   · ANYTHING OUTSIDE docs/. A `.md` elsewhere in the tree (a capsule
          #     README, .claude/**) is never a subject here.
          #   · WHETHER THE LINK TEXT IS TRUE. A row that links a file correctly
          #     and describes it wrongly passes. This catches absence, not rot —
          #     the shared "NOT COVERED" note above applies unchanged.
          #
          # NON-EMPTY, asserted: `readDir` filtered on `t == "regular"` drops
          # directories, so re-nesting docs/map/ would empty `mapIndexNames` and
          # shrink this gate's scope while it stayed green. The builder now fails
          # on an empty subject list, an empty index list, or no docs/map/ entries.
          docs-indexed =
            let
              docFiles =
                lib.naturalSort (
                  lib.attrNames (
                    lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n && n != "repo-map.md") (
                      builtins.readDir ../../docs
                    )
                  )
                )
                ++ map (n: "map/${n}") mapIndexNames;
            in
            pkgs.runCommand "docs-indexed" { nativeBuildInputs = [ pkgs.coreutils ]; } ''
              ${lib.optionalString (docFiles == [ ] || docIndexNames == [ ] || mapIndexNames == [ ]) ''
                echo "docs-indexed: VACUOUS — ${toString (lib.length docFiles)} documents, ${toString (lib.length docIndexNames)} indexes, ${toString (lib.length mapIndexNames)} docs/map entries. An empty side is never a pass." >&2
                exit 1
              ''}
              cd ${self}

              # Collect every link target the two indexes carry, each resolved
              # against ITS OWN directory. That per-index resolution is the whole
              # correction: the identical string `docs/x.md` is correct written
              # from CLAUDE.md at the repo root and broken written from
              # docs/repo-map.md one level inside docs/.
              #
              # `realpath -m` is purely lexical and does NOT require the target to
              # exist, which is what we want here — a broken link still resolves to
              # some path, it just will not match any real document, and that
              # mismatch is the failure this check reports. Whether the path exists
              # at all is docs-links-resolve's question, not this one.
              #
              # Dropped before resolving: fragment-only links (`#section`) and
              # anything carrying a URL scheme (https:, mailto:). Neither can name
              # a file in this repo.
              linked="$TMPDIR/linked"
              : > "$linked"
              for idx in ${lib.escapeShellArgs docIndexNames}; do
                grep -oE '\]\([^)[:space:]]+\)' "$idx" \
                  | sed -e 's/^](//' -e 's/)$//' -e 's/#.*$//' \
                  | grep -vE '^[a-zA-Z][a-zA-Z0-9+.-]*:' \
                  | grep -v '^$' \
                  | while IFS= read -r target; do
                      realpath -m --relative-to=. "$(dirname "$idx")/$target"
                    done >> "$linked"
              done

              unlinked=()
              for f in ${lib.escapeShellArgs docFiles}; do
                grep -qxF -- "docs/$f" "$linked" || unlinked+=("$f")
              done

              if [ ''${#unlinked[@]} -eq 0 ]; then
                echo "docs/: all ${toString (lib.length docFiles)} documents are reachable by a resolving link from one of the ${toString (lib.length docIndexNames)} indexes" > "$out"
                exit 0
              fi

              echo "docs-indexed: documents that no index LINKS TO resolvably." >&2
              printf '  docs/%s\n' "''${unlinked[@]}" >&2
              echo "" >&2
              echo "An unlinked document is one nobody finds and nobody updates, which is how a" >&2
              echo "runbook rots into a trap. Link it from CLAUDE.md's Documentation list or from" >&2
              echo "docs/map/docs-index.md — or, for a docs/map/ file, from the Contents table" >&2
              echo "in docs/repo-map.md. Only docs/repo-map.md itself is exempt: it is the root" >&2
              echo "index, not an entry." >&2
              echo "" >&2
              echo "NOTE: being MENTIONED is no longer enough — the link target must resolve to" >&2
              echo "the file. From CLAUDE.md (repo root) that is docs/<name>.md; from" >&2
              echo "docs/map/docs-index.md (one level deeper) it is ../<name>.md. Writing the" >&2
              echo "root-relative form from inside docs/ yields docs/docs/<name>.md and fails here." >&2
              exit 1
            '';

          # ---- every relative markdown link must RESOLVE on disk ----------------
          #
          # docs-indexed above answers "is this document reachable from an index".
          # This answers the other half, for every link rather than only the ones
          # pointing at docs/: does the target EXIST. Those came apart on
          # 2026-10-02 — 38 links in docs/repo-map.md pointed at docs/docs/*, a
          # directory that has never existed, and no gate in this file noticed,
          # because the only one looking did a substring test on the filename.
          # That is the second false-success shape in
          # docs/false-success-signals.md: a check whose green means something
          # weaker than what its name is read as promising.
          #
          # OFF THE SHELF: lychee --offline (nixpkgs lychee 0.24.2). Measured
          # 2026-10-02: the aarch64-linux build SUBSTITUTES prebuilt — 7.4 MiB
          # download, 23.7 MiB unpacked — so the Mac never compiles a Rust crate
          # for the Linux leg, which was the one real objection to using a tool
          # here instead of shell. Alternatives weighed and rejected: `mlc` and
          # `linkchecker` are built around HTTP crawling with no equally direct
          # local-only mode; `markdown-link-check` is an npm package whose offline
          # behaviour is a per-file JSON config. Hand-rolled grep + `realpath` was
          # the fourth option and lost on fragment and scheme handling, which
          # lychee already gets right — docs-indexed keeps a small version of that
          # shell only because it needs per-index resolution, which lychee does not
          # expose.
          #
          # OUT OF SCOPE, deliberately:
          #   · `#anchor` fragments — lychee reports a bare fragment OK because
          #     --include-fragments is NOT passed. Whether a heading still exists
          #     is prose rot; that is /hygiene's job and a reader's, not a link
          #     resolver's.
          #   · absolute URLs (http:, https:) and mailto: — --offline EXCLUDES
          #     every scheme-bearing target without a network call, which is also
          #     what makes this runnable in the build sandbox at all. 145 of the
          #     400 links in the tree are excluded on this rule.
          #
          # `${self}` is the git-tracked tree, so the eval-time walk that builds
          # mdFiles sees exactly what CI sees — the same reasoning ast-grep uses
          # below. Scope is EVERY tracked .md, not a hand-listed pair of paths: a
          # path list is one more thing to update when a document moves, and
          # repo-wide was already green when this landed (77 files, 400 links, 0
          # errors), so the wider net cost nothing to adopt.
          #
          # THE VACUITY GUARD IS LOAD-BEARING. `lychee` given an input that
          # matches no file prints "No files found for this input source" to
          # stderr and EXITS 0 — measured, with `lychee --offline 'docs/nope-*.md'`
          # reporting "0 Total" and success. A renamed directory would therefore
          # turn this gate green by checking nothing, which is the "green build
          # over an empty directory" failure the retired userscript gate's note
          # further down warns was worse than having no gate. Both halves are
          # asserted: that warning is fatal here, and a zero link total is fatal.
          docs-links-resolve =
            let
              mdFiles =
                let
                  walk =
                    prefix: dir:
                    lib.concatLists (
                      lib.mapAttrsToList (
                        name: type:
                        let
                          rel = if prefix == "" then name else "${prefix}/${name}";
                        in
                        if type == "directory" then
                          walk rel (dir + "/${name}")
                        else if type == "regular" && lib.hasSuffix ".md" name then
                          [ rel ]
                        else
                          [ ]
                      ) (builtins.readDir dir)
                    );
                in
                lib.naturalSort (walk "" ../..);
            in
            pkgs.runCommand "docs-links-resolve"
              {
                nativeBuildInputs = [
                  pkgs.lychee
                  pkgs.jq
                ];

                # NOT a network dependency, and nothing here ever opens a socket —
                # the sandbox has no network and --offline resolves no URL. lychee
                # builds its reqwest HTTP client during startup regardless of mode,
                # and that constructor refuses to exist without a trust store:
                # "No CA certificates were loaded from the system". nixpkgs points
                # SSL_CERT_FILE at the deliberately absent /no-cert-file.crt inside
                # the sandbox precisely so this surfaces, so the client must be
                # handed real roots or lychee cannot start.
                #
                # Measured 2026-10-02, and it is a ONE-PLATFORM failure: this check
                # built green on aarch64-darwin and failed on aarch64-linux at the
                # first attempt, because the two targets reach for different TLS
                # backends. Same asymmetry the hasInfix note above records, so the
                # same conclusion applies — build every check on BOTH systems, not
                # on the one the author happens to be sitting at.
                SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              }
              ''
                cd ${self}

                report="$TMPDIR/report.json"
                warnings="$TMPDIR/lychee.err"

                rc=0
                lychee --offline --no-progress --format json \
                  ${lib.escapeShellArgs mdFiles} > "$report" 2> "$warnings" || rc=$?

                # lychee exits 2 for "link errors found" and 1 for its own
                # failures, so only 0 and 2 mean the run itself worked and left a
                # parseable report behind.
                if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
                  echo "docs-links-resolve: lychee itself failed (exit $rc), so NOTHING was checked." >&2
                  cat "$warnings" >&2
                  exit 1
                fi

                if grep -q 'No files found for this input source' "$warnings"; then
                  echo "docs-links-resolve: lychee was handed an input that matched no file." >&2
                  grep 'No files found for this input source' "$warnings" >&2
                  echo "" >&2
                  echo "This exits 0 in lychee, so the gate would have passed having checked nothing." >&2
                  echo "The input list is built by an eval-time walk of the tracked tree, so this means" >&2
                  echo "a file moved between eval and build — re-run, and if it persists, report it." >&2
                  exit 1
                fi

                total=$(jq -er '.total' "$report")
                errors=$(jq -er '.errors' "$report")

                if [ "$total" -eq 0 ]; then
                  echo "docs-links-resolve: zero links examined across ${toString (lib.length mdFiles)} markdown files." >&2
                  echo "That is not a pass. Either every link vanished or the inputs did." >&2
                  exit 1
                fi

                if [ "$errors" -ne 0 ]; then
                  echo "docs-links-resolve: $errors unresolvable link target(s)." >&2
                  echo "" >&2
                  jq -r '
                    .error_map
                    | to_entries[]
                    | .key as $file
                    | .value[]
                    | "  \($file):\(.span.line // 0): \(.url)"
                  ' "$report" >&2
                  echo "" >&2
                  echo "Each target above was resolved relative to the file CONTAINING the link and" >&2
                  echo "does not exist. The classic case is a root-relative path written from inside a" >&2
                  echo "subdirectory: docs/<name>.md from docs/repo-map.md resolves to" >&2
                  echo "docs/docs/<name>.md. From inside docs/ use the bare sibling name." >&2
                  echo "" >&2
                  echo "Anchors, http(s) URLs and mailto: links are NOT checked here and cannot be" >&2
                  echo "the cause of a failure above." >&2
                  exit 1
                fi

                echo "markdown links: $total examined across ${toString (lib.length mdFiles)} tracked files, every relative target resolves" > "$out"
              '';

          # ---- no LINE NUMBERS into this repo's own files, in living text --------
          #
          # A `path:N` citation into a file this repo edits stops pointing at what
          # it names the moment that file grows above line N, and nothing notices.
          # Measured 2026-10-17 over the whole tree: of 146 citations that resolve
          # to a tracked file, 75 no longer held the text they cited (54 moved, 21
          # rewritten away) — including the global CLAUDE.md, which sent every
          # session to the wrong lines of claude-guardrails.nix for the
          # `--force-with-lease` carve-out. #839 and #840 re-pointed them at the
          # construct each one names (an option, a binding, a block), which cannot
          # drift by line. This gate keeps it that way.
          #
          # A FORBID lint, not a drift detector. Detecting drift needs the commit a
          # citation was written at, and the build sandbox has no git history; the
          # blame-based instrument that found the 75 also produced snapshot false
          # positives (a reflowed line blames to a later commit). A lint needs only
          # the tree and cannot cry wolf on a correct citation, because there are
          # no correct ones left to make. Rejected too: ast-grep (it cannot resolve
          # a path against the tree, and does not parse markdown), Semgrep (its
          # generic mode matches comments, but it cannot resolve a path either and
          # is not in this fleet), and docref, the
          # one off-the-shelf tool found for this (it hashes symbols into a
          # lockfile, has no Nix support, and is what naming the construct does by
          # hand).
          #
          # `P:N` is IN-REPO when P, as written, names a tracked file: from the
          # root, from the citing file's directory, or (no slash) as a basename
          # exactly one tracked file carries. Citing a PINNED input stays allowed
          # and is told apart by leading with the input's name —
          # `home-manager/modules/launchd/default.nix:411`, `nix-darwin/flake.nix:59`
          # — which no tracked path starts with. That is not a suppression marker;
          # it answers "which default.nix?", which a bare basename never did.
          #
          # Living text is every tracked .nix/.md/.js/.sh/.yml EXCEPT the as-of
          # records: ADRs, studies, plans and the retired mcp-* docs, where a
          # pointer into code that has since moved is the expected state, and
          # .claude/agent-memory. A `./` or `../` prefix is part of the path. Bare `:N` continuations and the second half of
          # an `:N-M` range are not parsed; the first number of a range is.
          #
          # The scanner runs on two fixtures BEFORE the tree — one citation that
          # must be flagged and one input-qualified citation that must not — so it
          # cannot rot into a green check that matches nothing. A zero count of
          # examined citations is fatal for the same reason.
          line-refs-cite-constructs =
            pkgs.runCommand "line-refs-cite-constructs"
              {
                nativeBuildInputs = [
                  pkgs.findutils
                  pkgs.gnugrep
                  pkgs.gawk
                  pkgs.coreutils
                ];
              }
              ''
                set -euo pipefail

                # scan ROOT -> stdout: "<file>:<line>: <citation>" per in-repo
                # line citation; stderr's last line: the count of citations seen.
                scan() (
                  cd "$1"
                  files="$TMPDIR/files.$$"
                  uniq_base="$TMPDIR/uniq.$$"
                  find . -type f -printf '%P\n' | LC_ALL=C sort > "$files"
                  awk -F/ '{print $NF}' "$files" | LC_ALL=C sort | uniq -u > "$uniq_base"
                  seen=0
                  while IFS= read -r f; do
                    d=$(dirname "$f")
                    while IFS= read -r hit; do
                      seen=$((seen + 1))
                      ln=''${hit%%:*}
                      tok=''${hit#*:}
                      p=''${tok%:*}
                      p=''${p#./}
                      if [ -f "$p" ] || [ -f "$d/$p" ] \
                        || { [ "''${p#*/}" = "$p" ] && grep -qxF -- "$p" "$uniq_base"; }; then
                        echo "$f:$ln: $tok"
                      fi
                    done < <(grep -noP '(?<![A-Za-z0-9_./-])(?:\.\.?/)*[A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:nix|js|sh|ya?ml|md|py|json|toml):[0-9]+' "$f" || true)
                  done < <(grep -E '\.(nix|md|js|sh|ya?ml)$' "$files" \
                    | grep -vE '^(docs/[^/]*-adr\.md|docs/[^/]*study[^/]*\.md|docs/[^/]*-plan\.md|docs/mcp-[^/]*\.md|\.claude/agent-memory/.*)$')
                  echo "$seen" >&2
                )

                fx="$TMPDIR/fixture"
                mkdir -p "$fx/a" "$fx/y"
                echo x > "$fx/y/z.nix"
                printf '# see y/z.nix:3\n' > "$fx/a/bad.nix"
                printf '# see nix-darwin/y/z.nix:3\n' > "$fx/a/ok.nix"
                # A `./`-relative citation must be flagged too — the regex once
                # could not start a match at `.`, so the `p#./` strip never ran.
                printf '# see ./z.nix:3\n' > "$fx/y/rel.nix"
                want=$(printf '%s\n' "a/bad.nix:1: y/z.nix:3" "y/rel.nix:1: ./z.nix:3")
                got=$(scan "$fx" 2>/dev/null)
                if [ "$got" != "$want" ]; then
                  echo "line-refs-cite-constructs: the scanner failed its own fixture." >&2
                  echo "  want exactly: $want" >&2
                  echo "  got:          ''${got:-<nothing>}" >&2
                  exit 1
                fi

                hits=$(scan ${self} 2> "$TMPDIR/seen")
                seen=$(tail -n1 "$TMPDIR/seen")
                if [ "$seen" -eq 0 ]; then
                  echo "line-refs-cite-constructs: examined 0 citations in the tree, so NOTHING was checked." >&2
                  exit 1
                fi
                if [ -n "$hits" ]; then
                  echo "line-refs-cite-constructs: line-number citations into this repo's OWN files." >&2
                  printf '%s\n' "$hits" | sed 's/^/  /' >&2
                  echo "" >&2
                  echo "A line number into a file this repo edits points at the wrong line as soon as" >&2
                  echo "that file changes above it. Cite the construct instead: the option, binding" >&2
                  echo "or block (e.g. \"hosts/macos.nix's homebrew.casks\"), which grep finds forever." >&2
                  echo "Citing a PINNED input is fine: lead the path with the input's name, e.g." >&2
                  echo "home-manager/modules/launchd/default.nix:411 or nix-darwin/flake.nix:59." >&2
                  echo "As-of records (ADRs, studies, plans, retired mcp-* docs) are not scanned." >&2
                  exit 1
                fi
                echo "file:line citations: $seen examined in living text, none into this repo's own files" > "$out"
              '';

          # ---- the uplink watchdog and firmware provisioning name the same file -
          #
          # The watchdog and the firmware-secrets capsule share three facts, and
          # NOTHING but this check makes them agree: the runtime wpa config path,
          # the card filename behind it, and the unit that consumes it. Rename any
          # of them in one place and the watchdog keeps evaluating, keeps starting,
          # and silently rewrites or restarts the wrong thing — the failure only
          # shows up during an outage, which is the one moment nobody wants to be
          # debugging it. Since 2026-10-01 `local.lanRecovery` gives that moment a
          # LAN sshd to debug FROM, but only while the Pi is on a segment you are
          # also on; a renamed interface breaks that path too, which is the third
          # thing `nixpi-security-posture` now joins to these two.
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
          # supplicant before its conf. On a headless Pi reachable REMOTELY only
          # through that connector, that is a ~40-minute trip to the shelf and a full
          # verified re-flash (docs/nixpi-sd-flashing-runbook.md).
          #
          # Values measured against the live config on 2026-09-12, before the
          # capsule move. Ungated for the reason uplink-watchdog-paths-agree
          # gives: the rename it catches is made on the Mac.
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
            in
            mkHostContract {
              inherit pkgs expect;
              name = "nixpi-firmware-names";
              subject = "nixpi firmware/connector contract";
              advice = [
                "These names are agreed by STRING across hosts/nixpi.nix,"
                "modules/features/cloudflared-connector/ and"
                "modules/features/firmware-secrets/. A break here evaluates fine"
                "and --dry-activates fine on an"
                "ALREADY-PROVISIONED card; it only surfaces on the next flash, as a"
                "Pi that never brings its tunnel up. Fix the name, do not relax this."
              ];
            };

          # ---- nixpi's security posture, which until now only PROSE held ------
          #
          # modules/nixos/core.nix's services.openssh block carries three careful paragraphs on why
          # sshd binds loopback only, why `openFirewall = false` is the knob that
          # actually keeps 22 shut, and why the TCP allow-list stays tiny. A
          # comment cannot fail a build. Every one of those lines is a one-token
          # edit away from reopening the LAN path that the Cloudflare Access
          # application in front of nixpi.<domain> is meant to be the only REMOTE
          # way through (the LAN path is local.lanRecovery's, scoped per interface) — and Access enforces at the EDGE, so a LAN connection to
          # port 22 is not merely unauthenticated, it produces NO ACCESS LOG AT
          # ALL. There is nothing to notice afterwards. That is what makes this
          # worth an eval-time gate rather than a comment.
          #
          # Each leg names its own silent-failure mode:
          #
          #   openFirewall — upstream's default is TRUE (pinned nixpkgs
          #     nixos/modules/services/networking/ssh/sshd.nix:312, and :874 feeds
          #     cfg.ports straight into allowedTCPPorts). It is false ONLY because
          #     core.nix's `openFirewall = false` says so, so deleting that one line reopens 22 on the
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
          #     generated block lives in the same string. Note the direction:
          #     extraConfig is CUMULATIVE, so it can only ever ADD a bind. Now that
          #     the expected pair IS the wildcard, this leg no longer catches a
          #     widening — it catches a THIRD address appearing, and the option leg
          #     beside it is what catches a narrowing.
          #   no explicit `port` on a listen address, because nixpkgs renders
          #     `ListenAddress ::1:22` UNBRACKETED (sshd.nix:901). OpenSSH reads
          #     that as the address ::0.1.0.34, the v6 bind fails EADDRNOTAVAIL,
          #     and sshd SURVIVES (a failed bind is fatal only if EVERY bind
          #     fails) — so v6 loopback silently vanishes. Measured with
          #     `sshd -G`; the transcript is in core.nix's listenAddresses comment.
          #   the firewall allow-list is SEVERAL legs, not one. nixpi runs the
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
          #     bluntest: :149 accepts ALL traffic arriving on a named
          #     interface, no port list consulted. Upstream sets it to [ "lo" ]
          #     itself (firewall.nix:334), so the leg pins that value rather than
          #     emptiness.
          #     SINCE 2026-10-01 the per-interface path is no longer purely a
          #     widening risk — it is where nixpi's LAN recovery ingress lives. So
          #     it is read TWICE, in opposite directions: that a per-interface list
          #     exists at all and names exactly what `local.lanRecovery` declares
          #     (a narrowing guard), and that each entry carries nothing but the
          #     sshd port on any protocol (the widening guard the leg always was).
          #     The GLOBAL list stays pinned to [ 80 ] separately, because that one
          #     renders with no `-i` and so has no interface scope to speak of.
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
          # hosts/nixpi.nix's allowedTCPPorts opens the Caddy ORIGIN port (443 omitted — TLS
          # terminates at Cloudflare's edge) and core.nix's `allowedTCPPorts = [ ]` MERGES with
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
          # Ungated, like secrets-sync below and unlike determinate-daemon-nixpi in
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
          # NOT COVERED, and the 2026-10-01 outage is why this paragraph now comes
          # with a warning rather than a footnote. THIS CHECK CANNOT TELL YOU THE
          # PI IS UP. It is EVAL, not runtime — no `sshd -G`, no `iptables -S`, no
          # TCP connect, no ping — and an already-flashed Pi keeps whatever its
          # current generation has until the next deploy. On 2026-10-01 every leg
          # here was GREEN while the host was unreachable by every route: the
          # connector was dead, the site answered Cloudflare 1033, and SSH timed out
          # at banner exchange. A green build means "the config still declares the
          # posture it is supposed to", and nothing more. REACHABILITY IS NOT
          # CHECKABLE FROM A DERIVATION: a fixed-output network probe would be
          # cached, non-hermetic, and would make a router outage fail CI for every
          # unrelated change. What IS checkable, and is the lesson that outage
          # bought, is that the config still declares a SECOND ingress — so the next
          # edit that quietly restores the single point of failure fails the build
          # instead of waiting for the next outage to announce itself. Runtime
          # health belongs to a monitor, not to `nix flake check`; there is none
          # today, and that gap is real.
          #
          # Three further CONFIG paths are known and deliberately ungated:
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
          #   the rest of sshd_config. A `Port` smuggled through extraConfig is
          #     harmless here — the binds are pinned and the allow-list is
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
              # rather than slipping past a read of the user-facing option. The
              # `default` pseudo-interface is the GLOBAL list under another name
              # (firewall.nix:308-311) and is covered by its own legs, so the
              # per-interface legs drop it and read what is genuinely `-i`-scoped.
              perIface = lib.filterAttrs (n: _: n != "default") (fw.allInterfaces or { });
              perIfaceEntries = lib.attrValues perIface;

              sortStrings = lib.sort (a: b: a < b);
              perIfaceKeys = sortStrings (lib.attrNames perIface);

              # The SECOND INGRESS half. `or null` so a deleted module reads as
              # broken here rather than throwing from inside the builder.
              lan = pi.local.lanRecovery or null;
              lanIfaces = if lan == null then null else sortStrings lan.interfaces;

              # The same two interface names, spelled independently TWICE more on
              # this host — the watchdog's wired interface and the supplicant
              # instances. Joining them here is what makes a rename loud: rename
              # the radio to wlp2s0 in one place and the LAN port silently never
              # opens there, which (like the watchdog paths above) only shows up
              # during an outage, the one moment nobody can debug it.
              namedIfaces = sortStrings (
                lib.unique (
                  lib.optional (
                    pi.local.uplinkWatchdog.wiredInterface or null != null
                  ) pi.local.uplinkWatchdog.wiredInterface
                  ++ lib.attrNames (pi.networking.supplicant or { })
                )
              );
              # mDNS is the LAN ingress's ENTRY POINT (`nixpi.local`), and it is
              # scoped to the wired interface alone: two interfaces on one LAN make
              # avahi lose a probe race against itself and rename the host for good
              # (measured 2026-10-17, avahi#117 — hosts/nixpi.nix). `or null` so a
              # vanished option reads as broken rather than throwing.
              avahi = pi.services.avahi or { };
              avahiIfaces = avahi.settings.server.allow-interfaces or null;
              wiredIface = pi.local.uplinkWatchdog.wiredInterface or null;
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

              # The two WILDCARD families, mirroring the loopback pair core.nix
              # declares for every other host. They do not collide: sshd sets
              # IPV6_V6ONLY on every AF_INET6 listener (openssh sshd.c:851-853 via
              # misc.c:2044-2056, read at the source), so these are two disjoint
              # sockets rather than one dual-stack bind plus a duplicate.
              wildcard = [
                "0.0.0.0"
                "::"
              ];
              # The GLOBAL UDP lists. #718 added a per-interface leg that asserts UDP is
              # empty on each `-i`-scoped interface, which left the GLOBAL list — the
              # one that renders with NO interface match — unasserted on every
              # protocol but TCP. mDNS is why it is non-empty: avahi publishes
              # `nixpi.local`, which is the entry point the LAN ingress is reached by,
              # so 5353 is load-bearing and named rather than merely tolerated.
              udp = fw.allowedUDPPorts or null;
              udpRanges = fw.allowedUDPPortRanges or null;
              mdns = [ 5353 ];

              # A RADIO is not a port, so nothing above can see it. `hardware.bluetooth`
              # is the specific one worth pinning: enabling it powers the controller at
              # boot (`powerOnBoot` DEFAULTS TO TRUE) in the default `ControllerMode =
              # "dual"`, i.e. the dangerous direction is the default, and it changes the
              # host's attack surface without touching a single firewall option.
              bt = pi.hardware.bluetooth or { };
              btUnits = lib.filter (n: n == "bluetooth") (lib.attrNames (pi.systemd.services or { }));

              caddyOrigin = [ 80 ]; # hosts/nixpi.nix networking.firewall.allowedTCPPorts
            in
            mkHostContract {
              inherit pkgs;
              name = "nixpi-security-posture";
              subject = "nixpi: TWO declared ingresses, LAN-scoped sshd, no build trust";
              expect = [
                {
                  name = "the firewall is enabled at all";
                  ok = fw.enable or false;
                }
                {
                  name = "the GLOBAL TCP allow-list is EXACTLY the Caddy origin port — it has not grown";
                  ok = tcp == caddyOrigin;
                }
                {
                  name = "the GLOBAL TCP port-RANGE allow-list is empty — a range reaches the same accept rule";
                  ok = tcpRanges == [ ];
                }
                {
                  name = "trustedInterfaces is loopback alone — a trusted interface accepts EVERYTHING on it";
                  ok = trusted == [ "lo" ];
                }
                {
                  name = "no sshd port appears in the GLOBAL TCP allow-list — that renders with no interface match";
                  ok = tcp != null && sshPorts != [ ] && !(lib.any (p: lib.elem p tcp) sshPorts);
                }
                {
                  name = "services.openssh.openFirewall is false (upstream defaults it TRUE, and it writes the GLOBAL list)";
                  ok = !(ssh.openFirewall or true);
                }
                # ---- NOT TCP, AND NOT A PORT. Everything above reads TCP, so the
                # check stayed green against two whole classes of widening: a UDP
                # service added to the global list, and a RADIO, which has no port at
                # all. Same failure shape as the outage itself — a check that cannot
                # fail for the thing you are worried about.
                {
                  name = "the GLOBAL UDP allow-list is mDNS alone — 5353 is how nixpi.local resolves, nothing else belongs";
                  ok = udp == mdns;
                }
                {
                  name = "no GLOBAL UDP port RANGES — a range is the cheapest way to widen past the leg above";
                  ok = udpRanges == [ ];
                }
                {
                  name = "hardware.bluetooth is DISABLED — enabling it powers the controller at boot (powerOnBoot defaults TRUE)";
                  ok = !(bt.enable or false);
                }
                {
                  name = "no bluetooth unit reached the closure — the option above is the declared knob, this is the rendered result";
                  ok = btUnits == [ ];
                }
                # ---- the SECOND INGRESS. A build-time check cannot reach a running
                # host, so none of this proves the LAN path WORKS. What these
                # legs do is make its DELETION a build failure: the day someone
                # restores loopback-only sshd or drops the per-interface allow-list,
                # the single-point-of-failure comes back silently and green, which
                # is exactly how this check sat passing through a total outage on
                # 2026-10-01. Deleting a leg here to make a red build go away
                # recreates that.
                {
                  name = "local.lanRecovery is ENABLED — without it the tunnel is the SOLE ingress again";
                  ok = lan != null && (lan.enable or false);
                }
                {
                  name = "a per-interface TCP allow-list EXISTS — this is the LAN half of the second ingress";
                  ok = perIfaceKeys != [ ];
                }
                {
                  name = "the per-interface allow-list names EXACTLY the interfaces local.lanRecovery declares";
                  ok = lanIfaces != null && perIfaceKeys == lanIfaces;
                }
                {
                  name = "those interface names match the ones the watchdog and the supplicants independently spell";
                  ok = lanIfaces != null && lanIfaces == namedIfaces;
                }
                {
                  name = "avahi is ON and publishes on EXACTLY the wired interface — a second LAN interface makes it rename itself (avahi#117)";
                  ok = (avahi.enable or false) && wiredIface != null && avahiIfaces == [ wiredIface ];
                }
                {
                  name = "each LAN interface opens EXACTLY the sshd port, and nothing else on any protocol";
                  ok =
                    perIfaceEntries != [ ]
                    && sshPorts != [ ]
                    && lib.all (
                      e:
                      (e.allowedTCPPorts or null) == sshPorts
                      && (e.allowedTCPPortRanges or null) == [ ]
                      && (e.allowedUDPPorts or null) == [ ]
                      && (e.allowedUDPPortRanges or null) == [ ]
                    ) perIfaceEntries;
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
                  name = "sshd binds the wildcard EXPLICITLY, and BOTH families — the LAN half needs an off-loopback bind";
                  ok = addrsWellFormed && sortStrings addrs == wildcard;
                }
                {
                  name = "the RENDERED ListenAddress lines are that same wildcard pair — nothing smuggled through extraConfig";
                  ok = addrsWellFormed && sortStrings renderedAddrs == wildcard;
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
                "modules/nixos/core.nix owns the sshd and firewall DEFAULTS;"
                "modules/nixos/lan-recovery.nix owns the LAN ingress that overrides them;"
                "hosts/nixpi.nix owns the one globally open port (Caddy's origin, 80)"
                "and the interface list the LAN ingress is scoped to."
                "nixpi has TWO ingresses on purpose. The tunnel connector dials"
                "localhost:22 and is the only INTERNET path and the only one"
                "Cloudflare Access gates; the LAN path answers on the named"
                "interfaces alone and does NOT traverse Access, so it is neither"
                "identity-gated nor logged there. That cost was accepted on"
                "2026-10-01, when a dead connector left no way in but a 40-minute"
                "physical reflash; the exposure analysis is in lan-recovery.nix."
                "So there are two opposite ways to break this host here. WIDENING:"
                "the GLOBAL list, a port RANGE or a trusted interface all reach the"
                "same iptables accept rule with no interface match, which is why"
                "each has its own leg. NARROWING: putting sshd back on loopback, or"
                "dropping the per-interface list, restores the single point of"
                "failure that cost the reflash. Fix the config; relax neither half."
                "The build legs keep this leaf host free of outbound build trust and"
                "of a stray /etc/nix/machines."
              ];
            };

          # ---- The Workspace MCP portal's security posture, read off the RENDER --------
          #
          # The Workspace connectors reach Google through ONE Cloudflare MCP portal
          # (infra/cloudflare/mcp-portals.nix + workspace-mcp-apps.nix, stack cf-mcp-portals,
          # since 2026-11-14): every server attached with its tools OFF unless listed, each
          # user's own Google grant, an email-allowlisted Access app in front, and a DCR
          # callback list naming the MCP clients that may register. Every one of those is a
          # line someone can delete with a green plan, so each is a leg here, and the legs
          # read the RENDERED stack (`.config` of flake.lib.terranixStackRenders, the attrset
          # terranix serialises), not the apps file. Reading the apps file back at itself is
          # the failure mcp-launcher-parity's header records: a check that compares Nix with
          # itself cannot go red. trivy cannot do this: it reads no nested block from tf.json
          # (trivy-terranix's header has the measurement).
          #
          # The OAuth config reaches tofu only as the HCL string inside each server's
          # `auth_credentials` (a jsonencode, because the client id is a variable). Its
          # literals are plain text there, so the scope and endpoint legs EXTRACT them with a
          # regex and fail closed when it no longer matches — a reshaped string must turn
          # this red, never skip the leg.
          #
          # The guardrail leg pins modules/home/claude-guardrails.nix's ask rules for outward
          # connector verbs and high-impact phone tools. It is a deliberate SECOND COPY of
          # that list, like claude-managed-settings' deny floor: deriving the expectation from
          # the list it checks would pass on an emptied list.
          #
          # THE WRITE LEG (operator decision 2026-11-19, ALL, GUARDED): the portal may enable
          # an outward, destructive or edit tool only when BOTH guards name it: an ask
          # rule in claude-guardrails that matches its real connector name (the floor that
          # prompts under bypass), and the pinned kattakath-workspace plugin's write guard,
          # read from its generated references/guarded.json. Which tools NEED a guard is
          # decided HERE (outwardVerbs + editVerbs, on the bare upstream name), never from
          # guarded.json: deriving it from the plugin would pass an unguarded new tool. It
          # replaced two legs that forbade every outward tool and every write scope; the
          # scope leg now forbids only what no enabled tool needs (send, settings, full
          # Drive/Calendar/Chat, Keep).
          #
          # NOT COVERED: anything live — a dashboard edit, a server's one-time admin
          # authorization, a Google token minted before a scope was narrowed. The daily
          # mcp-portal-probe workflow covers the unauthenticated surface.
          #
          # NEGATIVE CONTROLS, 2026-11-14 — each turned exactly its leg RED and was reverted:
          # `default_disabled = false` in mcp-portals.nix (the attachment leg, naming all 8
          # servers); `https://*` and `http://evil.example.com/cb` added to allowed_uris
          # (the DCR leg, naming both).
          mcp-portal-posture =
            let
              stack = (config.flake.lib.terranixStackRenders pkgs.stdenv.hostPlatform.system).cf-mcp-portals;
              res = stack.config.resource or { };
              mcpApps = import ../../infra/cloudflare/workspace-mcp-apps.nix;
              portalHost = "${mcpApps.portalLabel}.${domainName}";

              portals = lib.attrValues (res.cloudflare_zero_trust_access_ai_controls_mcp_portal or { });
              servers = res.cloudflare_zero_trust_access_ai_controls_mcp_server or { };
              attached = lib.concatMap (p: p.servers or [ ]) portals;
              attachedIds = lib.sort lib.lessThan (map (s: s.server_id or "") attached);
              serverIds = lib.sort lib.lessThan (map (n: "${serverRef}${n}.id}") (lib.attrNames servers));
              # A `public` app (public data, no secret; operator 2026-11-19) is the ONE class
              # reached with no upstream credential and no per-user grant. Every other server
              # stays Google OAuth with on_behalf, as the 2026-11-14 audit decided.
              publicApps = lib.attrNames (lib.filterAttrs (_: a: a.public or false) mcpApps.apps);
              isPublic = n: lib.elem n publicApps;
              oauthServers = lib.filterAttrs (n: _: !(isPublic n)) servers;
              badPublic = lib.attrNames (
                lib.filterAttrs (
                  n: s:
                  isPublic n
                  && (
                    (s.auth_type or null) != "unauthenticated"
                    || s ? auth_credentials
                    || s ? client_secret
                    || builtins.match "https://[a-z0-9-]+\\.[a-z0-9-]+\\.run\\.app/mcp" (s.hostname or "") == null
                    || !(mcpApps.apps.${n} ? selfHosted)
                  )
                  || !(isPublic n) && (s.auth_type or null) != "oauth"
                ) servers
              );
              badAttach = lib.filter (
                s: (s.default_disabled or null) != true || (s.on_behalf or null) != !(isPublic (appOf s))
              ) attached;
              # A server id is an HCL reference to `<server>.<app>.id`; name the app, since
              # a dollar-brace inside a leg name is a bash substitution in mkHostContract's echo.
              serverRef = "\${cloudflare_zero_trust_access_ai_controls_mcp_server.";
              appOf = s: lib.removeSuffix ".id}" (lib.removePrefix serverRef (s.server_id or "?"));

              # ---- the Access apps in front of the portal and each server ----
              accessApps = res.cloudflare_zero_trust_access_application or { };
              portalApps = lib.filter (a: (a.type or "") == "mcp_portal") (lib.attrValues accessApps);
              unguarded = lib.attrNames (lib.filterAttrs (_: a: (a.policies or [ ]) == [ ]) accessApps);
              # The access policy admits exactly the Workspace domain: one include, an
              # email_domain equal to domainName. Never `everyone`, never another domain.
              allowPolicy = res.cloudflare_zero_trust_access_policy.allowed or { };
              allowInclude = allowPolicy.include or [ ];

              # ---- DCR: who may register as an MCP client ----
              dcr = map (a: a.oauth_configuration.dynamic_client_registration or { }) portalApps;
              uris = lib.concatMap (d: d.allowed_uris or [ ]) dcr;
              # https with a literal host (a `*` only in the path), or an exact custom scheme.
              uriOk =
                u:
                builtins.match "https://[a-z0-9.-]+(/[^*]*(\\*)?)?" u != null
                || (builtins.match "[a-z][a-z0-9+.-]*://[^*]+" u != null && !(lib.hasPrefix "http" u));
              badUris = lib.filter (u: !(uriOk u)) uris;

              # ---- the Google OAuth literals inside each server's auth_credentials ----
              grab =
                k: s:
                let
                  m = builtins.match ".*${k} = \"([^\"]*)\".*" (s.auth_credentials or "");
                in
                if m == null then null else builtins.head m;
              authEndpoints = lib.mapAttrsToList (_: grab "authorization_endpoint") oauthServers;
              googleAuth = "https://accounts.google.com/o/oauth2/v2/auth?";
              badEndpoints = lib.filter (
                e: e == null || !(lib.hasPrefix googleAuth e) || !(lib.hasInfix "access_type=offline" e)
              ) authEndpoints;
              scopeStrings = lib.mapAttrsToList (_: grab "scope") oauthServers;
              scopes = lib.concatMap (s: lib.filter (w: w != "") (lib.splitString " " s)) (
                lib.filter (s: s != null) scopeStrings
              );
              auth = "https://www.googleapis.com/auth/";
              # Scopes no enabled tool needs (2026-11-19): each is wider than the narrowest
              # one its tools accept (workspace-mcp-apps.nix cites the per-tool pages).
              # Sending, mail settings, full Drive/Calendar/Chat, and Keep stay out.
              forbiddenScopes = [
                "https://mail.google.com/"
                "${auth}gmail.send"
                "${auth}gmail.send.self"
                "${auth}calendar"
                "${auth}calendar.acls"
                "${auth}drive"
                "${auth}chat.messages"
                "${auth}chat.memberships"
                "${auth}chat.spaces"
                "${auth}chat.delete"
                "${auth}keep"
              ];
              # Whole strings, never substrings: `calendar` is a prefix of the allowed
              # `calendar.events.readonly`. The one family matched by prefix is
              # gmail.settings.*, every member of which can forward mail out.
              badScopes = lib.filter (
                s: lib.elem s forbiddenScopes || lib.hasPrefix "${auth}gmail.settings." s
              ) scopes;
              badUpstreams = lib.attrNames (
                lib.filterAttrs (
                  _: s:
                  # Google's own servers, or a self-hosted one on Cloud Run (operator's
                  # pick 2026-11-18: any run.app host, for the Tasks server).
                  builtins.match
                    "https://([a-z0-9-]+\\.googleapis\\.com/mcp(/v1)?|[a-z0-9-]+\\.[a-z0-9-]+\\.run\\.app/mcp)"
                    (s.hostname or "") == null
                  || (s.client_secret or "") != "\${var.google_oauth_client_secret}"
                ) oauthServers
              );

              # ---- the live probe probes what the render serves ----
              probe = builtins.readFile ../../.github/workflows/mcp-portal-probe.yml;
              probeVar =
                k:
                let
                  m = builtins.match ".*\n      ${k}: ([^\n]*)\n.*" probe;
                in
                if m == null then null else builtins.head m;

              # ---- the local floor: claude-guardrails' ask rules ----
              hm = config.flake.darwinConfigurations.macos.config.home-manager.users.${loginName};
              ask = hm.programs.claude-code.settings.permissions.ask or [ ];
              # ---- the cloud floor: a cloud session reads the repo's settings, never ~/.claude ----
              # So every server the user scope denies must be denied in .claude/settings.json too;
              # otherwise an unsigned or write-enabled plugin server runs in cloud sessions
              # (measured 2026-11-14: aws-core, aws-serverless and desktop-commander all did).
              serverNames = l: map (d: d.serverName or "") l;
              userDenied = serverNames (hm.programs.claude-code.settings.deniedMcpServers or [ ]);
              repoDenied = serverNames (
                (builtins.fromJSON (builtins.readFile ../../.claude/settings.json)).deniedMcpServers or [ ]
              );
              cloudMissingDeny = lib.filter (n: !(lib.elem n repoDenied)) userDenied;
              outwardVerbs = [
                "send_message"
                "send_email"
                "forward"
                "reply"
                "share_file"
                "download_gmail_attachment"
                "create_event"
                "update_event"
                "delete_event"
                "respond_to_event"
                "update_doc"
                "update_presentation"
                "update_values"
                "update_formulas"
                "append_values"
                "copy_sheet_to_another_spreadsheet"
                "update_file"
                "trash_*"
                "delete_*"
                "mark_*_spam"
                # Google Home (portal trial 2026-11-14): its only scope also controls devices.
                "run_home_actions"
                "save_automation"
                "submit_feedback"
              ];
              phoneTools = map (t: "mcp__plugin_android-phone_mobile-mcp__mobile_${t}") [
                "install_app"
                "uninstall_app"
                "clear_app_data"
                "clipboard"
                "open_url"
                "launch_app"
              ];
              missingAsk = lib.filter (r: !(lib.elem r ask)) (map (v: "mcp__*__${v}") outwardVerbs ++ phoneTools);
              # ---- the write leg: every enabled outward/edit tool carries BOTH guards ----
              # Edits that no outward verb names but that change or hide the user's data.
              editVerbs = [
                "unlabel_*"
                "update_message_labels"
                "apply_sensitive_*"
                "mark_as_*"
                "update_notification_settings"
                "update_spreadsheet"
                "insert_dimension"
              ];
              globRe = g: lib.replaceStrings [ "*" ] [ "[a-z_]*" ] g;
              enabledByApp = lib.concatMap (
                s:
                map (t: {
                  app = appOf s;
                  tool = t.name;
                }) (lib.filter (t: t.enabled or false) (s.updated_tools or [ ]))
              ) attached;
              enabledTools = map (x: x.tool) enabledByApp;
              needGuard = map (x: "${x.app}_${x.tool}") (
                lib.filter (
                  x: lib.any (v: builtins.match (globRe v) x.tool != null) (outwardVerbs ++ editVerbs)
                ) enabledByApp
              );
              # An ask rule's `*` read as "any characters", matched against the name
              # claude.ai's connector really gives the tool. That is the PERMISSIVE reading,
              # so a stricter matcher could miss a rule this passes; the guardrails use full
              # `mcp__*__<app>_<tool>` names, which match under either reading.
              connectorName = n: "mcp__claude_ai_Kattakath_Workspace__${n}";
              askMatches =
                n:
                lib.any (r: builtins.match (lib.replaceStrings [ "*" ] [ ".*" ] r) (connectorName n) != null) (
                  lib.filter (lib.hasPrefix "mcp__") ask
                );
              noAsk = lib.filter (n: !(askMatches n)) needGuard;
              guardedFile = "${inputs.kattakath-skills}/plugins/kattakath-workspace/skills/kattakath-workspace/references/guarded.json";
              # Fail closed: a missing file, or one without a `tools` list, guards nothing.
              guarded =
                if builtins.pathExists guardedFile then
                  (builtins.fromJSON (builtins.readFile guardedFile)).tools or [ ]
                else
                  [ ];
              noHook = lib.filter (n: !(lib.elem n guarded)) needGuard;
            in
            mkHostContract {
              inherit pkgs;
              name = "mcp-portal-posture";
              subject = "workspace MCP portal: tools off unless listed, per-user grants, gated apps, listed DCR clients";
              expect = [
                {
                  name = "ONE portal, at ${portalHost}, attaching every declared server exactly once";
                  ok =
                    lib.length portals == 1
                    && ((lib.head portals).hostname or null) == portalHost
                    && serverIds != [ ]
                    && attachedIds == serverIds;
                }
                {
                  name = "every attached server has default_disabled = true, and on_behalf = true unless its app is public (broken: ${toString (map appOf badAttach)})";
                  ok = attached != [ ] && badAttach == [ ];
                }
                {
                  name = "only a `public` self-hosted app is unauthenticated: run.app /mcp, no credential, no secret; every other server is oauth (broken: ${toString badPublic})";
                  ok = badPublic == [ ];
                }
                {
                  name = "every enabled outward/destructive/edit tool has an ask rule matching its connector name (missing: ${toString noAsk})";
                  ok = enabledTools != [ ] && needGuard != [ ] && noAsk == [ ];
                }
                {
                  name = "every enabled outward/destructive/edit tool is in the pinned write guard's guarded.json (missing: ${toString noHook})";
                  ok = guarded != [ ] && noHook == [ ];
                }
                {
                  name = "one mcp_portal Access app, and EVERY Access app has a policy (none: ${toString unguarded})";
                  ok = lib.length portalApps == 1 && unguarded == [ ];
                }
                {
                  name = "the allow policy admits exactly the Workspace domain (one email_domain include = ${domainName}), never everyone";
                  ok =
                    (allowPolicy.decision or null) == "allow"
                    && allowInclude == [ { email_domain.domain = domainName; } ];
                }
                {
                  name = "every DCR callback is https on a literal host or an exact custom scheme (bad: ${toString badUris})";
                  ok = uris != [ ] && badUris == [ ];
                }
                {
                  name = "every oauth server authorizes at Google with access_type=offline (unmatched or wrong: ${toString (lib.length badEndpoints)})";
                  ok = authEndpoints != [ ] && badEndpoints == [ ];
                }
                {
                  name = "every server's scope literal parses, and none is a send, mail-settings or full Drive/Calendar/Chat/Keep scope (found: ${toString badScopes})";
                  ok = scopeStrings != [ ] && !(lib.elem null scopeStrings) && badScopes == [ ];
                }
                {
                  name = "every server's upstream is a googleapis.com or run.app MCP endpoint and its secret is the variable (broken: ${toString badUpstreams})";
                  ok = badUpstreams == [ ];
                }
                {
                  name = "mcp-portal-probe.yml probes exactly the portal host this stack serves";
                  ok = "${toString (probeVar "PORTAL")}.${toString (probeVar "ZONE")}" == portalHost;
                }
                {
                  name = "the guardrails ASK before every outward connector verb and high-impact phone tool (missing: ${toString missingAsk})";
                  ok = missingAsk == [ ];
                }
                {
                  name = "the repo's .claude/settings.json denies every MCP server the user scope denies, so cloud sessions inherit the deny list (missing: ${toString cloudMissingDeny})";
                  ok = cloudMissingDeny == [ ];
                }
              ];
              advice = [
                "infra/cloudflare/workspace-mcp-apps.nix owns each app's tools and scopes;"
                "infra/cloudflare/mcp-portals.nix renders the servers, the portal and its Access apps;"
                "modules/home/claude-guardrails.nix owns the local ask rules."
                "Each leg is a decision of the 2026-11-14 security audit or the 2026-11-19 ALL, GUARDED"
                "decision. A red write leg: add the tool's ask rule in claude-guardrails AND a write-guard"
                "rule in kattakath/skills, then bump the kattakath-skills pin. To WIDEN a leg on purpose,"
                "change this check in the same commit and say why in its header — a red leg"
                "deleted to make the build pass is the silent widening this check exists for."
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

          # ---- the workflow YAML is linted by SOMETHING, finally -------------------
          # 2,083 lines of `.github/workflows/*.yml` were covered by nothing: treefmt
          # has no YAML tool, sgconfig's rules are Nix and JS, and claude-config-lint
          # only looks at .claude/. This class has already bitten twice IN THESE FILES
          # — nix-ci.yml's errexit bug made a REQUIRED gate report green over a failing
          # eval, and an `if:` made the same gate skip silently. Same shape as why
          # .claude/hooks/tests exists.
          #
          # `-shellcheck` is the point, not a nicety: the real findings were all inside
          # `run:` blocks, which plain YAML linting cannot see. It caught an actual
          # quoting bug (SC2027: `'"$SO"'` inside a double-quoted echo unquotes the
          # variable) plus two `'\''` sequences that are single-quote escaping used in a
          # DOUBLE-quoted string, where they are simply wrong.
          #
          # Run as a flake CHECK rather than a third-party action, following
          # .github/workflows/gitleaks.yml's precedent: the CLI comes from this repo's
          # own pinned nixpkgs, which is one less supply-chain edge and makes the gate
          # reproducible locally instead of only in CI.
          #
          # The SC2086 findings are disabled INLINE with their reason rather than fixed
          # or globally ignored: each relies on word-splitting deliberately (e.g. printf reusing
          # its format per word; `printf | wc -l` counting attrs), so quoting would be
          # the regression.
          actionlint =
            pkgs.runCommand "actionlint"
              {
                nativeBuildInputs = [
                  pkgs.actionlint
                  pkgs.shellcheck
                ];
              }
              ''
                # A PROJECT, not a bare store copy of workflows/: actionlint resolves a
                # local `uses: ./.github/workflows/<x>.yml` against the project root it
                # finds by walking up to a `.git`. From the store copy alone it found
                # none and SKIPPED caller->callee validation silently — measured
                # 2026-10-18: an undefined input passed to nix-ci-impl.yml exited 0 from
                # the bare copy, and failed `[workflow-call]` once an empty `.git`
                # marker sat above `.github/workflows`. The WHOLE `.github` tree is
                # copied, not just workflows/: with only workflows/ present, a bad input
                # to the local composite action `uses: ./.github/actions/nix-setup` also
                # exited 0, and failed `[action]` once `.github/actions` sat beside it
                # (actionlint 1.7.12). (Store names cannot start with `.`, hence the
                # renamed `builtins.path` and the copy.)
                mkdir -p proj/.git
                cp -r ${
                  builtins.path {
                    path = ../../.github;
                    name = "dot-github";
                  }
                } proj/.github
                cd proj/.github/workflows
                # actionlint resolves `shellcheck` from PATH; nativeBuildInputs puts it there.
                if ! actionlint -shellcheck=shellcheck ./*.yml; then
                  echo "" >&2
                  echo "actionlint: fix the findings above, or add an inline" >&2
                  echo "\`# shellcheck disable=SCxxxx\` WITH A ONE-LINE REASON next to the" >&2
                  echo "line it covers. Do not add a blanket ignore — these files hold the" >&2
                  echo "required \`gate\`, and two silent-green bugs have already shipped" >&2
                  echo "in them." >&2
                  exit 1
                fi
                echo "actionlint: $(ls ./*.yml | wc -l | tr -d " ") workflow files clean (with shellcheck)"
                touch "$out"
              '';

          # ---- zizmor: the SECURITY lint actionlint is not ----------------------------
          #
          # actionlint proves a workflow is well-formed; zizmor asks whether it is SAFE:
          # template injection, over-broad tokens, dangerous triggers, unpinned actions.
          # Same lane as actionlint — the CLI from the pinned nixpkgs (zizmor 1.31.0), run
          # as a check, not as a third-party action.
          #
          # Triage of 2026-11-14 at the default (regular) persona: 37 findings (80 counting
          # the 43 the persona suppresses). 9 were FIXED in the workflows, 28 are accepted
          # in the repo-root zizmor.yml with a reason each, per FILE and never per line.
          #
          # NOT COVERED: zizmor's ONLINE audits (impostor-commit, known-vulnerable-actions,
          # ref-confusion, stale-action-refs). They need the GitHub API; the sandbox has no
          # network, so `--offline` drops them. Pinning every action by SHA (already true)
          # is what stands in for them.
          #
          # COVERAGE IS ASSERTED, not assumed: zizmor exits 0 when it audits NOTHING.
          # Measured 2026-11-14: given `..` from inside .github/workflows it reported 0
          # findings over a tree that had 28. So the check counts the inputs zizmor says it
          # completed and requires every workflow file among them.
          #
          # NEGATIVE CONTROL (2026-11-14): a seeded workflow with an issue title expanded
          # inside `run:` turned this check RED (template-injection, high); the seed was
          # then deleted.
          zizmor =
            pkgs.runCommand "zizmor"
              {
                nativeBuildInputs = [ pkgs.zizmor ];
                # A PROJECT root, like actionlint above, so the reported paths read
                # `.github/workflows/<x>.yml` (what zizmor.yml's ignores match).
                github = builtins.path {
                  path = ../../.github;
                  name = "dot-github";
                };
                config = ../../zizmor.yml;
              }
              ''
                mkdir proj && cp -r "$github" proj/.github && chmod -R u+w proj && cd proj
                export HOME="$TMPDIR" XDG_CACHE_HOME="$TMPDIR/cache"
                status=0
                zizmor --offline --no-progress --color never --show-audit-urls never \
                  --render-links never --config "$config" .github > ../report.txt 2> ../log.txt || status=$?
                expected=$(ls .github/workflows/*.yml | wc -l)
                audited=$(grep -c 'completed \.github/workflows/.*\.yml$' ../log.txt || true)
                if [ "$audited" -ne "$expected" ]; then
                  cat ../log.txt >&2
                  echo "zizmor: audited $audited of $expected workflow files — a scan that skips files is not a gate." >&2
                  exit 1
                fi
                if [ "$status" -ne 0 ]; then
                  cat ../report.txt >&2
                  echo "" >&2
                  echo "zizmor: fix the findings above. An accepted one goes in the repo-root" >&2
                  echo "zizmor.yml, per FILE, with a one-line reason; never per line, which rots." >&2
                  exit 1
                fi
                echo "zizmor: $audited workflow files clean ($(tail -1 ../report.txt))" > "$out"
              '';

          # ---- trivy over EVERY rendered terranix stack -------------------------------
          #
          # `trivy config` (pinned nixpkgs, 0.76.0) over each stack's config.tf.json,
          # rendered exactly as its *-plan wrapper renders it (flake.lib.terranixStackRenders,
          # which throws if a stack in modules/_lib/terranix-stacks.nix has no renderer).
          # No credentials: a render is pure Nix. HERMETIC: `--skip-check-update` makes
          # trivy fall back to the checks bundle compiled into the binary (its log says
          # "Falling back to embedded checks" at ERROR level — expected, not a failure), so
          # the rules are whatever 0.76.0 shipped and move only with a nixpkgs bump.
          #
          # Triage of 2026-11-14: 4 findings, all in gcp-foundation, accepted or marked
          # false-positive in the repo-root .trivyignore.yaml, each scoped to the stack it
          # was triaged on. cf-mcp-portals renders with none.
          #
          # THE BLIND SPOT, measured 2026-11-14 and the reason this is not the MCP portal's
          # posture check: trivy reads NO NESTED BLOCK from Terraform JSON. A world-open
          # firewall (`allow` block) gave 0 findings as tf.json and 3 as the same HCL; a
          # bucket with `versioning.enabled = true` still fired "versioning disabled". It
          # reads top-level attributes correctly (an `allUsers` member, a bucket without
          # uniform access). So: false NEGATIVES on anything nested, false POSITIVES on
          # nested-block checks. The portal's server list, DCR callbacks and OAuth scopes
          # live in nested and string values, so `mcp-portal-posture` asserts them in Nix. Rejected alternatives: checkov 3.3.26 (its closure pulls
          # python3.14-ecdsa, marked INSECURE in the pin — a scanner that needs an
          # insecure-package exemption), json2hcl 0.2.0 (emits HCL1 `"allow" = { }`, an
          # attribute, not a block — JSON alone cannot say which is which without the
          # provider schema), and trivy's plan-JSON scanner (a plan needs credentials).
          #
          # THE SCANNER MUST STILL SEE: a canary stack with a public bucket (`allUsers`)
          # is scanned with no ignore file and must report GCP-0001, and every stack must
          # appear as a scanned target. Without both, an emptied bundle or a skipped
          # directory reads as clean.
          #
          # NEGATIVE CONTROL (2026-11-14): adding a bucket IAM member `allUsers` on the
          # state bucket in infra/gcp/foundation.nix turned this check RED (GCP-0001);
          # reverted.
          trivy-terranix =
            let
              renders = config.flake.lib.terranixStackRenders pkgs.stdenv.hostPlatform.system;
              canary = pkgs.writeText "canary.tf.json" (
                # The member must REFERENCE a declared bucket, as the real stacks do:
                # with a bare bucket name trivy links it to nothing and reports nothing.
                builtins.toJSON {
                  resource.google_storage_bucket.canary = {
                    name = "canary";
                    location = "US";
                    uniform_bucket_level_access = true;
                    public_access_prevention = "enforced";
                  };
                  resource.google_storage_bucket_iam_member.canary = {
                    bucket = "\${google_storage_bucket.canary.name}";
                    role = "roles/storage.objectViewer";
                    member = "allUsers";
                  };
                }
              );
            in
            pkgs.runCommand "trivy-terranix"
              {
                nativeBuildInputs = [
                  pkgs.trivy
                  pkgs.jq
                ];
                ignorefile = ../../.trivyignore.yaml;
              }
              ''
                export HOME="$TMPDIR"
                flags="config --quiet --skip-check-update --skip-version-check --disable-telemetry --cache-dir $TMPDIR/cache"
                ${lib.concatStringsSep "\n" (
                  lib.mapAttrsToList (n: r: ''
                    mkdir -p stacks/${n} && cp ${r} stacks/${n}/config.tf.json
                  '') renders
                )}
                mkdir canary && cp ${canary} canary/config.tf.json

                # shellcheck disable=SC2086 # $flags is a deliberate word list
                trivy $flags --ignorefile "" --format json canary > canary.json || true
                if ! jq -e '[.Results[]?.Misconfigurations[]?.ID] | index("GCP-0001")' canary.json > /dev/null; then
                  echo "trivy-terranix: the canary's allUsers bucket member was NOT reported (GCP-0001)." >&2
                  echo "The scanner sees nothing, so a clean result below would mean nothing." >&2
                  exit 1
                fi

                status=0
                # shellcheck disable=SC2086
                trivy $flags --ignorefile "$ignorefile" --exit-code 1 --format json stacks > report.json || status=$?
                for n in ${lib.concatStringsSep " " (lib.attrNames renders)}; do
                  if ! jq -e --arg t "$n" '[.Results[]?.Target] | index($t)' report.json > /dev/null; then
                    echo "trivy-terranix: stack $n was not scanned." >&2
                    exit 1
                  fi
                done
                if [ "$status" -ne 0 ]; then
                  # shellcheck disable=SC2086
                  trivy $flags --ignorefile "$ignorefile" stacks >&2 || true
                  echo "" >&2
                  echo "trivy-terranix: fix the stack, or add a SCOPED entry (id + paths) to the" >&2
                  echo "repo-root .trivyignore.yaml with a statement saying why. Read its header" >&2
                  echo "first: trivy cannot read nested blocks from tf.json, so some findings are" >&2
                  echo "false positives, and say so." >&2
                  exit 1
                fi
                echo "trivy-terranix: ${toString (lib.length (lib.attrNames renders))} stacks clean (canary seen)" > "$out"
              '';

          # ---- documentation byte budgets -------------------------------------
          #
          # ONE check over a TABLE of (file, ceiling) pairs, NOT one runCommand
          # per document. "One source of truth; a second copy is a bug with a
          # delayed fuse" — a second near-identical check would drift from this
          # one the first time either message changed, and the thing being gated
          # (unbounded documentation growth) is identical for every row.
          #
          # STILL NAMED `claude-md-budget`, though it now gates thirteen files.
          # Checked before keeping it (2026-10-02): no workflow names it. The
          # one required status check is nix-ci.yml's `gate`, whose linux leg
          # enumerates `.#checks.<system>` from the FLAKE rather than listing
          # attrs, so a rename would not break branch protection — but
          # docs/monoflake-capsule-adr.md records this decision under this exact
          # name, so renaming costs an ADR edit and buys nothing.
          #
          # CEILINGS are round numbers ~25-80% above today's bytes, widest on the
          # smallest files (where a few paragraphs are a large fraction). The gate
          # exists to stop UNBOUNDED growth, not to make an ordinary edit hostile:
          # if a row is genuinely full, SPLIT the document the way repo-map.md was
          # split, rather than raising the number reflexively.
          #
          # NO `self`: every row is a path LITERAL, so the derivation is
          # content-addressed per file (it is still listed in scripts/drv-snapshot.sh's
          # EXCLUDE_RE, like the two `self`-taking docs checks above).
          #
          # COVERAGE IS ASSERTED IN BOTH DIRECTIONS, because a budget gate that
          # silently ignores a new file is worse than no gate — the lesson
          # capsule-registry was built on. A docs/map/*.md the table does not name
          # fails this check, and so does a row naming a file that is gone.
          claude-md-budget =
            let
              budgets = {
                "CLAUDE.md" = {
                  path = ../../CLAUDE.md;
                  limit = 40000;
                };
                "docs/repo-map.md" = {
                  path = ../../docs/repo-map.md;
                  limit = 12000;
                };
                "docs/map/ci.md" = {
                  path = ../../docs/map/ci.md;
                  limit = 12000;
                };
                "docs/map/claude-code.md" = {
                  path = ../../docs/map/claude-code.md;
                  limit = 40000;
                };
                "docs/map/docs-index.md" = {
                  path = ../../docs/map/docs-index.md;
                  limit = 24000;
                };
                "docs/map/engine.md" = {
                  path = ../../docs/map/engine.md;
                  limit = 40000;
                };
                "docs/map/entry-points.md" = {
                  path = ../../docs/map/entry-points.md;
                  limit = 32000;
                };
                "docs/map/hosts.md" = {
                  path = ../../docs/map/hosts.md;
                  limit = 28000;
                };
                "docs/map/infra.md" = {
                  path = ../../docs/map/infra.md;
                  limit = 24000;
                };
                "docs/map/modules-darwin.md" = {
                  path = ../../docs/map/modules-darwin.md;
                  limit = 36000;
                };
                "docs/map/modules-home.md" = {
                  path = ../../docs/map/modules-home.md;
                  limit = 88000;
                };
                "docs/map/modules-nixos.md" = {
                  path = ../../docs/map/modules-nixos.md;
                  limit = 36000;
                };
                "docs/map/packages.md" = {
                  path = ../../docs/map/packages.md;
                  limit = 36000;
                };
              };
              # What is ON DISK under docs/map/, read at eval time from the git
              # tree — the other half of the coverage claim.
              onDisk = lib.naturalSort (
                lib.attrNames (
                  lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir ../../docs/map)
                )
              );
              gated = lib.naturalSort (
                map (lib.removePrefix "docs/map/") (lib.filter (lib.hasPrefix "docs/map/") (lib.attrNames budgets))
              );
            in
            pkgs.runCommand "claude-md-budget"
              {
                table = lib.concatStringsSep "\n" (
                  lib.mapAttrsToList (name: b: "${name} ${toString b.limit} ${b.path}") budgets
                );
                onDiskList = lib.concatStringsSep "\n" onDisk;
                gatedList = lib.concatStringsSep "\n" gated;
              }
              ''
                fail=0

                # ---- coverage: docs/map/ on disk == docs/map/ rows in the table ----
                printf '%s\n' "$onDiskList" | sort > "$TMPDIR/on-disk"
                printf '%s\n' "$gatedList" | sort > "$TMPDIR/gated"

                ungated=$(comm -23 "$TMPDIR/on-disk" "$TMPDIR/gated")
                if [ -n "$ungated" ]; then
                  echo "claude-md-budget: docs/map/ file(s) with NO byte ceiling:" >&2
                  printf '%s\n' "$ungated" | sed 's|^|  docs/map/|' >&2
                  echo "" >&2
                  echo "A budget gate that silently ignores a new file is worse than no gate." >&2
                  echo "Add a row for each one to \`budgets\` in modules/parts/checks.nix, and" >&2
                  echo "a routing line to docs/repo-map.md's \`## Contents\` table." >&2
                  fail=1
                fi

                orphaned=$(comm -13 "$TMPDIR/on-disk" "$TMPDIR/gated")
                if [ -n "$orphaned" ]; then
                  echo "claude-md-budget: budget row(s) for docs/map/ file(s) that do not exist:" >&2
                  printf '%s\n' "$orphaned" | sed 's|^|  docs/map/|' >&2
                  echo "" >&2
                  echo "A dead row gates nothing and reads as coverage. Delete it, or restore" >&2
                  echo "the file it names." >&2
                  fail=1
                fi

                # ---- the ceilings themselves --------------------------------------
                printf '%s\n' "$table" > "$TMPDIR/table"
                while read -r name limit store; do
                  [ -n "$name" ] || continue
                  size=$(wc -c < "$store" | tr -d " ")
                  if [ "$size" -gt "$limit" ]; then
                    echo "claude-md-budget: $name is $size BYTES, over its $limit-byte budget." >&2
                    echo "" >&2
                    echo "CLAUDE.md is an INDEX and so is docs/repo-map.md; the per-path detail" >&2
                    echo "lives in docs/map/<domain>.md. If a domain file is genuinely full," >&2
                    echo "SPLIT it (add the new file to \`budgets\` and to repo-map.md's Contents)" >&2
                    echo "rather than raising this limit reflexively." >&2
                    fail=1
                  else
                    echo "$name: $size/$limit bytes"
                  fi
                done < "$TMPDIR/table"

                [ "$fail" -eq 0 ] || exit 1
                echo "doc budgets: ${toString (lib.length (lib.attrNames budgets))} files within budget, all ${toString (lib.length onDisk)} docs/map/ files gated" > "$out"
              '';

          # ---- every declared launchd log reaches exactly one rotator -------
          #
          # modules/darwin/logging.nix splits every log path into two buckets —
          # newsyslog rename+create for the jobs that re-exec, logrotate
          # --copytruncate for the long-lived ones — and the whole claim of that
          # module is that NOTHING falls between them. That claim is worth a gate,
          # because the failure is silent: a new KeepAlive agent simply grows an
          # unbounded log and no build ever goes red.
          #
          # This does NOT read the module's own inputs back at it. It re-walks the
          # four composed sources from ../darwin/launchd-sources.nix — which is
          # where the enumeration, and why each of the four is in it, now live —
          # and collects every StandardOutPath/StandardErrorPath, then asserts that
          # set is exactly the union of what the module says it covers, and that
          # the two buckets do not overlap, since rename+create racing
          # copytruncate on one path is a corruption, not a redundancy.
          #
          # COVERED IS NOT ENOUGH — the covering tick must also be able to WRITE
          # the file. Long-lived-wins precedence is global, so a path could leave
          # the newsyslog set because a user agent classified it long-lived while
          # a root daemon owns it; a login-user logrotate then gets EPERM and the
          # set-equality assertions above would still pass. The tier assertions
          # re-derive the daemon-declared paths here and demand that none of them
          # sit in the user tick's set.
          launchd-log-rotation =
            let
              mac = config.flake.darwinConfigurations.macos.config;
              rot = mac.local.launchdLogRotation;
              pathsIn =
                attrs: key:
                lib.unique (
                  lib.concatMap (
                    unit:
                    let
                      c = unit.${key} or { };
                    in
                    lib.filter (x: x != null && x != "") [
                      (c.StandardOutPath or null)
                      (c.StandardErrorPath or null)
                    ]
                  ) (lib.attrValues attrs)
                );
              # ../darwin/launchd-sources.nix is the ONE enumeration of the four
              # sources — the same list modules/darwin/launchd-reconcile.nix
              # selects its scope from. Typed here as well, the two copies drift
              # with nothing to notice: both consumers fail by DOING NOTHING, so a
              # dropped source stays green on both sides.
              sources = import ../darwin/launchd-sources.nix {
                config = mac;
                inherit loginName;
              };
              # THE ROSTER ITSELF — because deduping removed the drift that used to
              # prove it. Until modules/darwin/logging.nix was wired to that same
              # file it carried a THIRD copy of the four sources, so dropping one
              # made the module and this check disagree and `phantom` went red. With
              # ONE enumeration and three readers a dropped source shrinks BOTH sides
              # equally: measured on exactly that edit (remove the home-manager
              # source, rebuild this check) the result was exit 0 — green over three
              # sources. One source of truth is the right shape, but it moves the
              # dropped-source failure from "detected by disagreement" to "not
              # detected at all" unless the roster is asserted directly.
              #
              # NAMES ONLY, deliberately. The `units`/`key`/`domain` MAPPING is not
              # restated here: that mapping is the part that drifts silently, which
              # is the whole reason it lives in one file. A name roster cannot drift
              # quietly — it is either right or red — the same distinction
              # capsule-registry and docs-indexed draw between a tripwire and a
              # second copy. Adding a fifth source is a deliberate act and must
              # update this list; that friction is the point.
              expectedSources = [
                "home-manager launchd.agents"
                "nix-darwin launchd.agents"
                "nix-darwin launchd.daemons"
                "nix-darwin launchd.user.agents"
              ];
              actualSources = lib.naturalSort (map (src: src.name) sources);
              declared = lib.unique (lib.concatMap (src: pathsIn src.units src.key) sources);
              covered = lib.unique (rot.reExecPaths ++ rot.longLivedPaths);
              uncovered = lib.subtractLists covered declared;
              phantom = lib.subtractLists declared covered;
              overlap = lib.intersectLists rot.reExecPaths rot.longLivedPaths;
              # Tier, re-derived here rather than taken from the module.
              # Derived from the same list rather than naming `launchd.daemons`
              # again — the root tier IS the system-domain source.
              daemonDeclared = lib.unique (
                lib.concatMap (src: pathsIn src.units src.key) (lib.filter (src: src.domain == "system") sources)
              );
              rootInUserTick = lib.intersectLists rot.userLongLivedPaths daemonDeclared;
              tickSets = lib.unique (rot.userLongLivedPaths ++ rot.daemonLongLivedPaths);
              unticked = lib.subtractLists tickSets rot.longLivedPaths;
              stray = lib.subtractLists rot.longLivedPaths tickSets;
            in
            mkHostContract {
              inherit pkgs;
              name = "launchd-log-rotation";
              subject = "macos: every declared launchd log has exactly one rotator";
              expect = [
                {
                  name = "all four launchd option surfaces are still enumerated (found: ${toString actualSources})";
                  ok = actualSources == expectedSources;
                }
                {
                  name = "no declared log path is unrotated (missing: ${toString uncovered})";
                  ok = uncovered == [ ];
                }
                {
                  name = "no rotated path is undeclared (stale: ${toString phantom})";
                  ok = phantom == [ ];
                }
                {
                  name = "newsyslog and logrotate sets are disjoint (both: ${toString overlap})";
                  ok = overlap == [ ];
                }
                {
                  name = "the long-lived set is non-empty — an empty one means the classifier broke";
                  ok = rot.longLivedPaths != [ ];
                }
                {
                  name = "every long-lived path is in exactly one tick (unticked: ${toString unticked}, stray: ${toString stray})";
                  ok = unticked == [ ] && stray == [ ];
                }
                {
                  name = "no root-owned log is handed to the login-user tick (EPERM: ${toString rootInUserTick})";
                  ok = rootInUserTick == [ ];
                }
              ];
              advice = [
                "modules/darwin/logging.nix derives both sets from the KeepAlive shape of"
                "every composed agent and daemon; a path in neither bucket means a source"
                "was dropped, not that the agent needs no rotation. A path in BOTH means the"
                "long-lived-wins precedence (lib.subtractLists) was bypassed — newsyslog's"
                "rename+create racing logrotate's copytruncate on one file loses data."
                "A path in the user tick that a daemon also declares means the tier rule"
                "(any daemon declaration -> root tick) was bypassed: the login user cannot"
                "truncate root's file, so the path would be covered and still never shrink."
                "A changed ROSTER means a source left modules/darwin/launchd-sources.nix."
                "Every other leg here shrinks with it and stays green, so this one is the"
                "only signal: restore the source, or update the list if the surface is"
                "genuinely gone from the pinned nix-darwin / home-manager modules."
              ];
            };

          # ---- the gui user agents stay in the SELF-HEALING lane -------------
          #
          # modules/darwin/launchd-sources.nix is the one enumeration of the four
          # launchd option surfaces, and it records `selfHeals` per source. A
          # `selfHeals = false; domain = "gui"` unit is covered by NEITHER repair
          # mechanism — nix-darwin's activation is diff-gated in both its lanes,
          # and launchd-reconcile.nix runs as root with no `gui/<uid>` to reach —
          # so a unit macOS has dropped simply stays down until a human notices.
          # Five units sat there and ALL FIVE moved to home-manager's
          # `launchd.agents` on 2026-10-02 — three into
          # modules/home/macos-user-agents.nix (the Maccy opener among them,
          # retired 2026-10-27), then the two tart-vms CI runners
          # — so the stranded row is now EMPTY, which is what the first leg
          # below asserts. Upstream owns the `launchctl print` probe. This gate
          # is what stops them coming back, and the per-unit legs are keyed on
          # the LABEL for two reasons.
          #
          # THE LABEL IS THE UNIT'S ON-DISK IDENTITY, and the operator's
          # "Allow in the Background" approval in Background Task Management is
          # keyed to it. The literals below are therefore the artifact, not
          # a restatement of the module: home-manager's default Label would be
          # `org.nix-community.home.<attr>`, so the module must OVERRIDE it, and
          # a check that re-derived the override from the module could not tell a
          # preserved Label from a renamed one. (`launchd-log-rotation` above
          # draws the same tripwire-not-second-copy line for its source roster.)
          #
          # THE LABEL IS ALSO WHAT THE PROBE USES, which is why the override is
          # safe at all: pinned home-manager modules/launchd/default.nix:165
          # names each plist `"${v.config.Label}.plist"` and the activation script's
          # `agentName` local reads it straight back out of that filename, so the probe asks
          # `launchctl print gui/<uid>/<Label>` — the real unit.
          #
          # `enable` IS ITS OWN LEG, and it is not redundant with the lane leg.
          # It is a `mkEnableOption` defaulting to FALSE (:20) and `agentPlists`
          # filters on it (:166), while `launchd.agents` — the attrset
          # launchd-sources.nix walks — does not. nix-darwin's
          # `launchd.user.agents` has no such switch, so a lane change that
          # forgets it evaluates clean, renders NO plist, and would leave every
          # label-and-lane assertion here GREEN. Measured on this migration: the
          # first build of the three agents produced zero plists.
          #
          # arg0 is the last leg: `waitForNixStore = false` plus
          # `launcher.name = "nix-<attr>"` is what makes the binary launchd execs
          # a store-resident `nix-*` script rather than Apple's `/bin/sh`, and
          # that attribution is what grants these two sweeps READ access to the
          # TCC-protected ~/Desktop and ~/Downloads at all
          # (.claude/rules/launchd-naming.md § TCC). For the two CI runners the
          # same pair preserves the arg0 BASENAME across the lane change —
          # `nix-gitlab-runner` and `nix-tart-runner-dontsell-vm` are what BTM
          # listed before it, and those names come from `launcher.name`, not from
          # the inner script (which is deliberately named differently, so one
          # name does not end up on two store paths). The macos-user-agents
          # defaults come from modules/home/launchd-launcher.nix as `mkDefault`s,
          # i.e. a single agent can still silently opt out of both; the capsule
          # sets its own explicitly, because a capsule may not assume its
          # consumer loads this fleet's home profile.
          launchd-selfheal-lane =
            let
              mac = config.flake.darwinConfigurations.macos.config;
              hm = mac.home-manager.users.${loginName};
              sources = import ../darwin/launchd-sources.nix {
                config = mac;
                inherit loginName;
              };
              labelsOf = src: map (unit: unit.${src.key}.Label) (lib.attrValues src.units);
              healing = lib.concatMap labelsOf (lib.filter (src: src.selfHeals) sources);
              stranded = lib.concatMap labelsOf (lib.filter (src: !src.selfHeals) sources);
              # The tart-vms CI lanes, moved 2026-10-02 — the LAST units on the
              # stranded row. Both are declared from a nix-darwin module
              # (modules/features/tart-vms/{github,gitlab}-runner.nix write
              # `home-manager.users.<primaryUser>.launchd.agents`, the shape
              # modules/darwin/logging.nix's `file-rotation-logs` established) because their plists
              # derive from nix-darwin options — `local.tart.runnerStateDir`
              # defaults off `config.system.primaryUserHome`. Lane, not layer:
              # what self-heals is the option surface, not which file writes it.
              #
              # DERIVED, unlike the literals below, and that is the distinction
              # worth keeping. Their Labels are not hand-picked strings: each is
              # nix-darwin's own former default for the attribute name
              # (`launchd.labelPrefix` + "." + attr, the `serviceConfig.Label`
              # mkDefault in pinned modules/launchd/default.nix), which is precisely what sits on
              # disk and holds the BTM approval. So the invariant is the
              # FORMULA, and a literal list here would hardcode a consumer's
              # per-instance runner names into the fleet's checks as well.
              # It still is not a tautology: it fails if a lane drops its
              # explicit Label (home-manager would silently name the unit
              # `org.nix-community.home.<attr>`) or forgets `enable`.
              tartLanes =
                lib.optional mac.local.tart.gitlabRunner.enable "gitlab-runner"
                ++ map (n: "tart-runner-${n}") (
                  lib.attrNames (lib.filterAttrs (_: r: r.enable) mac.local.tart.githubRunners)
                );
              # attribute name -> the Label it MUST keep carrying.
              units = {
                file-rotation-desktop = "com.kattakath.file-rotation.trash-desktop";
                file-rotation-downloads = "com.kattakath.file-rotation.trash-downloads";
              }
              // lib.listToAttrs (map (n: lib.nameValuePair n "org.nixos.${n}") tartLanes);
              attrs = lib.attrNames units;
              required = lib.attrValues units;
              missing = lib.subtractLists healing required;
              regressed = lib.intersectLists stranded required;
              # `?` first, so a renamed attribute fails this leg instead of
              # throwing out of the legs below it.
              absent = lib.filter (n: !(hm.launchd.agents ? ${n} && hm.launchd.agents.${n}.enable)) attrs;
              present = lib.filter (n: hm.launchd.agents ? ${n}) attrs;
              mislabelled = lib.filter (n: hm.launchd.agents.${n}.config.Label != units.${n}) present;
              waiting = lib.filter (n: hm.launchd.agents.${n}.waitForNixStore) present;
              badLauncher = lib.filter (n: hm.launchd.agents.${n}.launcher.name != "nix-${n}") present;
              # THE LANE ITSELF, not a roster. Every leg above names a unit, so
              # all of them stay green for a NEW unit declared on the stranded
              # row — which is how five of them accumulated there in the first
              # place. As of 2026-10-02 nix-darwin's `launchd.user.agents` is
              # EMPTY on macos, so the strongest available assertion is
              # emptiness, and it needs no maintenance.
              strandedGui = lib.attrNames mac.launchd.user.agents;
              # Maccy starts through its OWN launch-at-login (one BTM item) since
              # 2026-10-27. A nix opener next to it is the two-launcher race of
              # 2026-09-23 (dead menu-bar icon), so its return is a red leg.
              maccyOpener = hm.launchd.agents ? open-maccy;
            in
            mkHostContract {
              inherit pkgs;
              name = "launchd-selfheal-lane";
              subject = "macos: every gui user agent is in the self-healing launchd lane (${toString (lib.length (lib.attrNames units))} units)";
              expect = [
                {
                  name = "nix-darwin's diff-gated gui lane is empty (stranded: ${toString strandedGui})";
                  ok = strandedGui == [ ];
                }
                {
                  name = "every unit is declared AND enabled in home-manager's launchd.agents (absent or disabled: ${toString absent})";
                  ok = absent == [ ];
                }
                {
                  name = "every Label is carried by a selfHeals source (missing: ${toString missing})";
                  ok = missing == [ ];
                }
                {
                  name = "no Label is carried by a source that repairs nothing (regressed: ${toString regressed})";
                  ok = regressed == [ ];
                }
                {
                  name = "every Label is pinned to its on-disk value (renamed: ${toString mislabelled})";
                  ok = mislabelled == [ ];
                }
                {
                  name = "no unit took upstream's /bin/sh wait4path arg0 (waitForNixStore: ${toString waiting})";
                  ok = waiting == [ ];
                }
                {
                  name = "every launcher is still named nix-<attr> (wrong: ${toString badLauncher})";
                  ok = badLauncher == [ ];
                }
                {
                  name = "no nix login opener for Maccy (the app's own launch-at-login is the one launcher)";
                  ok = !maccyOpener;
                }
              ];
              # NO BACKTICKS IN THESE LINES. mkHostContract emits each one inside
              # a double-quoted echo, so a backtick is command substitution: the
              # first red run of this check printed "launchd.user.agents: command
              # not found" in place of half its advice.
              advice = [
                "All five were nix-darwin launchd.user.agents until 2026-10-02 and moved"
                "to home-manager launchd.agents for its launchctl-print self-heal: three"
                "in modules/home/macos-user-agents.nix (the Maccy opener among them, retired"
                "2026-10-27 for Maccy's own launch-at-login), and the two CI runners in"
                "modules/features/tart-vms/. Moving one back puts it on the selfHeals ="
                "false, domain = gui row of modules/darwin/launchd-sources.nix, which no"
                "mechanism repairs: the unit stays down silently after macOS drops it."
                "The emptiness leg is the one that catches a BRAND NEW unit declared"
                "there, which every per-unit leg below it would miss."
                "A RENAMED or DEFAULTED Label is a different launchd unit, so it loses the"
                "operator's Background Task Management approval and reappears unapproved."
                "A unit declared without enable = true renders no plist at all — the"
                "agent is simply gone, with no eval error anywhere."
                "A waitForNixStore = true, or a renamed launcher, makes launchd exec"
                "Apple's /bin/sh, which TCC refuses on ~/Desktop and ~/Downloads: the two"
                "sweeps would run, log nothing useful, and quietly do no work. For the two"
                "CI runners the same change costs BTM legibility instead - the operator"
                "sees a phantom sh where nix-gitlab-runner used to be."
                "A nix opener for Maccy (open-maccy) races the app's own launch-at-login:"
                "two launchers left a dead menu-bar icon on 2026-09-23. Use the app toggle."
              ];
            };

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

          # ---- the launcher<->plugin CONTRACT, across the repo boundary ---------
          #
          # MCP servers in this fleet are declared in TWO repos BY DESIGN, and the
          # split is right: Nix builds the launcher BINARIES (`local.pluginMcp`,
          # packages/keychain-mcp.nix -> `nix-mcp-*` on PATH) because they read the
          # login Keychain, and a `github:kattakath/skills` plugin declares the server
          # because only a plugin can. Since skills #162 the plugin's `.mcp.json` names
          # NO binary: its server runs the plugin's own `scripts/launch.sh`, handed
          # `${user_config.launcher}`, and modules/home/plugin-mcp.nix seeds that
          # `launcher` setting (`pluginConfigs."<plugin>@kattakath"`) with `nix-mcp-<name>`.
          #
          # So the contract is THREE links in three places, and each one broken means a
          # server that silently never starts. For every server macos declares:
          #   (a) the plugin seeded with its launcher exists in the PINNED skills tree;
          #   (b) that plugin's `plugin.json` declares a `launcher` userConfig key, and
          #       its `.mcp.json` passes `${user_config.launcher}` to some server
          #       (command, args or env — the pinned rag/wordpress pass it in env);
          #   (c) exactly one kattakath plugin is seeded with `nix-mcp-<name>`, and that
          #       binary is in the composed home.packages.
          # Read at EVAL time — `builtins.readFile` over a realised flake input, so no
          # import-from-derivation and no network.
          #
          # The previous version joined the seeded launchers against the built ones.
          # Both came from `local.pluginMcp.servers`, so it compared Nix with itself and
          # could not go red; it never opened the plugin a launcher was seeded into.
          #
          # THE COST, stated rather than discovered: `kattakath-skills` is load-bearing
          # here, so renaming a plugin or its `launcher` key over there turns this check
          # RED at the next pin bump (the old pin stays green). A server added over there
          # is not read at all — only the servers macos declares are. Bounded and automatic —
          # .github/workflows/update-flake-lock.yml bumps it weekly (its
          # `updatable-inputs` step names the inputs it skips) and arms
          # auto-merge on the result — so the check is re-run on a reviewable PR
          # rather than never. A red leg there means a plugin is ALREADY broken on
          # this Mac (the marketplace tracks HEAD, not this pin); the stuck lockfile
          # is the symptom, not the fault.
          mcp-launcher-parity =
            let
              hm = config.flake.darwinConfigurations.macos.config.home-manager.users.${loginName};
              servers = hm.local.pluginMcp.servers;

              # BUILT, read off the COMPOSED package list. Derivation name == binary
              # name for the one builder, a `writeShellApplication`
              # (packages/keychain-mcp.nix) emitting exactly one `$out/bin/<name>`.
              built = map (p: p.name or "") hm.home.packages;

              seeded = hm.programs.claude-code.settings.pluginConfigs or { };
              placeholder = "\${user_config.launcher}";

              legsFor =
                name:
                let
                  launcher = "nix-mcp-${name}";
                  ids = lib.attrNames (
                    lib.filterAttrs (
                      id: c: lib.hasSuffix "@kattakath" id && (c.options.launcher or null) == launcher
                    ) seeded
                  );
                  plugin = if ids == [ ] then "<none>" else lib.removeSuffix "@kattakath" (builtins.head ids);
                  dir = "${inputs.kattakath-skills}/plugins/${plugin}";
                  readJson = f: if builtins.pathExists f then builtins.fromJSON (builtins.readFile f) else { };
                  manifest = readJson "${dir}/.claude-plugin/plugin.json";
                  mcp = readJson "${dir}/.mcp.json";
                  passesLauncher =
                    s:
                    builtins.elem placeholder (
                      [ (s.command or "") ] ++ (s.args or [ ]) ++ lib.attrValues (s.env or { })
                    );
                in
                [
                  {
                    name = "${name}: exactly one kattakath plugin is seeded with launcher ${launcher} (seeded: ${toString ids})";
                    ok = builtins.length ids == 1;
                  }
                  {
                    name = "${name}: ${launcher} is built into macos home.packages";
                    ok = builtins.elem launcher built;
                  }
                  {
                    name = "${name}: plugin '${plugin}' exists in the pinned kattakath-skills tree";
                    ok = builtins.pathExists dir;
                  }
                  {
                    # No backticks or `${...}` in these names: mkHostContract echoes
                    # them inside double quotes, where the shell would expand both.
                    name = "${name}: plugin '${plugin}' declares a launcher userConfig key";
                    ok = manifest ? userConfig.launcher;
                  }
                  {
                    name = "${name}: plugin '${plugin}' .mcp.json passes the user_config.launcher placeholder to a server";
                    ok = lib.any passesLauncher (lib.attrValues (mcp.mcpServers or { }));
                  }
                ];
            in
            mkHostContract {
              inherit pkgs;
              name = "mcp-launcher-parity";
              subject = "macos: every nix-mcp-* launcher is seeded into a pinned kattakath plugin that runs it";
              expect = [
                {
                  name = "macos declares at least one local.pluginMcp.servers entry (an empty list tests nothing)";
                  ok = servers != [ ];
                }
              ]
              ++ lib.concatMap legsFor servers;
              advice = [
                "Each server in local.pluginMcp.servers (hosts/macos.nix) reaches Claude Code"
                "only through a github:kattakath/skills plugin: plugin-mcp.nix seeds that"
                "plugin's launcher setting with nix-mcp-NAME, and the plugin's .mcp.json"
                "hands it to scripts/launch.sh. A red seeded/built leg is in plugin-mcp.nix"
                "(the server's plugin field). A red exists/userConfig/.mcp.json leg means"
                "the pinned skills tree renamed the plugin or its launcher key: fix the"
                "plugin field, or the plugin, then bump the kattakath-skills pin."
              ];
            };

          # The Workspace MCP portal's tool allowlist has ONE owner, workspace-mcp-apps.nix.
          # The kattakath-workspace plugin ships a GENERATED copy
          # (skills/kattakath-workspace/references/allowlist.json, written by the plugin's
          # scripts/gen-allowlist.sh) that its router, its /status skill and its write guard's
          # tests read. Two copies drift silently, so this compares them, plus the one name
          # the two repos must spell identically: the plugin's .mcp.json server key, which
          # the user-scope deniedMcpServers entry plugin:kattakath-workspace:<key> must match
          # or the plugin's copy of the connector stops being denied and a second sign-in
          # appears.
          #   (a) mapAttrs (_: a: a.tools) of the apps file == the PINNED copy's `apps`;
          #   (b) the pinned .mcp.json has exactly one server, and macos denies exactly it.
          # Same cost as mcp-launcher-parity: a change over there turns this RED at the next
          # pin bump. Land an allowlist change as ONE commit here: the apps edit plus
          # `nix flake update kattakath-skills` (after the regenerated copy is pushed there).
          workspace-plugin-parity =
            let
              hm = config.flake.darwinConfigurations.macos.config.home-manager.users.${loginName};
              expected =
                builtins.mapAttrs (_: a: a.tools)
                  (import ../../infra/cloudflare/workspace-mcp-apps.nix).apps;
              dir = "${inputs.kattakath-skills}/plugins/kattakath-workspace";
              allowFile = "${dir}/skills/kattakath-workspace/references/allowlist.json";
              mcpFile = "${dir}/.mcp.json";
              readJson = f: if builtins.pathExists f then builtins.fromJSON (builtins.readFile f) else { };
              pinned = (readJson allowFile).apps or null;
              keys = lib.attrNames ((readJson mcpFile).mcpServers or { });
              prefix = "plugin:kattakath-workspace:";
              denied = lib.filter (lib.hasPrefix prefix) (
                map (d: d.serverName or "") (hm.programs.claude-code.settings.deniedMcpServers or [ ])
              );
              appDiff =
                let
                  apps = lib.unique (
                    lib.attrNames expected ++ lib.attrNames (if pinned == null then { } else pinned)
                  );
                in
                lib.filter (
                  a: (expected.${a} or null) != ((if pinned == null then { } else pinned).${a} or null)
                ) apps;
            in
            mkHostContract {
              inherit pkgs;
              name = "workspace-plugin-parity";
              subject = "the pinned kattakath-workspace plugin matches workspace-mcp-apps.nix and the connector deny";
              expect = [
                {
                  name = "the pinned plugin ships references/allowlist.json with an apps attribute";
                  ok = pinned != null;
                }
                {
                  name = "allowlist.json apps equal workspace-mcp-apps.nix (apps that differ: ${toString appDiff})";
                  ok = pinned != null && appDiff == [ ];
                }
                {
                  name = "the pinned .mcp.json declares exactly one server (found: ${toString keys})";
                  ok = builtins.length keys == 1;
                }
                {
                  name = "macos denies exactly that server as plugin:kattakath-workspace:KEY (denied: ${toString denied})";
                  ok = builtins.length keys == 1 && denied == [ "${prefix}${builtins.head keys}" ];
                }
              ];
              advice = [
                "allowlist.json is generated: run the plugin's scripts/gen-allowlist.sh against"
                "this checkout, push kattakath/skills, then in ONE commit here keep the apps edit"
                "and run nix flake update kattakath-skills. A red .mcp.json/deny leg means the"
                "plugin renamed its server key: change the deniedMcpServers entry in"
                "modules/home/default.nix to plugin:kattakath-workspace:NEW-KEY in the same commit."
              ];
            };
        };

      # The writer for every generated span `hosts-documented` checks (see `generatedBlocks`).
      # It splices the SAME render the check compares against, so the two cannot disagree.
      # ADR-014 § 4 E. Every commit SHA a markdown file cites must resolve in this repo's
      # history. NOT a flake check: a check builds from `self`, which has no .git. CI runs this
      # app in gitleaks.yml's full-history checkout; /hygiene runs it from the snapshot.
      #
      # VOID: SHAs the 2026-11-13 history rewrite destroyed that could not be remapped. GitHub
      # no longer serves them, or they were PR-branch commits a squash merge replaced. The 8
      # that could be remapped (same UTC author date AND subject) were rewritten in place.
      # This list only shrinks: a NEW dead SHA fails.
      apps.docs-shas-resolve =
        let
          void = [
            "095fef2f"
            "3e8100d5"
            "3f606dc"
            "78f956b3"
            "7b4c5ec4"
            "848a6c0e"
            "c013aa5"
            "d5bd9cd"
            "ef34387ddd751e1ab8857adf4676492d32eb24ec"
            "efb6d0d5"
            "ff0e21a4"
          ];
        in
        {
          type = "app";
          program = lib.getExe (
            pkgs.writeShellApplication {
              name = "docs-shas-resolve";
              runtimeInputs = [
                pkgs.git
                pkgs.gnugrep
                pkgs.coreutils
              ];
              text = ''
                cd "$(git rev-parse --show-toplevel)"
                if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
                  echo "docs-shas-resolve: shallow clone, cannot judge history (fetch-depth: 0)." >&2
                  exit 1
                fi
                void=" ${lib.concatStringsSep " " void} "
                # REACHABLE from a remote ref, not merely present: a local clone keeps
                # unreachable pre-rewrite objects, so `git cat-file -e` passed four dead SHAs
                # on the Mac that CI's fresh clone rejected (2026-11-25).
                tmpd=$(mktemp -d)
                trap 'rm -r "$tmpd"' EXIT
                git rev-list --remotes > "$tmpd/reachable.txt"
                if [ ! -s "$tmpd/reachable.txt" ]; then
                  echo "docs-shas-resolve: no remote refs to judge against (git fetch first)." >&2
                  exit 1
                fi
                seen=0
                dead=()
                # `abc1234` in backticks, or "commit(s) abc1234"; at least one digit AND one
                # letter, so a plain number or word is not a SHA.
                # shellcheck disable=SC2016  # the backticks are literal markdown, not expansions
                while IFS=: read -r file sha; do
                  case "$sha" in *[0-9]*) ;; *) continue ;; esac
                  case "$sha" in *[a-f]*) ;; *) continue ;; esac
                  seen=$((seen + 1))
                  case "$void" in *" $sha "*) continue ;; esac
                  grep -q "^$sha" "$tmpd/reachable.txt" || dead+=("$file: $sha")
                done < <(git ls-files -z '*.md' | grep -zv '^.claude/worktrees/' |
                  xargs -0 grep -o -H -E '`[0-9a-f]{7,40}`|commits? [0-9a-f]{7,40}\b' |
                  sed -E 's/^([^:]*):.*[` ]([0-9a-f]{7,40})`?$/\1:\2/' | sort -u)
                if [ "$seen" -eq 0 ]; then
                  echo "docs-shas-resolve: VACUOUS - no cited SHA found" >&2
                  exit 1
                fi
                if [ ''${#dead[@]} -gt 0 ]; then
                  echo "docs-shas-resolve: cited commit(s) that do not exist in this repo:" >&2
                  printf '  %s\n' "''${dead[@]}" >&2
                  echo "Cite the commit's subject or its PR number, or fix the SHA." >&2
                  exit 1
                fi
                echo "docs-shas-resolve: $seen cited SHAs, every live one resolves (${toString (lib.length void)} known void)"
              '';
            }
          );
          meta.description = "Check every commit SHA cited in markdown resolves (ADR-014; needs a full-history clone)";
        };

      apps.docs-generate = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = "docs-generate";
            runtimeInputs = [
              pkgs.git
              pkgs.gawk
              pkgs.coreutils
            ];
            text = ''
              root=$(git rev-parse --show-toplevel)
              while IFS=$'\t' read -r name rel _ render begin end; do
                doc="$root/$rel"
                if ! grep -qxF -- "$begin" "$doc" || ! grep -qxF -- "$end" "$doc"; then
                  echo "docs-generate: $rel has no BEGIN/END GENERATED: $name markers." >&2
                  exit 1
                fi
                tmp=$(mktemp "$doc.XXXXXX")
                awk -v b="$begin" -v e="$end" -v r="$render" '
                  $0 == b { while ((getline l < r) > 0) print l; skip = 1; next }
                  $0 == e { skip = 0; next }
                  !skip { print }
                ' "$doc" > "$tmp"
                mv "$tmp" "$doc"
                echo "docs-generate: rewrote the $name span in $rel" >&2
              done < ${generatedManifest pkgs}
              echo "  (the render comes from the flake as evaluated: git add a new .nix first)" >&2
            '';
          }
        );
        meta.description = "Rewrite every generated doc span (${lib.concatStringsSep ", " (lib.attrNames generatedBlocks)}) from the flake (checked by checks.<system>.hosts-documented)";
      };
    };
}
