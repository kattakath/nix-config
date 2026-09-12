# ---- Single source of truth for the human identity, the owner, the cache ----
#
# Moved VERBATIM out of flake.nix's `let` block by the ADR-002 wave-2
# flake-parts conversion. Nothing here changed value or meaning; only its home
# did. `config.fleet.<name>` is what every other part reads.
#
# WHY `lazyAttrsOf raw` AND NOT `uniq`/`unique`: so more than one file can
# contribute to the same attrset — `modules/parts/systems.nix` adds the system
# lists to this very option. This copies flake-parts' own
# `modules/nixosConfigurations.nix:11` (`types.lazyAttrsOf types.raw`); a
# `types.unique` here would force every seam back into one file, which is
# exactly the monolith this wave is undoing.
{ lib, ... }:
let
  # loginName is the POSIX ACCOUNT on every host (users.users.${loginName},
  # home-manager.users.${loginName}, /Users/ismail on the Mac) — NOT a label.
  # It is deliberately NOT the GitHub handle: renaming it would repoint
  # home-manager at a user that does not exist on the machine.
  loginName = "ismail";
  domainName = "kattakath.com";
  fullName = "Ismail Kattakath";

  # userName is the human's cross-service HANDLE — the "username" field on
  # GitHub, GitLab, HuggingFace, LinkedIn, … (all the same string today). It is
  # NOT the POSIX login (that's loginName) and, since the fleet moved under the
  # `kattakath` org, NO LONGER the repo owner (that's orgName) — just the person.
  userName = "ismailkattakath";

  # Git identity. Its own binding rather than "${loginName}@${domainName}",
  # so the commit address can be GitHub's noreply (which never leaks a real
  # mailbox) without dragging the POSIX account name along with it.
  userEmail = "8927166+${userName}@users.noreply.github.com";

  # ---- Optional: JSON Resume gist ----------------------------------------
  # The GitHub Gist ID hosting resume.json (jsonresume.org). OPTIONAL — set to
  # null to disable. When non-null it composes jsonResumeUrl below (the raw
  # resume.json URL), which is BAKED into the `jsonresume` package as its default
  # --url (packages/jsonresume.nix) — no ambient env var, since that package is
  # its only consumer. Owner is the GitHub handle (userName), not the POSIX loginName.
  jsonResumeGistId = "5fc44006a632f8466f09b61749129a88";

  # The raw resume.json URL, derived from the gist id + handle (null when the id is
  # null). Threaded to the jsonresume package (via home.nix + the packages fold) as
  # its baked-in default --url — the composition lives here, in one place.
  jsonResumeUrl =
    if jsonResumeGistId == null then
      null
    else
      "https://gist.githubusercontent.com/${userName}/${jsonResumeGistId}/raw/resume.json";

  # The raw logo.svg URL, from the SAME gist — one canonical source of truth for
  # identity assets (resume + logo). null when the gist id is null. Baked into the
  # email-signature package as its default --logo-url; the generator fetches it, caches
  # it locally (~/.local/share/email-signature/logo.svg), and rasterizes it. Kept here
  # so the composition lives in one place, alongside jsonResumeUrl.
  logoUrl =
    if jsonResumeGistId == null then
      null
    else
      "https://gist.githubusercontent.com/${userName}/${jsonResumeGistId}/raw/logo.svg";

  # The raw brand design-tokens URL (W3C DTCG), from the SAME gist. null when the gist id
  # is null. Baked into the email-signature package as its default --tokens-url; the
  # generator reads colors + font family from it (falling back to built-in defaults when
  # unavailable), so the palette/typography stay in one canonical place.
  tokensUrl =
    if jsonResumeGistId == null then
      null
    else
      "https://gist.githubusercontent.com/${userName}/${jsonResumeGistId}/raw/tokens.json";

  # ---- Single source of truth for the GitHub owner -----------------------
  # The org that owns the repo and the Cachix cache.
  # Split from userName so the two can never be confused again: everything
  # that says "who publishes this" is orgName; everything that says "who is
  # the person" is userName/loginName.
  orgName = "kattakath";
  repoName = "nix-config";
  flakeRef = "github:${orgName}/${repoName}";

  # ---- Single source of truth for the Cachix binary cache ----------------
  # The public read-only CI cache, consumed by every host. Threaded into the
  # NixOS builder's specialArgs (modules/shared/nix-cache.nix) and into the
  # macOS host's Determinate customSettings — one literal, no duplication.
  cachixUrl = "https://${orgName}.cachix.org";
  cachixKey = "${orgName}.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw=";

  # ---- Single source of truth for the operator SSH public key ------------
  # The sole network login credential on every NixOS host AND the agenix
  # "keep editable" recipient. Public, so the secret-free sdImage embeds it
  # freely. Threaded to core.nix via mkNixos specialArgs and read directly by
  # secrets/secrets.nix — one file to edit on rotation (see secrets/operator-key.nix).
  operatorSshKey = import ../../secrets/operator-key.nix;

  # ---- Operator identity email for Google-IdP access allowlists -----------
  # The real login identity (distinct from `userEmail`, the GitHub noreply
  # commit address) — default Google-allowed-user for the HyperFrames
  # self-host stack's Access policy (packages/hyperframes-selfhost.nix). Not
  # a secret.
  operatorEmail = "ismail@${domainName}";

  # ---- Single source of truth for the Cloudflare account/zone ------------
  # Threaded (with domainName) into the cfTunnelConfig terranix stack via
  # `_module.args`, so the account/zone ids and the domain live in ONE place
  # instead of being re-hardcoded. These are IDENTIFIERS, not credentials
  # (safe to commit); the API token stays in the CLOUDFLARE_API_TOKEN env var.
  cloudflareAccountId = "726e0b2aa2bc2c6944f96a042e3c461b";
  cloudflareZoneId = "6e28971881e488941d052bbbf50d69cd"; # the domainName zone

  # ---- Sites served on nixpi: composition hook, not a live list -----------
  # nixpi's Caddy vhosts are driven ENTIRELY by mkNixos's `hostedSites`
  # parameter (see modules/parts/compose.nix) — this public repo defines the
  # SHAPE and the GENERIC Caddy-generation code (hosts/nixpi.nix), never any real
  # site. Shape: { domain; zoneId ? null; root; www ? true; ownTunnel ? false }
  # (root = a path Caddy file_servers). infra/cloudflare/nixpi-tunnel.nix's
  # `cfTunnelConfig` maps the SAME shape to tunnel ingress + DNS (also
  # overridable — see modules/parts/terranix.nix). Public hosts pass nothing, so
  # `hostedSites` defaults to `[ ]`: Caddy runs, zero vhosts, the sdImage
  # stays secret- and site-free. The real production sites (kattakath.com,
  # snoringirl.com, ismail.kattakath.com, dontsell.ai) are supplied by the
  # private nix-personal composition flake's `nixosConfigurations.nixpi`,
  # mirroring the Vast-provisioner pattern (`extraHomeModules` for the Mac;
  # `hostedSites` + `extraModules` for nixpi) — see
  # docs/private-home-modules.md.

  # ---- Shared identity, as threaded into BOTH builders --------------------
  # Threaded into mkNixos + mkDarwin so system specialArgs and the embedded
  # Home-Manager block can never drift. Only args with a live module consumer
  # are carried: loginName (core/host), fullName+userEmail (home.nix),
  # domainName (nixpi's Caddy vhost + the darwin file-rotation launchd label).
  # userName only builds userEmail above, and orgName is consumed only by
  # PACKAGES (via callPackage, not specialArgs) — the Mac's runner lanes take
  # their org from their own options (services.macosGithubRunner.org,
  # tart.githubRunners.<name>.scope), never from identityArgs — so neither is
  # threaded.
  identityArgs = {
    inherit
      loginName
      fullName
      userEmail
      domainName
      ;
  };
in
{
  options.fleet = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.raw;
    default = { };
    description = ''
      The fleet's single-source `let` bindings: identity, owner, cache,
      Cloudflare ids and the system lists. Read as `config.fleet.<name>` from
      any `modules/parts/*.nix`. Declared `lazyAttrsOf raw` so several files can
      contribute (identity.nix + systems.nix today).
    '';
  };

  config = {
    fleet = {
      inherit
        loginName
        domainName
        fullName
        userName
        userEmail
        jsonResumeGistId
        jsonResumeUrl
        logoUrl
        tokensUrl
        orgName
        repoName
        flakeRef
        cachixUrl
        cachixKey
        operatorSshKey
        operatorEmail
        cloudflareAccountId
        cloudflareZoneId
        identityArgs
        ;
    };

    # ---- Machine-readable identity ------------------------------------------
    # The flake's single-source identity bindings, surfaced so `bootstrap.sh`
    # can guard on them BEFORE activating. `key-recover` reads
    #   nix eval --raw <flake>#identity.loginName
    # right after cloning and HARD-FAILS if it does not equal the macOS login
    # (`id -un`): a mismatch would half-activate home-manager for a POSIX user that
    # does not exist and build /Users/<wrong> paths. This attrset references NO
    # flake inputs, so the eval is instant and fetches nothing — unlike reading
    # `darwinConfigurations.macos.config.system.primaryUser` (which equals loginName
    # by construction, core.nix, but forces the whole darwin module fixpoint and
    # every input) and is hostname-independent (does not depend on the "macos" attr
    # key). A forker who sets `loginName` here is exactly who the guard lets through.
    flake.identity = {
      inherit
        loginName
        orgName
        domainName
        userName
        ;
    };
  };
}
