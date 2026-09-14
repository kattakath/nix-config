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
  inherit (inputs) home-manager;
  inherit (config.fleet.identityArgs) loginName;
in
{
  perSystem =
    { pkgs, ... }:
    {
      checks =
        lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          # ---- The shell-init ORDERING contract, tested for the first time ----
          #
          # TWO modules write into the SAME three home-manager options, and the
          # whole correctness argument is which one lands first:
          #
          #   modules/features/keychain-secrets/module.nix  lib.mkAfter  (= 1500)
          #     exports every registered Keychain secret into the shell.
          #   modules/shared/claude-bedrock-gate.nix        lib.mkOrder 1600
          #     reads CLAUDE_CODE_USE_BEDROCK and unsets it when the private AWS
          #     layer is absent.
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
        }
        // {
          claude-md-budget = pkgs.runCommand "claude-md-budget" { } ''
            limit=40000
            size=$(wc -c < ${../../CLAUDE.md} | tr -d " ")
            if [ "$size" -gt "$limit" ]; then
              echo "claude-md-budget: CLAUDE.md is $size chars, over the $limit-char" >&2
              echo "context-lint budget it documents for itself." >&2
              echo "" >&2
              echo "CLAUDE.md is an INDEX. The full per-path detail belongs in" >&2
              echo "docs/repo-map.md — move a section there and leave the one-liner," >&2
              echo "rather than raising this limit reflexively." >&2
              exit 1
            fi
            echo "CLAUDE.md: $size/$limit chars"
            touch "$out"
          '';

          # The vendored launchd fork (modules/shared/hm-launchd/default.nix) copies
          # ONE upstream file; launchd.nix/types.nix are imported from the pinned
          # input itself. So drift is one hash: upstream's default.nix at the
          # revision the fork was last reviewed against. A mismatch prints the
          # fork-vs-upstream diff — port what applies, then re-pin `expected`.
          hm-launchd-drift = pkgs.runCommand "hm-launchd-drift" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
            upstream=${home-manager}/modules/launchd/default.nix
            expected=a16a4bf28ca400708261105816955e66184964485a6e5ac067cdea34491614c3
            actual=$(sha256sum "$upstream" | cut -d' ' -f1)
            if [ "$actual" != "$expected" ]; then
              echo "hm-launchd-drift: pinned home-manager modules/launchd/default.nix moved" >&2
              echo "(sha256 $actual, reviewed $expected). Re-review the vendored fork" >&2
              echo "(modules/shared/hm-launchd/default.nix) against this diff, port what" >&2
              echo "applies, then re-pin \`expected\` in modules/parts/checks.nix." >&2
              diff -u "$upstream" ${../shared/hm-launchd/default.nix} >&2 || true
              exit 1
            fi
            touch "$out"
          '';

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
