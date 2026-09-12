# ---- CAPSULE: vast-provision (ADR-002 wave 4) -------------------------------
#
# THE ONLY FILE ANYTHING OUTSIDE THIS DIRECTORY IMPORTS. Absorbed from the
# standalone github:kattakath/nix-vast-provision flake by PLAIN COPY — history
# stays in the archived origin repo, per the operator's decision.
#
# THIS CAPSULE HAS NO MODULE. Unlike the three before it, `vast-provision` never
# shipped a home-manager or NixOS module: it is six macOS CLIs plus a lint. So
# there is no `module.nix` and nothing registers on `capsuleModules` — the
# anatomy's option surface simply does not apply here, and inventing an
# `enable` flag for a `nix run` toolkit would be surface for its own sake.
#
# THE ONE THING THIS CAPSULE IS NOT ALLOWED TO OWN — and why:
#
#   packages/vast-bootstrap.sh
#   packages/templates/provisioner/{provision.sh,provision-lib.sh,
#                                   .provisioner-template.json,README.md}
#
# A Vast.ai template is a STORED, SERVER-SIDE object. The one this toolkit
# creates carries `PROVISIONING_SCRIPT=https://raw.githubusercontent.com/
# <org>/<repo>/<rev>/packages/vast-bootstrap.sh` and `PROVISION_LIB_URL=…/
# packages/templates/provisioner/provision-lib.sh` — literal repo PATHS, baked
# at create time, re-fetched by every instance ever rented from that template.
# `rev` is `self.rev or "main"`, so a template created from a dirty working tree
# is pinned to the MOVING `main`. Move those files and that template 404s on a
# rented, BILLED instance while `nix flake check` stays green (ADR-002 §4,
# finding S2). They therefore stay where they are, engine-owned, and the capsule
# receives them as values through `config.fleet.vastRawServed`
# (modules/parts/packages.nix) — never by a `../../../packages/…` path literal,
# which ast-grep/rules/capsule-must-not-reach-out.yml would reject.
#
# WHAT MOVED, AND WHAT DID NOT:
#   packages/vast-provision.nix  -> ./packages/vast-provision.nix (verbatim but
#                                   for the four `./templates/provisioner/…`
#                                   literals, now the `provisionerTemplate`
#                                   argument, and `scripts-lint` moving out)
#   flake.nix's `scripts-lint`   -> ./checks/scripts-lint.nix, EXTENDED — it now
#                                   lints the raw-served copies (the ones that
#                                   actually reach an instance, which nothing
#                                   linted before) and parses the JSON marker.
#   packages/{vast-bootstrap.sh,templates/provisioner/*} -> already here. There
#     were FOUR copies of the two served scripts across two repos — nix-config's
#     (which the URLs point at, mode 644, unlinted) and the satellite's (mode
#     755, linted). They are now ONE set, at the contract path, executable, and
#     linted; the satellite's three template files it alone carried
#     (provision.sh, .provisioner-template.json, README.md) came across with it.
#   checks.<system>.vast-lib-drift -> DELETED. It existed to diff nix-config's
#     copies against the input's; with one tree there is no second copy, and a
#     check that diffs a file against itself is worse than no check.
#   flake.nix's `packages`/`apps` -> the six packages register HERE; the six
#     `apps` stay in modules/parts/packages.nix, where they already were with
#     this fleet's own `meta.description` strings, pointing at
#     `config.packages.vast-*` — which is now what this capsule provides.
#   flake.nix's treefmt block + checks.treefmt -> DROPPED. This repo's own
#     treefmt.nix / `checks.formatting` already covers this tree.
#   README.md -> ./README.md (rehomed next to the code).
#
# UPSTREAM FIRST → grepped the pinned flake-parts and nixpkgs option surface for
# a "publish a set of CLIs + a lint" seam beyond `perSystem.packages` /
# `perSystem.checks`; there is none, and none is wanted — flake-parts' own
# `modules/packages.nix` and `modules/checks.nix` ARE the registry, and this
# file uses them directly. The capsule registry itself reuses
# `flake-parts.flakeModules.modules` via modules/parts/capsules.nix.
{
  config,
  lib,
  self,
  ...
}:
let
  inherit (config.fleet)
    orgName
    repoName
    userName
    vastRawServed
    ;
in
{
  # Self-registration. modules/parts/capsules.nix's `capsule-registry` check
  # asserts this list equals `readDir ./modules/features`, so a misnamed entry
  # file cannot silently drop a whole capsule while CI stays green (ADR-002 §4,
  # finding S3).
  capsules = [ "vast-provision" ];

  perSystem =
    { pkgs, ... }:
    let
      # DARWIN-ONLY, exactly as the satellite gated it (`systems =
      # [ "aarch64-darwin" ]`) and exactly as nix-config gated it before the
      # absorption: every one of these CLIs shells out to /usr/bin/security for
      # VAST_API_KEY and the synced tokens.
      #
      # The gate is INSIDE the output, never around the module body — a
      # `perSystem` whose SHAPE depends on `pkgs` is an infinite recursion
      # through `_module.args`. Same reason as the three capsules before this.
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

      kit = pkgs.callPackage ./packages/vast-provision.nix {
        inherit orgName repoName userName;
        # `self.rev` is set only from a clean, committed tree (CI, `nix run
        # github:…`); a dirty checkout falls back to "main". CARRIED VERBATIM
        # from the satellite: it is the cache-buster that makes the generated
        # PROVISIONING_SCRIPT URL change whenever the bootstrap does, defeating
        # the Vast base image's Phase-9 URL-hash idempotency skip. It is also
        # why every `vast-*` drv changes on every commit, which is why
        # scripts/drv-snapshot.sh compares them by NAME and not by hash.
        rev = self.rev or "main";
        provisionerTemplate = {
          inherit (vastRawServed)
            provision
            provisionLib
            marker
            readme
            ;
        };
      };
    in
    {
      packages = lib.optionalAttrs isDarwin {
        vast-template-apply = kit.template-apply;
        vast-repo-check = kit.repo-check;
        vast-account-vars-set = kit.account-vars-set;
        vast-ssh-key-set = kit.ssh-key-set;
        vast-init-repo = kit.init-repo;
        vast-rent = kit.rent;
      };

      # NOT darwin-gated, unlike the packages. shellcheck and jq over four
      # committed text files care nothing for the platform, and the check this
      # replaces (`vast-lib-drift`) ran on both legs — dropping the linux leg
      # would quietly halve the coverage of the only lint these boot-time
      # scripts get.
      checks.vast-scripts-lint = pkgs.callPackage ./checks/scripts-lint.nix {
        inherit (vastRawServed)
          bootstrap
          provision
          provisionLib
          marker
          ;
      };
    };
}
