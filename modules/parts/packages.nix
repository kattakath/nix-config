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

  inherit (config.fleet)
    darwinSystems
    orgName
    repoName
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

      # `nix run .#nixvm`'s CWD-INDEPENDENT entry point. Darwin-only in practice —
      # only `apps` (below) forces it, and that whole block is `optionalAttrs isDarwin`.
      #
      # WHY a wrapper at all: upstream resolves `virtualisation.diskImage` against the
      # CALLER's working directory (qemu-vm.nix:129 readlink -f's it, 156 lines before its
      # own `cd "$TMPDIR"` at :285), so the same command grew a different 8 GiB root — and
      # a different saved browser session — per directory it was invoked from. Same root
      # cause as the tofu state lost twice (modules/parts/terranix.nix), same fix shape: pin
      # an XDG state dir. `NIX_DISK_IMAGE` is upstream's OWN override hook, so nothing here
      # is patched or overridden — grepped the pinned tree, `diskImage` and this env var are
      # the only two levers that exist (`virtualisation.vz.diskImage` is a different backend).
      #
      # WHY the mkdir is load-bearing, not tidiness: nothing in qemu-vm.nix creates the
      # image's parent, and `readlink -f` exits 1 on a missing one — which :129's own
      # `|| test -z` swallows, so :131 skips creation while :1355 still emits `-drive file=`.
      # A bare XDG path in `virtualisation.diskImage` would break with no diagnostic.
      #
      # WHY it is NOT in `packages`, unlike every other writeShellApplication here: its text
      # embeds the VM, so `nix flake check` would BUILD the whole aarch64-linux XFCE closure
      # on the darwin leg, which has no Linux builder. Cost: shellcheck runs on first
      # `nix run` instead of in CI.
      nixvmRunner = pkgs.writeShellApplication {
        name = "nixvm-run";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          # 0700 because this image holds the guest's logged-in browser session.
          state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nixvm"
          mkdir -p "$state_dir"
          chmod 700 "$state_dir"
          export NIX_DISK_IMAGE="$state_dir/nixvm.qcow2"
          echo "nixvm root disk (PERSISTS across runs; delete it to reset): $NIX_DISK_IMAGE" >&2
          exec ${self.nixosConfigurations.nixvm.config.system.build.vm}/bin/run-nixvm-vm "$@"
        '';
      };
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
            superhookSrc = "${inputs.kattakath-skills}/plugins/superhook";
          })
          superhook
          superhook-digest
          ;

        page-lab-pick = pkgs.callPackage ../../packages/page-lab-pick.nix {
          # The plugin tree comes from the pinned input, not from this repo — see
          # flake.nix `kattakath-skills`.
          pageLabSrc = "${inputs.kattakath-skills}/plugins/page-lab";
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
          # nixpi SD-card provisioning toolkit (macOS only). Exposed as packages so
          # `nix flake check` BUILDS them — running writeShellApplication's shellcheck
          # on each of the four apps. See packages/nixpi-provision.nix.
          nixpiKit = pkgs.callPackage ../../packages/nixpi-provision.nix {
            inherit orgName repoName;
          };
        in
        {
          nixpi-wifi-creds = nixpiKit.wifi-creds;
          nixpi-provision = nixpiKit.provision;
          nixpi-flash = nixpiKit.flash;
          nixpi-vault-token = nixpiKit.vault-token;

          # (macvm-tart-* and the macvm-only `vpn` operator were removed with the
          # macvm host, 2026-09-05 — docs/macvm-readd-runbook.md.)

          # Health check for the local Claude Code routing-telemetry OTel
          # Collector (local.claudeOtel, modules/shared/claude-otel.nix).
          claude-otel-doctor = pkgs.callPackage ../../packages/claude-otel-doctor.nix { };

          # Runtime health check for every launchd unit this fleet installs:
          # declared-but-not-loaded (incl. non-zero exits), loaded-but-not-declared
          # orphan plists, unrotated log growth, disabled-DB orphans, orphan logs.
          # None of the five can be a flake check — they are properties of the
          # running machine, not the config.
          launchd-doctor = pkgs.callPackage ../../packages/launchd-doctor.nix { };

          # Ad-hoc inspection CLI for the household's Rogers CGM4981 (RDK-B)
          # gateway, which exposes NO shell (22/23 closed, 161 silent; only
          # 80/443/53 answer). Speaks the contract in docs/rdkb-gateway-contract.md.
          # INSPECTION ONLY — a failed login increments a persisted server-side
          # lockout counter, so it authenticates once and never retries. The
          # fleet's WAN-health signal stays the Cloudflare tunnel to nixpi.
          rogers-gw = pkgs.callPackage ../../packages/rogers-gw.nix { };

          # Deterministic ADB wired/wireless operator + scrcpy mirroring for a
          # physical Android device (adb/scrcpy resolved at runtime from the
          # android-platform-tools/scrcpy Homebrew formulae, hosts/macos.nix).
          # Also on PATH via home.packages, macos only (modules/shared/home.nix).
          android-phone = pkgs.callPackage ../../packages/android-phone.nix { };

          # fal.ai: the vendor's own deploy CLI (`fal`) plus `fal-gen`, a thin
          # inference wrapper the vendor does not ship. Ephemeral uv
          # environments, the same shape as fidelity-enhance and jobspy, because
          # none of fal's dependency tree is in nixpkgs. Shared through
          # environment.systemPackages (hosts/macos.nix); reads FAL_KEY from the
          # login Keychain.
          fal = pkgs.callPackage ../../packages/fal.nix { };

          # xAI's grok CLI — a vendor-signed PREBUILT binary, the first in this
          # tree. It replaces a `curl … | bash` install that put a
          # self-updating copy in each user's ~/.grok/bin, outside the store and
          # outside git. Shared via environment.systemPackages (hosts/macos.nix)
          # so both accounts run one reviewed version; per-user state stays in
          # ~/.grok. Darwin-only by meta.platforms, so it never evaluates into
          # the two NixOS hosts.
          # Built from a NARROWED unfree instance, not `pkgs`, and not
          # `allowUnfree = true`: grok is a closed-source vendor binary, and the
          # same reasoning modules/features/tart-vms/flake-module.nix records
          # applies — a predicate listing one name means a SECOND unfree package
          # arriving later fails here instead of being waved through. The host
          # itself already sets `allowUnfree = true` (hosts/macos.nix), so this
          # only matters for the standalone `nix build .#grok` output, which is
          # what CI and the cache consume.
          grok =
            (import inputs.nixpkgs {
              inherit system;
              config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "grok" ];
            }).callPackage
              ../../packages/grok.nix
              { };

          # Google's Antigravity CLI — a vendor-provided PREBUILT binary. It
          # replaces the moving `curl … | bash` installer and is shared through
          # hosts/macos.nix; the package is Darwin-only like the host install.
          antigravity-cli =
            (import inputs.nixpkgs {
              inherit system;
              config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "antigravity-cli" ];
            }).callPackage
              ../../packages/antigravity-cli.nix
              { };

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
        # `nix run .#nixvm` — build the graphical build-vm variant and boot it in a
        # native macOS QEMU window: an UNPROVISIONED XFCE dev VM (no installed disk,
        # no partitioning) whose Nix STORE is rebuilt per boot but whose ROOT — so
        # /home, so browser logins — PERSISTS in the XDG state dir `nixvmRunner` pins
        # above. Disposable, not ephemeral: `rm` that qcow2 to reset. The runner is a
        # darwin derivation (host.pkgs = aarch64-darwin); the aarch64-linux guest
        # closure builds on Determinate's native Linux builder (enabled on the macos
        # host) or is substituted from Cachix. run-nixvm-vm is the qemu-vm.nix script
        # name for "nixvm"; nixvm-run is our wrapper around it.
        nixvm = {
          type = "app";
          program = "${nixvmRunner}/bin/nixvm-run";
          meta.description = "Boot the disposable nixvm XFCE dev VM in a QEMU window — store rebuilt per boot, root disk PERSISTS at $XDG_STATE_HOME/nixvm (guest builds on the native Linux builder)";
        };

        # `nix run github:kattakath/nix-config#macos` — one-line first
        # activation of the macos nix-darwin host straight from the flake (the
        # darwin analog of nixpi's `nixos-rebuild switch --flake …#nixpi`).
        # After Determinate Nix is installed but before darwin-rebuild is on
        # PATH, this builds darwin-rebuild from the flake and `switch`es against
        # this SAME revision (${self}).
        #
        # It SELF-ELEVATES, because darwin-rebuild does NOT. Since nix-darwin's
        # 2025-01-30 root migration `switch` is a bare `id -u` test followed by
        # `exit 1` — PAM is never reached, so a non-root caller gets a dead end
        # instead of this fleet's Touch ID sudo prompt. Upstream deliberately
        # pushed that decision to the caller; packages/activate.nix already makes
        # it once for every LATER rebuild, and this is the same call for the
        # first one. The alternative is a documented command that cannot work as
        # typed — which is exactly how the sudo-self-elevation removal broke a
        # recovery mid-flight once before. `-H` because nix warns when $HOME is
        # not owned by root.
        #
        # After this one run, /etc/nix-darwin and `activate` both exist, so no
        # later rebuild needs this form.
        macos = {
          type = "app";
          program = "${pkgs.writeShellScript "activate-macos" ''
            rebuild=${self.darwinConfigurations.macos.config.system.build.darwin-rebuild}/bin/darwin-rebuild
            if [ "$(id -u)" -eq 0 ]; then
              exec "$rebuild" switch --flake "${self}#macos" "$@"
            fi
            exec /usr/bin/sudo -H "$rebuild" switch --flake "${self}#macos" "$@"
          ''}";
          meta.description = "First activation of the macos nix-darwin host from the flake (self-elevates via sudo/Touch ID; after Determinate Nix)";
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

        # Declared-vs-loaded drift, orphan plists and log hygiene, for every
        # fleet launchd unit.
        launchd-doctor = {
          type = "app";
          program = "${config.packages.launchd-doctor}/bin/launchd-doctor";
          meta.description = "Check every fleet launchd unit: loaded, exit codes, orphaned plists, log growth, disabled-DB and log orphans";
        };

        # Ask the household gateway a question without clicking its GUI. Needs the
        # password injected, never inlined:
        #   secret exec ROGERS_GW_PASSWORD=rogers:cgm4981:admin-password -- nix run .#rogers-gw -- status
        rogers-gw = {
          type = "app";
          program = "${config.packages.rogers-gw}/bin/rogers-gw";
          meta.description = "Inspect the Rogers CGM4981 gateway: status, connected devices and logs, without the GUI";
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
