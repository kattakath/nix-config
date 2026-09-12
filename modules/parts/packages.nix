# ---- Packages + the `nix run` apps that expose them --------------------------
#
# The mechanical half of wave 2: the old `packages` was one
# `foldl' recursiveUpdate` over five different `genAttrs` folds, and `apps` was a
# `recursiveUpdate` of a hand-written aarch64-darwin block with a `forAllSystems`
# one. flake-parts' `perSystem` is that fold, so every `genAttrs darwinSystems`
# becomes an `optionalAttrs isDarwin` and the merge bookkeeping disappears.
#
# Nothing about WHAT is built changed: same callPackages, same arguments, same
# derivation names, same `meta.description` strings (they are what
# `nix flake show` prints).
#
# The terranix packages and their apps live in
# modules/parts/terranix.nix; the devcontainer image in
# modules/parts/devcontainer.nix — each next to the code that explains it.
{
  config,
  inputs,
  self,
  ...
}:
let
  inherit (inputs) agenix;

  inherit (config.fleet)
    darwinSystems
    orgName
    repoName
    flakeRef
    userEmail
    jsonResumeUrl
    logoUrl
    tokensUrl
    ;
in
{
  perSystem =
    {
      config,
      lib,
      pkgs,
      system,
      ...
    }:
    let
      isDarwin = lib.elem system darwinSystems;
    in
    {
      packages = {
        # `page-lab-pick` — the two-way element picker from the page-lab plugin, as a
        # CLI on a PINNED Node. Node 20 on this fleet has no global WebSocket, so the raw
        # CDP client would otherwise need --experimental-websocket; nodejs_22 removes the
        # flag from the fleet path. See packages/page-lab-pick.nix for why this exists at
        # all when `node <the script>` already works.
        # `superhook` / `superhook-digest` — the hook supervisor as CLIs, so
        # `.claude/settings.json` can name a bare command instead of a store path it
        # cannot hold. Scripts come from the same pinned marketplace input as the
        # plugins. See packages/superhook.nix for why this is not a plugin hook.
        inherit
          (pkgs.callPackage ../../packages/superhook.nix {
            superhookSrc = "${inputs.kattakath-claude-plugins}/plugins/superhook";
          })
          superhook
          superhook-digest
          ;

        page-lab-pick = pkgs.callPackage ../../packages/page-lab-pick.nix {
          # The plugin tree comes from the pinned input, not from this repo — see
          # flake.nix `kattakath-claude-plugins`.
          pageLabSrc = "${inputs.kattakath-claude-plugins}/plugins/page-lab";
        };
      }
      // lib.optionalAttrs (system == "aarch64-linux") {
        # The LIVE nixpi SD image (not a separate installer): prebuilt in CI
        # (build-installers), published to the installer-latest release, and
        # Cachix-warmed so `nixpi-flash` substitutes it instead of building.
        # Secret-free — token + Wi-Fi are planted post-flash on the FIRMWARE
        # partition, so this public artifact carries only the operator PUBLIC key.
        nixpi-sd-image = self.nixosConfigurations.nixpi.config.system.build.sdImage;
      }
      // lib.optionalAttrs isDarwin (
        let
          # Key-recovery kit (macOS only). Exposed as packages so `nix flake check`
          # BUILDS them — which is what runs writeShellApplication's shellcheck on
          # key-backup/key-recover and the explicit shellcheck on the no-Nix
          # bootstrap script. Before this, the recovery scripts lived as loose bash
          # in an iCloud folder that nothing linted and nothing evaluated.
          keyKit = pkgs.callPackage ../../packages/key-recovery.nix {
            # The PINNED agenix, not `nix run github:ryantm/agenix` at runtime:
            # a recovery must not depend on whatever agenix master is that day.
            agenix = agenix.packages.${system}.default;
            inherit orgName flakeRef userEmail;
          };

          # nixpi SD-card provisioning toolkit (macOS only). Exposed as packages so
          # `nix flake check` BUILDS them — running writeShellApplication's shellcheck
          # on each of the four apps. See packages/nixpi-provision.nix.
          nixpiKit = pkgs.callPackage ../../packages/nixpi-provision.nix {
            inherit orgName repoName;
          };
        in
        {
          inherit (keyKit) key-backup key-recover key-recovery-bootstrap;

          nixpi-wifi-creds = nixpiKit.wifi-creds;
          nixpi-provision = nixpiKit.provision;
          nixpi-flash = nixpiKit.flash;
          nixpi-vault-token = nixpiKit.vault-token;

          # (macvm-tart-* and the macvm-only `vpn` operator were removed with the
          # macvm host, 2026-09-05 — docs/macvm-readd-runbook.md.)

          # Health check for the local Claude Code routing-telemetry OTel
          # Collector (services.claudeOtel, modules/shared/claude-otel.nix).
          claude-otel-doctor = pkgs.callPackage ../../packages/claude-otel-doctor.nix { };

          # Deterministic ADB wired/wireless operator + scrcpy mirroring for a
          # physical Android device (adb/scrcpy resolved at runtime from the
          # android-platform-tools/scrcpy Homebrew formulae, hosts/macos.nix).
          # Also on PATH via home.packages, macos only (modules/shared/home.nix).
          android-phone = pkgs.callPackage ../../packages/android-phone.nix { };

          # (`secret` / `set-secret` / `remove-secret` — the macOS login-Keychain
          # CLIs — are NOT here. They were `inherit (keychain-secrets.packages.
          # ${system}) …` from the extracted flake until ADR-002 wave 4 absorbed
          # it; the capsule now registers them itself in
          # modules/features/keychain-secrets/flake-module.nix, which is the one
          # place that also builds them for the home-manager module. The `apps`
          # below still expose them via `config.packages.<name>` and are
          # unchanged. DARWIN-ONLY either way: the Keychain is macOS-only.)

          jsonresume = pkgs.callPackage ../../packages/jsonresume.nix {
            defaultUrl = jsonResumeUrl;
          };

          # `email-signature` (macOS only) — render a paste-ready HTML email signature from
          # the same JSON Resume (baked jsonResumeUrl) plus the logo.svg fetched from the same
          # gist (baked logoUrl), rasterized via librsvg. Exposed as a package so `nix flake
          # check` BUILDS it (writeShellApplication
          # shellcheck); on PATH via home.packages, run on activation, and `nix run
          # .#email-signature`. See packages/email-signature/ (default.nix).
          email-signature = pkgs.callPackage ../../packages/email-signature {
            defaultUrl = jsonResumeUrl;
            inherit logoUrl tokensUrl;
          };

          # `design-tokens` (macOS only) — transform the same gist tokens.json (baked
          # tokensUrl) into SCSS/CSS/JS via Style Dictionary (v4, via npx), so any consumer
          # builds from one source of truth. Exposed as a package so `nix flake check` BUILDS
          # it (writeShellApplication shellcheck); on PATH via home.packages + `nix run
          # .#design-tokens`. See packages/design-tokens/ (default.nix).
          design-tokens = pkgs.callPackage ../../packages/design-tokens {
            inherit tokensUrl;
          };

          # `jobspy` (macOS only) — scrape jobs from LinkedIn/Indeed/Glassdoor/etc. into
          # CSV/JSON via the off-the-shelf python-jobspy library, run in an ephemeral uv
          # env. Exposed as a package so `nix flake check` BUILDS it (writeShellApplication
          # shellcheck); on PATH via home.packages + `nix run .#jobspy`. See packages/jobspy.nix.
          jobspy = pkgs.callPackage ../../packages/jobspy.nix { };
        }
      );

      apps = lib.optionalAttrs isDarwin {
        # `nix run .#nixvm` — build the graphical build-vm variant and
        # boot it in a native macOS QEMU window: a THROWAWAY XFCE dev VM (no
        # installed disk, no provisioning). The runner wrapper is a darwin
        # derivation (host.pkgs = aarch64-darwin); the aarch64-linux guest
        # closure builds on Determinate's native Linux builder (enabled on the
        # macos host) or is substituted from Cachix. run-nixvm-vm is the
        # qemu-vm.nix script name for "nixvm".
        nixvm = {
          type = "app";
          program = "${self.nixosConfigurations.nixvm.config.system.build.vm}/bin/run-nixvm-vm";
          meta.description = "Boot a THROWAWAY nixvm dev VM with an XFCE desktop in a QEMU window (builds locally on the native Linux builder)";
        };

        # `nix run .#key-backup` — on a HEALTHY Mac, before you wipe it:
        # publishes the passphrase-encrypted operator key + the bootstrap
        # script + a (non-secret) fingerprint manifest into iCloud.
        key-backup = {
          type = "app";
          program = "${config.packages.key-backup}/bin/key-backup";
          meta.description = "Publish the encrypted key-recovery kit to iCloud (run BEFORE resetting this Mac)";
        };

        # `nix run .#key-recover` — stage 2 of recovery/founding. bootstrap.sh
        # execs this once Determinate Nix exists. It clones, verifies the macOS
        # login == this flake's `loginName` (#identity.loginName), then either
        # (kit) decrypts the operator key + re-keys agenix to the new host key,
        # or (--fresh, no kit) FOUNDS a new operator identity + re-initialises
        # the macos service secret to a placeholder — then activates #macos.
        # Stage 1 (the stale-Nix preflight + the installer itself) cannot run
        # under Nix and lives in bootstrap.sh at the repo root.
        key-recover = {
          type = "app";
          program = "${config.packages.key-recover}/bin/key-recover";
          meta.description = "Restore (kit) or found (--fresh) the operator key, re-key agenix to this Mac's host key, and activate #macos";
        };

        # `nix run github:kattakath/nix-config#macos` — one-line first
        # activation of the macos nix-darwin host straight from the flake (the
        # darwin analog of nixpi's `nixos-rebuild switch --flake …#nixpi`).
        # After Determinate Nix is
        # installed but before darwin-rebuild is on PATH, this builds
        # darwin-rebuild from the flake and `switch`es against this SAME
        # revision (${self}); darwin-rebuild self-elevates via sudo/Touch ID.
        # Subsequent rebuilds just use `darwin-rebuild switch --flake .#macos`.
        macos = {
          type = "app";
          program = "${pkgs.writeShellScript "activate-macos" ''
            exec ${self.darwinConfigurations.macos.config.system.build.darwin-rebuild}/bin/darwin-rebuild switch --flake "${self}#macos" "$@"
          ''}";
          meta.description = "First activation of the macos nix-darwin host from the flake (after Determinate Nix)";
        };

        # (The #macvm activation app, the macvm-tart-* Tart lifecycle apps,
        # and the macvm-only #vpn operator were removed with the macvm host,
        # 2026-09-05 — docs/macvm-readd-runbook.md.)

        # Claude Code routing-telemetry collector health check.
        claude-otel-doctor = {
          type = "app";
          program = "${config.packages.claude-otel-doctor}/bin/claude-otel-doctor";
          meta.description = "Check the local Claude Code OTel Collector: launchd agent, OTLP port, events file";
        };

        # Deterministic ADB wired/wireless operator + scrcpy mirroring.
        android-phone = {
          type = "app";
          program = "${config.packages.android-phone}/bin/android-phone";
          meta.description = "ADB operator: android-phone list|pair|connect|disconnect|unpair|tcpip|wireless|mirror|doctor";
        };

        # `nix run .#set-secret -- KEY [VALUE]` — store a secret in the macOS
        # login Keychain (encrypted at rest) + register it for the login
        # export loop. Bare `nix run` only persists; the `set-secret` shell
        # function (modules/shared/home.nix) also applies it to the current
        # shell. Darwin-only (Keychain).
        set-secret = {
          type = "app";
          program = "${config.packages.set-secret}/bin/set-secret";
          meta.description = "Store KEY=VALUE in the macOS login Keychain (encrypted) and register it for login-shell export; omit VALUE for a hidden prompt";
        };

        # `nix run .#remove-secret -- KEY` — delete KEY from the macOS login
        # Keychain and unregister it (alias for `set-secret --remove`). Bare
        # `nix run` only mutates the Keychain; the remove-secret shell function
        # (modules/shared/home.nix) also unsets it from the current shell.
        remove-secret = {
          type = "app";
          program = "${config.packages.remove-secret}/bin/remove-secret";
          meta.description = "Delete KEY from the macOS login Keychain and unregister it from the set-secret index (alias for set-secret --remove)";
        };

        # `nix run .#secret -- <set|reveal|rm|ls> …` — the primary noun-verb
        # interface to the Keychain secret store (set-secret/remove-secret are
        # its aliases). `secret load` is shell-function-only (mutates the
        # current shell); the app covers the Keychain-only verbs.
        secret = {
          type = "app";
          program = "${config.packages.secret}/bin/secret";
          # NO `get`: printing a value is opt-in via `reveal` (CLAUDE.md § Security).
          meta.description = "Keychain secret store: secret set|reveal|rm|ls (primary interface; set-secret/remove-secret are aliases)";
        };

        # nixpi SD-card provisioning (macOS). The executable runbook: build +
        # verified dd + plant token/wifi (nixpi-flash), plant onto a mounted card
        # (nixpi-provision), emit a wpa_supplicant.conf from this Mac's Wi-Fi
        # (nixpi-wifi-creds), and re-encrypt a rotated token into the vault
        # (nixpi-vault-token). See packages/nixpi-provision.nix + the flashing runbook.
        nixpi-flash = {
          type = "app";
          program = "${config.packages.nixpi-flash}/bin/nixpi-flash";
          meta.description = "Fresh reflash: build (or --image) → verified dd → auto-plant token+wifi (--disk /dev/diskN)";
        };
        nixpi-provision = {
          type = "app";
          program = "${config.packages.nixpi-provision}/bin/nixpi-provision";
          meta.description = "Plant the connector token and/or wpa_supplicant.conf onto a mounted nixpi FIRMWARE partition (--all|--token|--wifi)";
        };
        nixpi-wifi-creds = {
          type = "app";
          program = "${config.packages.nixpi-wifi-creds}/bin/nixpi-wifi-creds";
          meta.description = "Emit a wpa_supplicant.conf from this Mac's current Wi-Fi network (SSID + keychain PSK + locale country)";
        };
        nixpi-vault-token = {
          type = "app";
          program = "${config.packages.nixpi-vault-token}/bin/nixpi-vault-token";
          meta.description = "Re-encrypt a new connector token (stdin/$TUNNEL_TOKEN) into secrets/cloudflared-token.age (run from the repo root)";
        };

        # `nix run .#jsonresume -- <download|print|markdown|text> …` — fetch a JSON
        # Resume and render it (PDF, or theme-less Markdown/text to stdout) via the
        # npm resume CLI (also on PATH via home.packages).
        jsonresume = {
          type = "app";
          program = "${config.packages.jsonresume}/bin/jsonresume";
          meta.description = "Fetch a JSON Resume (--url, else the baked-in default) and render it — PDF (theme from meta.theme), or Markdown/plain text to stdout: jsonresume download|print|markdown|text";
        };

        # `nix run .#email-signature -- [--url URL] [--out DIR]` — render a self-contained
        # HTML email signature from the JSON Resume + bundled logo (also on PATH via
        # home.packages, and regenerated on activation).
        email-signature = {
          type = "app";
          program = "${config.packages.email-signature}/bin/email-signature";
          meta.description = "Render a paste-ready HTML email signature from your JSON Resume (--url, else baked default) + bundled logo into ~/.local/share/email-signature/signature.html";
        };

        # `nix run .#design-tokens -- [--tokens-url URL] [--out DIR]` — transform the gist
        # DTCG tokens.json into SCSS/CSS/JS via Style Dictionary (also on PATH via
        # home.packages).
        design-tokens = {
          type = "app";
          program = "${config.packages.design-tokens}/bin/design-tokens";
          meta.description = "Transform the gist brand tokens.json (--tokens-url, else baked default) into SCSS/CSS/JS via Style Dictionary, into ~/.local/share/design-tokens/";
        };

        # `nix run .#jobspy -- --search "…" --location "…" …` — scrape jobs from
        # multiple boards into CSV/JSON via python-jobspy (also on PATH via home.packages).
        jobspy = {
          type = "app";
          program = "${config.packages.jobspy}/bin/jobspy";
          meta.description = "Scrape jobs (LinkedIn/Indeed/Glassdoor/…) into CSV/JSON via python-jobspy: jobspy --search … --location … [--sites …] [--results N] [--remote]";
        };
      };
    };
}
