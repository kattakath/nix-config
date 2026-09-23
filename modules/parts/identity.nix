# ---- Single source of truth for the human identity, the owner, the cache ----
#
# Moved VERBATIM out of flake.nix's `let` block by the ADR-002 wave-2
# flake-parts conversion. Nothing here changed value or meaning; only its home
# did. `config.fleet.<name>` is what every other part reads.
#
# WHY `lazyAttrsOf raw` AND NOT `uniq`/`unique`: so more than one file can
# contribute to the same attrset — `modules/parts/systems.nix` adds the system
# lists to this very option. This copies flake-parts' own
# `modules/nixosConfigurations.nix:12` (`types.lazyAttrsOf types.raw`); a
# `types.unique` here would force every seam back into one file, which is
# exactly the monolith this wave is undoing. It is now the option's FREEFORM
# type rather than its whole type — see `options.fleet` below, where
# `identityArgs` alone is declared and typed.
# OPERATOR-ONLY — every VALUE in this file (names, emails, gist, Cloudflare ids, sites,
# the SSH key) is this operator's. The SHAPE (`config.fleet.*`, `flake.identity`) is the
# engine; a consumer supplies its own values through mkDarwin's `identity` argument.
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

  # ---- The CANONICAL identity (ADR-004 §2.6, docs/identity-and-offboarding.md) ---
  # The Google Workspace account. GitHub login (SSO), FlakeHub/Determinate auth,
  # Cloudflare Access (Google is the only IdP) and GCP Secret Manager — the
  # secrets-recovery backend — all trace back to THIS account; suspending it is
  # the single offboarding lever. Spelled from loginName + domainName because
  # that is how Workspace mints it, so the three cannot drift apart.
  #
  # NOT in identityArgs: that attrset is what a template consumer REPLACES with a
  # documented four-field identity, and a fifth required field there is the exact
  # breakage `publicMcpPort` caused on 2026-09-16 (modules/parts/compose.nix).
  # Fleet code reads it as config.fleet.googleAccount; the home profile gets it
  # through mkHomeManagerModule's fleet-constants inherit list.
  googleAccount = "${loginName}@${domainName}";

  # Git identity. Its own binding rather than "${loginName}@${domainName}",
  # so the commit address can be GitHub's noreply (which never leaks a real
  # mailbox) without dragging the POSIX account name along with it.
  userEmail = "8927166+${userName}@users.noreply.github.com";

  # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
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

  # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
  # ---- Single source of truth for the operator SSH public key ------------
  # The sole network login credential on every NixOS host AND the agenix
  # "keep editable" recipient. Public, so the secret-free sdImage embeds it
  # freely. Threaded to core.nix via mkNixos specialArgs and read directly by
  # secrets/secrets.nix — one file to edit on rotation (see secrets/operator-key.nix).
  operatorSshKey = import ../../secrets/operator-key.nix;

  # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
  # ---- Single source of truth for the Cloudflare account/zone ------------
  # Threaded (with domainName) into the cfTunnelConfig terranix stack via
  # `_module.args`, so the account/zone ids and the domain live in ONE place
  # instead of being re-hardcoded. These are IDENTIFIERS, not credentials
  # (safe to commit); the API token stays in the CLOUDFLARE_API_TOKEN env var.
  cloudflareAccountId = "726e0b2aa2bc2c6944f96a042e3c461b";
  cloudflareZoneId = "6e28971881e488941d052bbbf50d69cd"; # the domainName zone

  # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
  # ---- Sites served on nixpi ------------------------------------------------
  # nixpi's Caddy vhosts are driven ENTIRELY by mkNixos's `hostedSites`
  # parameter (see modules/parts/compose.nix): hosts/nixpi.nix generates one
  # Caddy virtualHost per entry, and infra/cloudflare/nixpi-tunnel.nix's
  # `cfTunnelConfig` maps the SAME shape to tunnel ingress + DNS
  # (modules/parts/terranix.nix). Shape: { domain; zoneId ? null; root;
  # www ? true; ownTunnel ? false } (root = a path Caddy file_servers).
  # Formerly supplied by the private nix-personal composition flake; folded in
  # here when that flake was retired (2026-09-15) — see docs/repo-map.md.
  hostedSites = [
    {
      domain = "snoringirl.com";
      zoneId = "21de2a6be1b268b2b151ae0b3592e562";
      root = ../../sites/snoringirl;
    }
    # ismail.kattakath.com moved OFF nixpi/Caddy to GitHub Pages 2026-09-16 (nixpi
    # was down; decoupled from the Pi). Now served by the kattakath/ismail-landing
    # repo; DNS is a plain CNAME -> kattakath.github.io (DNS-only), no longer a
    # tunnel CNAME here. sites/ismail-landing stays as the content source that
    # seeded that repo. Re-add an entry here only to serve it from nixpi again.
    #
    # DO NOT DELETE THAT TREE AS DEAD WEIGHT: its fonts/ subdir is LIVE, and not
    # for a site — modules/shared/next-right-thing.nix reads it for the übersicht
    # widget's typography. Absent from `hostedSites` means "Caddy no longer serves
    # it", not "nothing uses it".
  ];

  # ---- MCP servers exposed on the public gateway ---------------------------
  # THE one roster. `local.mcpGateway.public` named an opt-in subset until
  # 2026-09-22; it and the second proxy are gone, so this list is both what the
  # gateway hosts and what the portal registers, and
  # `checks.<system>.mcp-published-parity` fails the build if those two diverge.
  # Consumed by modules/parts/terranix.nix's mcpPublicConfig/mkMcpPublicTofu.
  #
  # EVERY hosted server, by operator decision (2026-09-22). It must EQUAL
  # `local.mcpGateway.hostedServers`, and `checks.<system>.mcp-published-parity`
  # asserts exactly that — terranix renders outside any host's module system and
  # cannot read the roster back, so a check keeps the two honest.
  #
  # The second proxy this list used to select a subset for is GONE. There is one
  # process, it hosts all of these, and a leaked Access service token reaches all
  # of it — which is the same statement as before, minus the pretence that a
  # subset was protecting anything. The tiers that argument was written about, named so the cost stays
  # legible rather than buried in an alphabetical list. They PARTITION the 26 names
  # below — the bracketed counts must sum to 26, so the arithmetic is checkable
  # instead of decorative, and a name added below without a tier here shows up as a
  # sum that no longer lands:
  #   - machine control : macos-automator (arbitrary AppleScript = RCE on this
  #                       Mac), desktop-commander (a shell, so the same reach by a
  #                       different door), chrome-devtools (live browser
  #                       cookies/sessions), mobile-mcp (the attached device)   [4]
  #   - personal        : gmail-* (four accounts), wordpress + wordpress-adapter
  #                       (prod writes)                                         [6]
  #   - credentialed    : github (PAT, repo write), cloudflare (this account),
  #                       postgres (the local pgvector store), apify (paid)      [4]
  #   - reference       : the remaining twelve hold no credential and reach nothing
  #                       personal — lookup/compute, plus `memory`'s local scratch
  #                       graph                                                [12]
  #
  # desktop-commander is tiered as MACHINE CONTROL deliberately, not as reference:
  # modules/shared/mcp.nix and docs/mcp-gateway.md both call it the shell/RCE
  # surface, and a tiering that left it in the "stateless lookup/compute"
  # remainder would understate the published surface by exactly the server whose
  # publication was the operator decision of 2026-09-22.
  #
  # Narrow it by deleting names here; the next apply then DROPS their Cloudflare
  # objects, which the mkMcpPublicTofu drop-guard will make you confirm.
  #
  # `telegram` WAS here and was removed 2026-09-22, for an upstream bug rather
  # than a policy call. Its `initialize` ADVERTISES the `prompts` and `resources`
  # capabilities, and then both `prompts/list` and `resources/list` answer
  # `-32000 failed to unmarshal arguments: unexpected end of JSON input`.
  # Cloudflare's portal syncs what a server advertises, so it called them, got an
  # internal error, and marked the whole registration `status = error` —
  # contributing 0 of its 5 tools while still occupying a portal slot.
  #
  # Measured on the gateway itself, so this is the server, not the edge: `memory`
  # advertises no prompts and answers `-32601 Method not found`, which the portal
  # tolerates. A clean "not implemented" is fine; a malformed error is not.
  #
  # WITHDRAWING IT NOW COSTS THE TOOLS, which it did not when this was written.
  # The first draft said telegram was "unaffected on the private gateway (:8096),
  # so Claude Code keeps all 5 tools" — true for about a day. The same 2026-09-22
  # change that withdrew it also collapsed the two proxies into one and put every
  # client behind the portal, so there is no private gateway left to keep serving
  # it: withdrawn here means gone from every client, not merely unpublished.
  # `local.mcpGateway.telegram.enable` is therefore also off, and turning it on
  # alone fails mcp-published-parity — that option's comment has the detail.
  # Re-add it here when chaindead/telegram-mcp either implements those methods or
  # stops advertising them.
  #
  # The gmail-* names are `gmailAlias` (modules/shared/mcp.nix) applied to
  # hosts/macos.nix's `local.mcpGateway.gmail.accounts` — lowercased, with
  # @/./+ replaced by _. They are spelled out rather than derived because
  # terranix renders outside any host's module system and cannot read that
  # option back; the mcp.nix assertion catches a name the gateway does not host.
  publicMcpServers = [
    "apify"
    "arxiv"
    "chrome-devtools"
    "cloudflare"
    "cloudflare-docs"
    # The shell/RCE surface, published by operator decision 2026-09-22. It was
    # kept off the gateway entirely until then; see its entry in
    # modules/shared/mcp.nix for what that decision accepts.
    "desktop-commander"
    "context7"
    "duckduckgo"
    "fetch"
    "github"
    "gmail-aloshyakasoto_gmail_com"
    "gmail-ismail_kattakath_com"
    "gmail-ismailkattakath_gmail_com"
    "gmail-izzy_silvercreek_ai"
    "json-yaml-toml"
    # Browser automation by LOCAL BRIDGE, as opposed to chrome-devtools (CDP) and
    # claude-in-chrome (native messaging). Declared 2026-09-23, closing the gap
    # modules/shared/chromium.nix had recorded as a real follow-up: this repo owned
    # the extension half and left the server half imperative in ~/.claude.json.
    "kapture"
    "macos-automator"
    "mcp-jq"
    "mcpfinder"
    "memory"
    "mobile-mcp"
    "nixos"
    "postgres"
    "sequential-thinking"
    "terraform"
    "wordpress"
    "wordpress-adapter"
  ];

  # ---- GCP billing -----------------------------------------------------------
  # The billing account the fleet's GCP project is linked to. An IDENTIFIER, not a
  # credential — the same class as `cloudflareAccountId` above, and committed for
  # the same reason: it names an object, it does not authorise anything. Spending
  # needs ADC, which lives in the operator's gcloud config dir and never in git.
  gcpBillingAccountId = "016854-91C33C-F9E522";

  # Single digit, by operator instruction (2026-09-22): a deliberately tiny number
  # so ANY real spend trips it, since the fleet's only intended GCP cost is
  # Terraform state — kilobytes, inside Always Free, i.e. nothing.
  #
  # A STRING because google.type.Money carries int64 `units` as a JSON string.
  #
  # AND IT IS AN ALERT, NOT A CAP. Google offers no hard spending limit; see the
  # header of infra/gcp/budget.nix. Lowering this number does not buy more safety,
  # it buys an earlier email.
  gcpBudgetAmount = "5";

  # MUST equal the billing account's own currency. Measured 2026-09-22: this
  # account is CAD, and a USD budget on it is rejected as a bare
  # `400 Request contains an invalid argument` — no field violation, no mention of
  # currency, and gcloud gives the identical error, which is why it reads like a
  # malformed request rather than a mismatched one. Check with:
  #   gcloud billing accounts describe <id> --format='value(currencyCode)'
  gcpBudgetCurrency = "CAD";

  # The GCP project the fleet uses. A public identifier; ADR-004 keeps it out of
  # the KEYCHAIN-backend code path (read from gcloud at runtime there), but
  # terranix renders outside any shell and needs it at eval.
  gcpProjectId = "kattakath-family";

  # OpenTofu state bucket (ADR-005 phase 1). Bucket names are a GLOBAL namespace,
  # so this one is prefixed with the org name rather than being a bare "state".
  gcpStateBucket = "kattakath-tofu-state";

  # One of the three regions Always Free covers (us-west1/us-central1/us-east1).
  # State is kilobytes, so this stays free and therefore inside the 5 CAD alert.
  gcpStateBucketLocation = "US-CENTRAL1";

  # The service account terranix impersonates for GCP. An identifier, not a
  # credential: impersonating it requires roles/iam.serviceAccountTokenCreator,
  # which is granted to the operator and to nobody else. No key file exists.
  gcpAutomationServiceAccount = "tofu-fleet@kattakath-family.iam.gserviceaccount.com";

  # The loopback port the gateway's mcp-proxy binds, and therefore the port the
  # published tunnel's ingress must point at. Single-sourced here because its two
  # consumers cannot see each other: modules/shared/mcp.nix binds it (a Home
  # Manager module) and infra/cloudflare/mcp-public.nix routes to it (a terranix
  # module). It was written 8097 in both. A change to one alone is silent and
  # outward-facing — the connector proxies to a dead port and the public endpoint
  # 502s — so the two spellings are exactly the drift this file exists to stop.
  #
  # (It was the SECOND proxy's port until 2026-09-22; the private :8096 one is
  # gone and this is now the only gateway port.)
  publicMcpPort = 8097;

  # ---- The Cloudflare Access organisation, as data ------------------------
  # Rendered by infra/cloudflare/access-org.nix. Read that module's header before
  # changing anything here: the resource models the WHOLE organisation with every
  # attribute optional, so a field dropped from this attrset is an instruction to
  # BLANK it, and `authDomain` is the sign-in host for every Access application in
  # the account — nixpi's SSH gate included.
  #
  # `name` and `authDomain` are mirrored live state, not settings chosen here.
  # Note `name` is "Family" and is NOT `orgName` ("kattakath", the GitHub org) —
  # two different namespaces that happen to describe the same person.
  #
  # WHY THE BRANDING MATTERS AT ALL: the login page is the ONLY surface in the
  # connector flow that carries the operator's mark. Claude renders a generic
  # globe for every custom connector — `serverInfo.icons` exists in MCP spec
  # 2025-11-25 but Claude does not read it (anthropics/claude-ai-mcp#152, open
  # since 2026-04-06), and Cloudflare's portal object has no icon field to put one
  # in either. Measured 2026-09-22.
  #
  # `logoUrl` must be a URL Cloudflare can FETCH, not a file: the login page is
  # rendered by Cloudflare, so the asset is hosted rather than committed here.
  #
  # It is the WORDMARK (512x132) and not the square icon, deliberately — the login
  # header is wide and the mark that fills it is the horizontal one. Verified
  # byte-identical to ~/Pictures/logo.svg.
  #
  # NOT a duplicate of `logoUrl` above: that one is a DIFFERENT lockup
  # (1080x426, from the resume gist) consumed by the email-signature package.
  # Different aspect ratios for different surfaces — do not "DRY" them into one.
  accessOrg = {
    name = "Family";
    authDomain = "kattakath.cloudflareaccess.com";
    loginDesign = {
      logoUrl = "https://raw.githubusercontent.com/kattakath/kattakath.github.io/refs/heads/main/logo.svg";
      backgroundColor = "#300a24";
      headerText = "Sign in with your @${domainName} email";
      footerText = "Members only";
    };
  };

  # ---- Shared identity, as threaded into BOTH builders --------------------
  # Threaded into mkNixos + mkDarwin so system specialArgs and the embedded
  # Home-Manager block can never drift. Only args with a live module consumer
  # are carried: loginName (core/host), fullName+userEmail (home.nix),
  # domainName (nixpi's Caddy vhost + the darwin file-rotation launchd label).
  # userName only builds userEmail above, and orgName is consumed only by
  # PACKAGES (via callPackage, not specialArgs) — the Mac's runner lanes take
  # their org from their own options (local.macosGithubRunner.org,
  # local.tart.githubRunners.<name>.scope), never from identityArgs — so neither is
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
  # Freeform by default, typed where a mistake is expensive — the shape
  # flake-parts gives its OWN top-level option (pinned flake-parts
  # `modules/flake.nix:11-28`: a submodule whose only module sets
  # `freeformType = types.lazyAttrsOf … types.raw`, into which its sibling modules
  # declare individual typed sub-options, e.g. `modules/nixosConfigurations.nix:12`).
  # The mechanism is upstream's: nixpkgs `lib/modules.nix:220` declares
  # `_module.freeformType` ("merge all definitions that don't have an associated
  # option together using this type"), so every attr but `identityArgs` keeps the
  # `lazyAttrsOf raw` merge it has today — `hostedSites`, `operatorSshKey` and the
  # rest are untouched. Zero custom Nix.
  options.fleet = lib.mkOption {
    type = lib.types.submodule {
      freeformType = lib.types.lazyAttrsOf lib.types.raw;

      # WHY ONLY THIS ONE IS TYPED: identityArgs is the attrset a template
      # consumer REPLACES (`identity ? identityArgs`, compose.nix), so its FIELD
      # SET is a published contract — and the way it breaks is by GROWING.
      # `publicMcpPort` was added here on 2026-09-16 and only exploded in a
      # consumer's build (see the note on googleAccount above, and checks.nix's
      # `template-consumer`). A closed submodule moves that failure to THIS file:
      # a fifth field now fails with "The option `fleet.identityArgs.<field>'
      # does not exist" on the first read of any single field.
      #
      # It constrains the DECLARATION, not the call: mkDarwin/mkNixos receive a
      # consumer's `identity` through `specialArgs`, which is outside the module
      # type system by construction — so this buys the declaration site type
      # errors and docs, and buys a consumer nothing.
      options.identityArgs = lib.mkOption {
        type = lib.types.submodule {
          options = {
            loginName = lib.mkOption {
              type = lib.types.str;
              description = "The POSIX account on every host — the `loginName` binding above.";
            };
            fullName = lib.mkOption {
              type = lib.types.str;
              description = "The human's display name, read by modules/shared/home.nix.";
            };
            userEmail = lib.mkOption {
              type = lib.types.str;
              description = "The git commit address — the `userEmail` binding above.";
            };
            domainName = lib.mkOption {
              type = lib.types.str;
              description = "nixpi's Caddy vhosts and the darwin file-rotation launchd label.";
            };
          };
        };
        description = ''
          The four-field identity threaded into BOTH builders' specialArgs and the
          embedded Home-Manager block — exactly the set `templates/default/flake.nix`
          documents. Adding a field is a BREAKING change for every template
          consumer, which is what the closed submodule is for.
        '';
      };
    };
    default = { };
    description = ''
      The fleet's single-source `let` bindings: identity, owner, cache,
      Cloudflare ids and the system lists. Read as `config.fleet.<name>` from
      any `modules/parts/*.nix`. Freeform `lazyAttrsOf raw` so several files can
      contribute (identity.nix + systems.nix today); only `identityArgs` is
      declared and typed.
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
        googleAccount
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
        cloudflareAccountId
        cloudflareZoneId
        hostedSites
        publicMcpServers
        publicMcpPort
        accessOrg
        gcpBillingAccountId
        gcpBudgetAmount
        gcpBudgetCurrency
        gcpAutomationServiceAccount
        gcpProjectId
        gcpStateBucket
        gcpStateBucketLocation
        identityArgs
        ;
    };

    # ---- Machine-readable identity ------------------------------------------
    # The flake's single-source identity bindings, surfaced so `bootstrap.sh`
    # can guard on them BEFORE activating. bootstrap.sh reads
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
        googleAccount
        ;
    };
  };
}
