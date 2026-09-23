# ---- terranix (Nix -> OpenTofu JSON) and the six tofu app families ----------
#
# Renderers + `writeShellApplication` wrappers, moved verbatim from flake.nix's
# `let` (ADR-002 wave 2). Every guard here — the site-free refusal, the
# unpublish refusal, the pinned 0700 state directory — is a recorded incident,
# not hygiene; none of it is rewritten, only rehomed.
#
# `cfTunnelConfig` / `mcpPublicConfig` join `flake.lib`
# ALONGSIDE the builders in modules/parts/compose.nix. That is only possible
# because `flake.lib` is declared `lazyAttrsOf raw` in
# modules/parts/lib-option.nix — under flake-parts' freeform `types.unique`
# default, these two files would be a merge conflict.
{ config, inputs, ... }:
let
  inherit (inputs) nixpkgs terranix;

  inherit (config.fleet)
    domainName
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
    googleAccount
    ;

  # kattakath.com's records, as a PLAIN LIST rather than a `fleet.*` option.
  # Reading them through the module system recursed: `config` inside a terranix
  # `_module.args` block resolves to that module's own config (measured
  # 2026-09-22, the error names `dnsRecords` rather than the cause). One consumer,
  # so an option bought nothing anyway.
  dnsRecords = import ../../infra/cloudflare/kattakath-dns.nix;

  # Per-system nixpkgs accessor (legacyPackages avoids a redundant eval). The
  # tofu builders below take a `system` rather than a `pkgs`, so they keep
  # their original shape; inside `perSystem` this is the same value as the
  # `pkgs` module argument (flake-parts modules/nixpkgs.nix:18-22 defines that
  # as `inputs'.nixpkgs.legacyPackages`).
  pkgsFor = system: nixpkgs.legacyPackages.${system};

  # ---- Cloudflare TUNNEL provisioning (terranix -> OpenTofu) --------------
  # Renders infra/cloudflare/nixpi-tunnel.nix (the remotely-managed tunnel +
  # ingress + proxied CNAME + connector-token output for nixpi) to its own
  # config.tf.json, per system.
  cfTunnelConfig =
    {
      system,
      # Same hostedSites shape/default as mkNixos — public callers (the
      # cf-tunnel-apply/destroy apps below) pass nothing, rendering an
      # ingress/DNS config with zero sites. A private composition flake
      # calls this directly with its own real site list.
      hostedSites ? [ ],
    }:
    terranix.lib.terranixConfiguration {
      inherit system;
      # domainName is the zone name, plus the account/zone ids — threaded from
      # the single flake bindings above (one source of truth, no re-hardcoding).
      modules = [
        ../../infra/cloudflare/nixpi-tunnel.nix
        (tofuGcsBackend "cf-tunnel")
        {
          _module.args = {
            inherit domainName hostedSites;
            accountId = cloudflareAccountId;
            zoneId = cloudflareZoneId;
          };
        }
      ];
    };

  # ---- PUBLISHED MCP gateway (terranix -> OpenTofu) ----------------------
  # Renders infra/cloudflare/mcp-public.nix: the Mac's own tunnel + ingress to
  # the gateway on 127.0.0.1:<publicMcpPort>, the proxied CNAME, ONE Access
  # application gated by a SERVICE TOKEN, and one portal registration per
  # published server.
  #
  # `publicServers` IS `config.fleet.publicMcpServers`. It is passed
  # rather than read from the darwin config because terranix renders outside
  # any host's module system — the pairing is documented in
  # docs/mcp-public-exposure-design.md and the mcp.nix option text. Empty (the
  # default, and what the public apps below render) produces the tunnel and
  # Access objects but registers NO server, so nothing is reachable.
  mcpPublicConfig =
    {
      system,
      publicServers ? [ ],
      publicSubdomain ? "upstream",
      # Remote MCP Workers published under the SAME origin hostname as the
      # gateway, as Cloudflare Worker routes rather than hostnames of their
      # own. Entry shape is documented at the module's own `externalServers`
      # argument (infra/cloudflare/mcp-public.nix) — deliberately not
      # restated here, so the two cannot drift.
      externalServers ? [ ],
    }:
    terranix.lib.terranixConfiguration {
      inherit system;
      modules = [
        ../../infra/cloudflare/mcp-public.nix
        (tofuGcsBackend "mcp-public")
        {
          _module.args = {
            inherit
              domainName
              googleAccount
              publicServers
              publicSubdomain
              externalServers
              publicMcpPort
              ;
            accountId = cloudflareAccountId;
            zoneId = cloudflareZoneId;
          };
        }
      ];
    };

  # writeShellApplication wrapper around `tofu <action>` for the rendered
  # nixpi tunnel config (guards on CLOUDFLARE_API_TOKEN, copies the read-only
  # rendered config out of the store first). On `apply`, it additionally prints the
  # SENSITIVE connector token (a sensitive tofu output) to STDOUT, clearly
  # labeled, so the operator can store it in the vault (`nix run
  # .#nixpi-vault-token`) and plant it on nixpi's FIRMWARE partition. The token
  # is NEVER written to git or the /nix/store — only echoed to the terminal.
  mkCfTunnelTofu =
    {
      system,
      name,
      action,
      hostedSites ? [ ],
    }:
    let
      pkgs = pkgsFor system;
      printToken = ''

        echo "----- CONNECTOR TOKEN for nixpi (SECRET) -----"
        echo "TUNNEL_TOKEN=$(tofu output -raw nixpi_connector_token)"
        echo ""
        echo "Store it (from the repo root): pipe the TUNNEL_TOKEN= line above into"
        echo "  nix run .#nixpi-vault-token"
        echo "then plant it on a mounted card with"
        echo "  nix run .#nixpi-provision --token        # (or reflash)"
        echo "----- end nixpi -----"
      '';
    in
    pkgs.writeShellApplication {
      inherit name;
      # coreutils/gnugrep/gnused are for the DROPPED-RECORD guard below. Pinning
      # them is the point: the guard is the thing standing between a bad render
      # and four deleted zones, so it must not resolve `comm` off the caller's
      # ambient PATH.
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
      ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          echo "  Use the least-privilege token, not the broad one:" >&2
          echo "    secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:nixpi-tunnel -- ${name}" >&2
          echo "  Its scopes (verified minimal for this stack):" >&2
          echo "    Account > Cloudflare Tunnel:Edit          (Personal account only)" >&2
          echo "    Zone    > DNS:Edit                       on ${domainName} + every hosted site zone" >&2
          echo "    Zone    > Zone Settings:Edit             on the same zones" >&2
          echo "    Zone    > Dynamic URL Redirects:Edit     on the same zones (www->apex rulesets)" >&2
          exit 1
        fi
        # DURABLE STATE DIR — the root cause of losing state twice was running
        # `tofu` in whatever directory happened to be the CWD, leaving a
        # gitignored, unbacked-up state file behind. Pin the working directory
        # to an XDG state path instead, so state has one stable home no matter
        # where the app is invoked from. NOTE: the state PAYLOAD carries the tunnel
        # connector token (a `data` source result) — encrypted at rest since
        # ADR-005, but the dir is still 0700 and must never be committed or synced.
        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-cf-tunnel"
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        cd "$state_dir"
        # 0600 on everything written from here on. The umask covers the local
        # scratch — the rendered config.tf.json and the guards' address lists.
        umask 077
        # The tfstate chmod is NOT a GCS-era vestige, and this is the one line of
        # why for all six wrappers: ADR-005 moved this stack's state to the bucket
        # but did not delete the local copy tofu wrote during the migration, so a
        # `terraform.tfstate.backup` still sits in this XDG dir. Measured
        # 2026-09-22 by reading the bytes: it is ENCRYPTED, same
        # `key_provider.pbkdf2.fleet` envelope as the remote object, one serial
        # behind it — NOT the pre-migration plaintext an earlier draft of this
        # comment claimed. It is a redundant offline snapshot, not an exposure.
        # Only gcp-foundation still writes these files live (and its local state is
        # encrypted too); the other five keep the line because 0600 on a stale
        # encrypted state costs nothing and the file is real.
        chmod 600 terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
        echo "tofu working directory: $state_dir" >&2

        rm -f config.tf.json
        cp ${cfTunnelConfig { inherit system hostedSites; }} config.tf.json

        # SITE-FREE GUARD — the twin of the `deploy` trap. A caller that passes
        # no `hostedSites` (or an accidentally emptied one) renders a tunnel
        # whose ingress is SSH + the catch-all 404 and NO site DNS/redirects. A
        # successful apply of that would take every site dark and delete the
        # records/rulesets from state, while reporting SUCCESS.
        # One ingress entry == SSH only; two == SSH + catch-all, still site-free.
        ingress_count=$(
          ${pkgs.jq}/bin/jq '
            [.resource.cloudflare_zero_trust_tunnel_cloudflared_config.nixpi.config.ingress[]?]
            | length' config.tf.json
        )
        if [ "''${ingress_count:-0}" -le 2 ]; then
          echo "REFUSING: rendered config is SITE-FREE (ingress entries: ''${ingress_count})." >&2
          echo "  Applying it would blank the live tunnel's ingress and delete" >&2
          echo "  every site CNAME + www->apex ruleset that is in state." >&2
          echo "  Override only if you genuinely mean a site-free tunnel:" >&2
          echo "    CF_TUNNEL_ALLOW_SITE_FREE=1 ${name}" >&2
          [ "''${CF_TUNNEL_ALLOW_SITE_FREE:-}" = "1" ] || exit 1
          echo "WARNING: CF_TUNNEL_ALLOW_SITE_FREE=1 set — proceeding site-free." >&2
        fi

        ${tofuRemoteStatePrelude}
        tofu init

        # DROPPED-RECORD GUARD — the site-free check above is an ABSOLUTE FLOOR,
        # so it only fires when EVERY site is gone. A render that keeps one site
        # and drops three sails past it (ingress 3 > 2) and then deletes three
        # CNAMEs and three www->apex rulesets while reporting success. The floor
        # cannot see that, because it never looks at what is already live.
        # This does: compare the addresses state holds against the addresses this
        # render declares, and refuse on any DROP.
        #
        # Read through an `if`, never `|| true`: a locked, corrupt or
        # otherwise-unreadable state would yield an empty list, which reads as
        # "nothing to lose" — a guard that fails OPEN exactly when it matters.
        # Refuses unconditionally: this used to fall through to a "first apply,
        # nothing to drop" branch whenever a local `terraform.tfstate` was absent,
        # which ADR-005 made ALWAYS true by moving state to GCS — so the guard
        # failed open in precisely the case it exists for.
        # ABSENT state and UNREADABLE state are different answers, and conflating
        # them either way is a wrong diagnosis. `tofu state list` exits 1 for BOTH
        # (measured against the pinned opentofu: absent state prints
        # "No state file was found"), so discriminate on the message: absent means
        # an empty roster and the actionable guards below, unreadable means this
        # run genuinely cannot tell and must refuse.
        if ! tofu state list > .state-addrs.raw 2> .state-list.err; then
          if grep -qF "No state file was found" .state-list.err; then
            : > .state-addrs.raw
          else
            echo "REFUSING: 'tofu state list' failed, so this run cannot tell whether" >&2
            echo "  an apply would delete live records. Proceeding blind is the one" >&2
            echo "  thing this guard exists to prevent. tofu said:" >&2
            sed 's/^/    /' .state-list.err >&2
            exit 1
          fi
        fi
        # EVERY cloudflare_* type, not an allow-list of two. The first version of
        # this guard named `dns_record|ruleset` and therefore inspected 2 of the 6
        # types the config renders — so a render dropping
        # `cloudflare_zero_trust_access_application.nixpi_ssh` (the SSH Access gate
        # that VANISHED on 2026-08-20 and took ssh plus both deploy legs with it)
        # or any `cloudflare_zone_setting` (the ssl=strict / min_tls / HSTS floor)
        # passed both this check and the floor above, and was applied. An
        # allow-list is the wrong shape here: the failure mode of forgetting to
        # add a type is silent deletion, so the default must be "covered".
        grep -E '^cloudflare_[a-z0-9_]+\.' .state-addrs.raw \
          | sort > .state-addrs || true
        ${pkgs.jq}/bin/jq -r '
          .resource // {} | to_entries[] | .key as $type
          | .value | keys[] | $type + "." + .
        ' config.tf.json | sort > .render-addrs
        # EMPTY-STATE GUARD — the mirror of the drop check, and the hole it
        # closes was found the same day the drop check shipped. The comparison
        # above is state MINUS render, so an EMPTY state yields an empty
        # difference and refuses nothing, while the floor check passes because
        # the render is full. Both guards are blind to a CREATE over live infra.
        #
        # That is not hypothetical here: tofu state is per-USER, under this
        # account's XDG_STATE_HOME. A second admin on this Mac has no such
        # directory, so `tofu` from their session sees a pristine workspace and
        # plans to create a tunnel, DNS records and Access objects that already
        # exist. State has been lost twice before from a wrong working directory;
        # this is the same wound through a different door.
        #
        # A genuine first apply is indistinguishable from that by construction —
        # both are "no state, full render" — so this refuses BOTH and makes the
        # first apply say so explicitly. First applies are rare and deliberate;
        # the accident is neither.
        render_count=$(wc -l < .render-addrs | tr -d ' ')
        if [ ! -s .state-addrs ] && [ "''${render_count:-0}" -gt 0 ]; then
          echo "REFUSING: state is EMPTY but this render declares ''${render_count} resource(s)." >&2
          echo "  Working directory: $state_dir" >&2
          echo "  Applying now would try to CREATE infrastructure that may already" >&2
          echo "  exist, and a tofu apply has NO rollback." >&2
          echo "  Most likely you are running as a DIFFERENT USER than the one whose" >&2
          echo "  state holds the live stack — tofu state here is per-user." >&2
          echo "  If this really is the first apply for this account, say so:" >&2
          echo "    CF_TUNNEL_ALLOW_CREATE=1 ${name}" >&2
          [ "''${CF_TUNNEL_ALLOW_CREATE:-}" = "1" ] || exit 1
          echo "WARNING: CF_TUNNEL_ALLOW_CREATE=1 set — proceeding against empty state." >&2
        fi

        dropped=$(comm -23 .state-addrs .render-addrs)
        if [ -n "$dropped" ]; then
          echo "REFUSING: this render DROPS resources that state already holds:" >&2
          printf '%s\n' "$dropped" | sed 's/^/    /' >&2
          echo "  Applying it would DELETE each of them at Cloudflare, and a tofu" >&2
          echo "  apply has NO rollback — not a generation, not magicRollback." >&2
          echo "  Usually this means hostedSites lost an entry it should still have." >&2
          echo "  Override only if you genuinely mean to delete them:" >&2
          echo "    CF_TUNNEL_ALLOW_DROPS=1 ${name}" >&2
          # Its OWN variable. Sharing CF_TUNNEL_ALLOW_SITE_FREE would mean an
          # operator standing down the floor for a legitimate site removal also
          # silently stood down this check on the same run.
          [ "''${CF_TUNNEL_ALLOW_DROPS:-}" = "1" ] || exit 1
          echo "WARNING: CF_TUNNEL_ALLOW_DROPS=1 set — proceeding with the deletions." >&2
        fi

        # "$@" is forwarded LAST so a caller can add flags (-auto-approve,
        # -target, -refresh=false) without a second app. It cannot weaken the
        # guards above: those run before tofu ${action} is invoked at all, and
        # refusing exits the script rather than falling through to this line.
        tofu ${action} "$@"
      ''
      + nixpkgs.lib.optionalString (action == "apply") printToken;
    };

  # ---- kattakath.com ZONE RECORDS (terranix -> OpenTofu) -------------------
  # Renders infra/cloudflare/zones.nix. The third stack; see that file's header
  # for why mail does not ride in the Pi's plan.
  cfZonesConfig =
    { system }:
    terranix.lib.terranixConfiguration {
      inherit system;
      modules = [
        ../../infra/cloudflare/zones.nix
        (tofuGcsBackend "cf-zones")
        {
          _module.args = {
            inherit domainName dnsRecords;
            accountId = cloudflareAccountId;
            zoneId = cloudflareZoneId;
          };
        }
      ];
    };

  cfAccessOrgConfig =
    { system }:
    terranix.lib.terranixConfiguration {
      inherit system;
      modules = [
        ../../infra/cloudflare/access-org.nix
        (tofuGcsBackend "cf-access-org")
        {
          _module.args = {
            accountId = cloudflareAccountId;
            inherit (accessOrg) authDomain loginDesign;
            orgName = accessOrg.name;
          };
        }
      ];
    };

  # A FOURTH Cloudflare stack, for ONE resource, and that is the right shape:
  # `cloudflare_zero_trust_organization` owns `auth_domain`, the sign-in host for
  # EVERY Access application in the account. Breaking it takes out nixpi's SSH
  # gate and the MCP portal together — a blast radius that shares nothing with a
  # tunnel or a DNS record, which is exactly when ADR-005 §4 says to split.
  #
  # The guard here is not the zones stack's "did the render shrink". There is
  # exactly ONE organisation per account and it has existed since 2026-07-03, so
  # the damaging shape is an apply against EMPTY state: that is a create where
  # only an import is correct.
  mkCfAccessOrgTofu =
    {
      system,
      name,
      action,
    }:
    let
      pkgs = pkgsFor system;
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
      ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          echo "  secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:api -- ${name}" >&2
          echo "  (needs Account > Access: Organizations:Edit — the scoped" >&2
          echo "   cf:cloudflare.com:mcp-public handle 403s on /access/organizations)" >&2
          exit 1
        fi

        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-cf-access-org"
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        cd "$state_dir"
        umask 077
        chmod 600 terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
        echo "tofu working directory: $state_dir" >&2

        rm -f config.tf.json
        cp ${cfAccessOrgConfig { inherit system; }} config.tf.json
        chmod 600 config.tf.json
        ${tofuRemoteStatePrelude}
        tofu init

        echo "auth_domain this render declares: $(jq -r '
          .resource.cloudflare_zero_trust_organization.fleet.auth_domain // "MISSING"
        ' config.tf.json)" >&2

        # EMPTY STATE = an import has not happened. Applying here would try to
        # CREATE an organisation that already exists.
        # Unconditional, as in mkCfTunnelTofu — and here the old fall-through was
        # also a WRONG diagnosis: an unreadable state was reported as "not tracked
        # yet", sending the operator at an import against state that is fine.
        # ABSENT state and UNREADABLE state are different answers, and conflating
        # them either way is a wrong diagnosis. `tofu state list` exits 1 for BOTH
        # (measured against the pinned opentofu: absent state prints
        # "No state file was found"), so discriminate on the message: absent means
        # an empty roster and the actionable guards below, unreadable means this
        # run genuinely cannot tell and must refuse.
        if ! tofu state list > .state-addrs.raw 2> .state-list.err; then
          if grep -qF "No state file was found" .state-list.err; then
            : > .state-addrs.raw
          else
            echo "REFUSING: 'tofu state list' failed, so this run cannot tell whether" >&2
            echo "  the organisation is already tracked. tofu said:" >&2
            sed 's/^/    /' .state-list.err >&2
            exit 1
          fi
        fi
        if ! grep -q '^cloudflare_zero_trust_organization\.' .state-addrs.raw; then
          echo "REFUSING: state does not track the organisation yet." >&2
          echo "  There is exactly ONE per account and it has existed since" >&2
          echo "  2026-07-03, so the correct first move is an IMPORT, never a" >&2
          echo "  create:" >&2
          echo "    nix run .#cf-access-org-import" >&2
          echo "  then re-run ${name} and read the plan: it must show NO changes" >&2
          echo "  before any apply." >&2
          exit 1
        fi

        # ---- The guard that matters: a NULL-WRITE check -----------------------
        # Everything below is one mechanism, so read it once rather than per-test.
        # The provider's encoder (internal/apijson/encoder.go:406-409 @ 5.25.0)
        # omits a key only when it is null in BOTH plan and state; when it is null
        # in the plan and SET in state it sends an explicit JSON `null`, and
        # Update marshals against prior state (resource.go:129). So for this
        # resource "absent from the render" means DELETE, not "leave alone".
        #
        # `computed_optional` attributes are exempt — the framework refills them
        # from state — which leaves exactly these six able to be silently deleted.
        # They are absent from the render because they are unset live; if anyone
        # sets one in the dashboard, this refuses instead of reverting it.
        state_json=$(tofu show -json 2>/dev/null || true)
        if [ -z "$state_json" ]; then
          echo "REFUSING: could not read state as JSON, so this run cannot tell" >&2
          echo "  whether an apply would null out an organisation attribute." >&2
          exit 1
        fi
        # NOT `|| true`. A jq that errors here would yield an empty result, which
        # reads identically to "nothing would be clobbered" — the fail-OPEN shape
        # this repo already hit once on the mcp-public drop guard. Tested against
        # a populated state, a clean state and malformed input (jq exits 5).
        if ! clobbered=$(printf '%s' "$state_json" | jq -r --slurpfile cfg config.tf.json '
          ($cfg[0].resource.cloudflare_zero_trust_organization.fleet) as $render
          | [ "session_duration", "user_seat_expiration_inactive_time",
              "warp_auth_session_duration", "custom_pages", "mfa_config",
              "mfa_ssh_piv_key_requirements" ] as $risky
          | ( .values.root_module.resources // [] )
          | map(select(.type == "cloudflare_zero_trust_organization"))
          | .[0].values // {}
          | to_entries
          | map(select((.key | IN($risky[])) and .value != null and ($render[.key] == null)))
          | .[].key
        '); then
          echo "REFUSING: could not evaluate the null-write guard against state." >&2
          echo "  An empty result and a failed query look the same, so this run" >&2
          echo "  cannot tell whether an apply would delete an org attribute." >&2
          exit 1
        fi
        if [ -n "$clobbered" ]; then
          echo "REFUSING: state holds attributes this render does not declare." >&2
          printf '%s\n' "$clobbered" | sed 's/^/    /' >&2
          echo "" >&2
          echo "  For THIS resource an omission is not a no-op — the provider sends" >&2
          echo "  an explicit null, which DELETES the setting at Cloudflare. Each" >&2
          echo "  name above is a live Access policy (session lifetimes, custom" >&2
          echo "  pages, MFA configuration) that an apply would silently clear." >&2
          echo "  Declare it in infra/cloudflare/access-org.nix with its live value," >&2
          echo "  then re-run. Do not override this one." >&2
          exit 1
        fi

        # auth_domain: compare the render against STATE, not against "". An
        # omission already fails at EVAL (it is a required module argument), so
        # the reachable failure is a WRONG value — a typo in identity.nix — and
        # only state can catch that.
        render_ad=$(jq -r '
          .resource.cloudflare_zero_trust_organization.fleet.auth_domain // ""
        ' config.tf.json)
        if ! state_ad=$(printf '%s' "$state_json" | jq -r '
          ( .values.root_module.resources // [] )
          | map(select(.type == "cloudflare_zero_trust_organization"))
          | .[0].values.auth_domain // ""
        '); then
          echo "REFUSING: could not read auth_domain out of state." >&2
          exit 1
        fi
        if [ -n "$state_ad" ] && [ "$render_ad" != "$state_ad" ]; then
          echo "REFUSING: this render CHANGES the sign-in host." >&2
          echo "    state:  $state_ad" >&2
          echo "    render: $render_ad" >&2
          echo "  auth_domain is the sign-in host for EVERY Access application in" >&2
          echo "  the account. Rewriting it locks nixpi's SSH gate and the MCP" >&2
          echo "  portal in the same apply. If this is a typo in" >&2
          echo "  modules/parts/identity.nix (fleet.accessOrg.authDomain), fix it." >&2
          echo "  If you genuinely mean to move the sign-in host:" >&2
          echo "    CF_ACCESS_ORG_ALLOW_AUTH_DOMAIN_CHANGE=1 ${name}" >&2
          [ "''${CF_ACCESS_ORG_ALLOW_AUTH_DOMAIN_CHANGE:-}" = "1" ] || exit 1
          echo "WARNING: proceeding with an auth_domain change." >&2
        fi

        ${pkgs.lib.optionalString (action == "apply") ''
          # The interactive confirmation is the last line of defence here, because
          # unlike the sibling stacks this one has no address-level drop guard —
          # its whole risk is at the ATTRIBUTE level, inside one resource.
          for a in "$@"; do
            case "$a" in
              -auto-approve|--auto-approve)
                echo "REFUSING: -auto-approve on the Access organisation." >&2
                echo "  Read the diff. An unattended apply here can rewrite the" >&2
                echo "  sign-in host for every Access application in the account." >&2
                exit 1
                ;;
            esac
          done
        ''}

        tofu ${action} "$@"
      '';
    };

  # The import, as an APP rather than a paragraph in a runbook. Both other
  # cf-access-org apps refuse until state tracks the organisation, so the import
  # is MANDATORY — and doing it by hand means reconstructing `TF_ENCRYPTION` in an
  # interactive shell, which puts the state passphrase into the operator's own
  # history. That is the one secret-handling regression every other wrapper here
  # exists to avoid, so it gets a wrapper too. It imports and stops: no plan, no
  # apply, nothing that can write to Cloudflare.
  mkCfAccessOrgImport =
    { system }:
    let
      pkgs = pkgsFor system;
    in
    pkgs.writeShellApplication {
      name = "cf-access-org-import";
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
      ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          echo "  secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:api -- cf-access-org-import" >&2
          exit 1
        fi

        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-cf-access-org"
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        cd "$state_dir"
        umask 077
        rm -f config.tf.json
        cp ${cfAccessOrgConfig { inherit system; }} config.tf.json
        chmod 600 config.tf.json
        ${tofuRemoteStatePrelude}
        tofu init

        # Read-only at Cloudflare: the provider's ImportState reads the org with
        # a GET (resource.go:229-270). The registry docs for 5.25.0 claim this
        # resource has no import support; the source disagrees and the source is
        # what runs. If it ever stops working, that claim is where to look first.
        echo "Importing the Zero Trust organisation into state (no writes)..." >&2
        tofu import cloudflare_zero_trust_organization.fleet ${cloudflareAccountId}

        echo "" >&2
        echo "Imported. NEXT, and do not skip it:" >&2
        echo "  nix run .#cf-access-org-plan" >&2
        echo "It must report NO changes. Anything else — especially a line ending" >&2
        echo "in '-> null' — means the render is missing something state holds." >&2
      '';
    };

  # Its own builder, its own state dir, its own guard — the same reasoning that
  # kept mcp-public separate from cf-tunnel. The failure mode here is unique:
  # this stack is ALL data and no infrastructure, so the damaging mistake is not
  # a bad tunnel, it is a SHRUNKEN render silently deleting mail records.
  mkCfZonesTofu =
    {
      system,
      name,
      action,
    }:
    let
      pkgs = pkgsFor system;
      # The floor. Not a magic number: a render that has lost records relative to
      # state is the only way this stack can hurt you, and MX/DKIM/DMARC loss is
      # not something a plan skimmed at speed reliably catches.
      minRecords = 20;
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
      ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          echo "  secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:api -- ${name}" >&2
          echo "  (needs Zone > DNS:Edit on ${domainName})" >&2
          exit 1
        fi

        # Its OWN state directory. 0700 + umask 077 like the others; this state
        # holds no token, but it holds the zone, and the two prior state losses
        # were both about a stray working directory rather than about secrets.
        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-cf-zones"
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        cd "$state_dir"
        umask 077
        chmod 600 terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
        echo "tofu working directory: $state_dir" >&2

        rm -f config.tf.json
        cp ${cfZonesConfig { inherit system; }} config.tf.json
        chmod 600 config.tf.json
        ${tofuRemoteStatePrelude}
        tofu init

        rendered=$(jq '[.resource.cloudflare_dns_record // {} | keys[]] | length' config.tf.json)
        echo "rendered records: $rendered" >&2

        # FLOOR GUARD — catches "the data file lost half its records" before the
        # delta guard below has to reason about which ones.
        if [ "''${rendered:-0}" -lt ${toString minRecords} ]; then
          echo "REFUSING: render declares ''${rendered} records, under the ${toString minRecords} floor." >&2
          echo "  modules/parts/dns.nix has probably lost entries. Applying this" >&2
          echo "  would DELETE the missing ones — including mail records." >&2
          echo "    CF_ZONES_ALLOW_SHRINK=1 ${name}   # only if you truly mean it" >&2
          [ "''${CF_ZONES_ALLOW_SHRINK:-}" = "1" ] || exit 1
          echo "WARNING: CF_ZONES_ALLOW_SHRINK=1 — proceeding under the floor." >&2
        fi

        # Same three-part guard the other two stacks carry, and for the same
        # reasons. See mkMcpPublicTofu for the full rationale on each.
        # Unconditional, as in mkCfTunnelTofu: there is no local state left to probe.
        # ABSENT state and UNREADABLE state are different answers, and conflating
        # them either way is a wrong diagnosis. `tofu state list` exits 1 for BOTH
        # (measured against the pinned opentofu: absent state prints
        # "No state file was found"), so discriminate on the message: absent means
        # an empty roster and the actionable guards below, unreadable means this
        # run genuinely cannot tell and must refuse.
        if ! tofu state list > .state-addrs.raw 2> .state-list.err; then
          if grep -qF "No state file was found" .state-list.err; then
            : > .state-addrs.raw
          else
            echo "REFUSING: 'tofu state list' failed, so this run cannot tell whether" >&2
            echo "  an apply would delete live records. tofu said:" >&2
            sed 's/^/    /' .state-list.err >&2
            exit 1
          fi
        fi
        grep -E '^cloudflare_[a-z0-9_]+\.' .state-addrs.raw | sort > .state-addrs || true
        jq -r '
          .resource // {} | to_entries[] | .key as $type
          | .value | keys[] | $type + "." + .
        ' config.tf.json | sort > .render-addrs

        render_count=$(wc -l < .render-addrs | tr -d ' ')
        if [ ! -s .state-addrs ] && [ "''${render_count:-0}" -gt 0 ]; then
          echo "REFUSING: state is EMPTY but this render declares ''${render_count} resource(s)." >&2
          echo "  Working directory: $state_dir" >&2
          echo "  For THIS stack that is the expected shape of a first IMPORT, and" >&2
          echo "  applying instead of importing would try to CREATE records that" >&2
          echo "  already exist at Cloudflare. Import first (ADR-005 phase 2)." >&2
          echo "    CF_ZONES_ALLOW_CREATE=1 ${name}" >&2
          [ "''${CF_ZONES_ALLOW_CREATE:-}" = "1" ] || exit 1
          echo "WARNING: CF_ZONES_ALLOW_CREATE=1 set — proceeding against empty state." >&2
        fi

        dropped=$(comm -23 .state-addrs .render-addrs)
        if [ -n "$dropped" ]; then
          echo "REFUSING: this render DROPS objects that state already holds:" >&2
          printf '%s\n' "$dropped" | sed 's/^/    /' >&2
          echo "  Applying it would DELETE each record at Cloudflare, and a tofu" >&2
          echo "  apply has NO rollback. If one of these is mail, the failure is" >&2
          echo "  silent until a message bounces." >&2
          echo "    CF_ZONES_ALLOW_DROPS=1 ${name}" >&2
          [ "''${CF_ZONES_ALLOW_DROPS:-}" = "1" ] || exit 1
          echo "WARNING: CF_ZONES_ALLOW_DROPS=1 set — proceeding with the deletions." >&2
        fi

        tofu ${action} "$@"
      '';
    };

  # The GCS backend, as a module each remote-state stack composes in. One `prefix`
  # per stack inside ONE bucket: separate state objects, shared lifecycle and
  # versioning, and no second bucket to forget to configure.
  #
  # Credentials are ADC (the operator). Deliberately not the automation service
  # account: the backend is read/written by every stack including the Cloudflare
  # ones, which have no google provider at all, and the operator is the identity
  # that already owns the bucket.
  tofuGcsBackend = prefix: {
    terraform.backend.gcs = {
      bucket = gcpStateBucket;
      inherit prefix;
    };
  };

  # ---- Remote state: the GCS backend's encryption, shared ------------------
  # ADR-005 phase 1. The invariant is ENCRYPTION, not remoteness: all SIX stacks
  # source this, including gcp-foundation, which keeps state LOCAL on purpose (it
  # declares the bucket the other five live in) and still encrypts it. So the
  # encryption can never be configured on one stack and forgotten on another.
  #
  # ENCRYPTION IS NOT OPTIONAL HERE. Two of these states hold secrets in
  # PLAINTEXT today — the cf-tunnel connector token and the mcp-public Access
  # service-token secret. Moving those into object storage unencrypted would take
  # a secret that is currently 0600 on one disk and put it in a bucket. The ADR
  # says encryption ships with the backend or the phase does not ship.
  #
  # The passphrase is read from the login Keychain at RUN TIME and handed over in
  # TF_ENCRYPTION, so the whole encryption config exists only in the process
  # environment — never in /nix/store (world-readable), never in argv, never in
  # the rendered config.tf.json. Same shape as every other secret wrapper in this
  # repo (see modules/shared/mcp.nix).
  #
  # LOSE THE PASSPHRASE AND THE STATE IS UNREADABLE. It lives in the login
  # Keychain as `tofu:state:passphrase`. The bucket keeps 10 versions and every
  # one of them is encrypted with this key, so the key is the backup that matters.
  tofuRemoteStatePrelude = ''
    pass="$(/usr/bin/security find-generic-password -a "$(id -un)" -s tofu:state:passphrase -w 2>/dev/null || true)"
    if [ -z "$pass" ]; then
      echo "ERROR: no state-encryption passphrase in the login Keychain." >&2
      echo "  Expected service: tofu:state:passphrase" >&2
      echo "  Without it this stack's remote state cannot be decrypted." >&2
      exit 1
    fi
    export TF_ENCRYPTION="
      key_provider \"pbkdf2\" \"fleet\" {
        passphrase = \"$pass\"
      }
      method \"aes_gcm\" \"fleet\" {
        keys = key_provider.pbkdf2.fleet
      }
      state {
        method = method.aes_gcm.fleet
        enforced = true
      }
    "
    unset pass
  '';

  # ---- GCP foundation (terranix -> OpenTofu) -------------------------------
  # Renders infra/gcp/foundation.nix: enabled APIs, the automation service
  # account and its three bindings, and the OpenTofu state bucket. Everything in
  # it was created by hand on 2026-09-22 and is imported, so the plan reads empty.
  gcpFoundationConfig =
    { system }:
    terranix.lib.terranixConfiguration {
      inherit system;
      modules = [
        ../../infra/gcp/foundation.nix
        {
          _module.args = {
            projectId = gcpProjectId;
            billingAccountId = gcpBillingAccountId;
            operatorAccount = googleAccount;
            automationServiceAccount = gcpAutomationServiceAccount;
            stateBucket = gcpStateBucket;
            stateBucketLocation = gcpStateBucketLocation;
          };
        }
      ];
    };

  mkGcpFoundationTofu =
    {
      system,
      name,
      action,
    }:
    let
      pkgs = pkgsFor system;
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
        pkgs.jq
      ];
      text = ''
        adc="''${GOOGLE_APPLICATION_CREDENTIALS:-''${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json}"
        if [ ! -f "$adc" ]; then
          echo "ERROR: no Application Default Credentials at $adc" >&2
          echo "  Inside 'nix develop':  gcloud auth application-default login" >&2
          exit 1
        fi
        echo "ADC: $adc" >&2

        # LOCAL STATE, deliberately — this stack declares the bucket every other
        # stack's state lives in, so it cannot live there itself. See the header
        # of infra/gcp/foundation.nix.
        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-gcp-foundation"
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        cd "$state_dir"
        umask 077
        chmod 600 terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
        echo "tofu working directory: $state_dir" >&2

        rm -f config.tf.json
        cp ${gcpFoundationConfig { inherit system; }} config.tf.json
        chmod 600 config.tf.json
        ${tofuRemoteStatePrelude}
        tofu init

        # The refusal that matters here is DELETION of the state bucket: it holds
        # every other stack's state, and `prevent_destroy` in the resource only
        # stops tofu, not a render that drops the resource entirely.
        if ! jq -e '.resource.google_storage_bucket.tofu_state' config.tf.json >/dev/null; then
          echo "REFUSING: this render declares NO state bucket." >&2
          echo "  Every other stack keeps its state there. Applying would orphan" >&2
          echo "  or delete it." >&2
          exit 1
        fi

        tofu ${action} "$@"
      '';
    };

  # ---- GCP billing budget (terranix -> OpenTofu) ---------------------------
  # Renders infra/gcp/budget.nix. The SIXTH stack, and the second non-Cloudflare
  # one after gcp-foundation above: a different provider, a different credential
  # (ADC, not an API token) and a different blast radius. Mixing it into a
  # Cloudflare stack would mean one plan that can fail for two unrelated reasons.
  gcpBudgetConfig =
    { system }:
    terranix.lib.terranixConfiguration {
      inherit system;
      modules = [
        ../../infra/gcp/budget.nix
        (tofuGcsBackend "gcp-budget")
        {
          _module.args = {
            billingAccountId = gcpBillingAccountId;
            budgetAmount = gcpBudgetAmount;
            budgetCurrency = gcpBudgetCurrency;
            automationServiceAccount = gcpAutomationServiceAccount;
          };
        }
      ];
    };

  # No API token to check here: the google provider authenticates via ADC, which
  # the devShell scopes to this repo (CLOUDSDK_CONFIG, modules/parts/devshell.nix).
  # That is exactly why the guard below checks for ADC rather than an env var — an
  # unset CLOUDFLARE_API_TOKEN fails loudly, but a MISSING ADC file makes the
  # provider fall back to whatever other credential it can find, which is how you
  # apply to the wrong account without noticing.
  mkGcpBudgetTofu =
    {
      system,
      name,
      action,
    }:
    let
      pkgs = pkgsFor system;
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
        pkgs.jq
      ];
      text = ''
        adc="''${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
        if [ ! -f "$adc" ]; then
          echo "ERROR: no Application Default Credentials at $adc" >&2
          echo "  The google provider reads ADC, not 'gcloud auth login'. Both are needed:" >&2
          echo "    gcloud auth login" >&2
          echo "    gcloud auth application-default login" >&2
          echo "  Run them inside 'nix develop', so they land in this repo's scoped" >&2
          echo "  gcloud config dir rather than the global one." >&2
          exit 1
        fi
        echo "ADC: $adc" >&2

        # NO quota project, and that is the fix rather than an omission.
        #
        # Measured 2026-09-22, in this order: user ADC 403s on billingbudgets
        # without a quota project; setting one (ADC field AND the provider's
        # GOOGLE_BILLING_PROJECT) then 403s on `serviceusage.services.use` even
        # with roles/owner held DIRECTLY on the project. The reason the second
        # error looks like the first is that a quota project makes the client
        # attach `x-goog-user-project` to EVERY call — including the
        # impersonation call — and that header is itself serviceusage-gated.
        #
        # With impersonation the final API call carries the SERVICE ACCOUNT's
        # credential, which needs no quota project at all. So the quota project
        # was never the fix; it was the thing breaking impersonation.

        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-gcp-budget"
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        cd "$state_dir"
        umask 077
        chmod 600 terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
        echo "tofu working directory: $state_dir" >&2

        rm -f config.tf.json
        cp ${gcpBudgetConfig { inherit system; }} config.tf.json
        chmod 600 config.tf.json
        ${tofuRemoteStatePrelude}
        tofu init

        # The budget is ONE object, so the elaborate delta guards the Cloudflare
        # stacks carry would be ceremony here. The one mistake worth refusing is
        # the opposite of theirs: a render that would DELETE the alarm and leave
        # the account unwatched.
        rendered=$(jq '[.resource.google_billing_budget // {} | keys[]] | length' config.tf.json)
        # The `&& [ -s terraform.tfstate ]` this carried could never be true —
        # gcp-budget is GCS-backed too (ADR-005) — so the refusal never fired. A
        # render with no budget is wrong whatever state holds, so drop the probe.
        if [ "''${rendered:-0}" -lt 1 ]; then
          echo "REFUSING: render declares no budget." >&2
          echo "  Applying would DELETE the spend alarm and leave the billing" >&2
          echo "  account unwatched. That is never an accident worth allowing." >&2
          exit 1
        fi

        tofu ${action} "$@"
      '';
    };

  # writeShellApplication wrapper around `tofu <action>` for the PUBLISHED MCP
  # gateway stack (infra/cloudflare/mcp-public.nix). Deliberately its own
  # builder rather than a parameter on mkCfTunnelTofu: it is a different stack
  # with its own state, and — crucially — a different failure mode, so it needs
  # a different guard.
  mkMcpPublicTofu =
    {
      system,
      name,
      action,
      publicServers ? [ ],
    }:
    let
      pkgs = pkgsFor system;
      # Deliberately does NOT print the token. The nixpi app echoes its
      # connector token to the terminal, which puts a live secret into
      # scrollback and any transcript. Here the value is fetched by a separate
      # `mcp-public-token` app that writes ONLY the raw token to stdout, so it
      # can be piped straight into the Keychain and never rendered.
      printToken = ''

        echo ""
        echo "Applied. Store the connector token WITHOUT displaying it:"
        echo "  secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:mcp-public -- \\"
        echo "    nix run .#mcp-public-token | secret set cf:cloudflare.com:mcp-connector"
        echo ""
        echo "The gateway roster is config.fleet.publicMcpServers — one list, and"
        echo "checks.<system>.mcp-published-parity holds it equal to what the gateway"
        echo "hosts. Activate after storing the token."
      '';
    in
    pkgs.writeShellApplication {
      inherit name;
      # gnugrep/gnused/coreutils are the guard's, not the app's — see the twin
      # note on the nixpi builder: a guard must not resolve its tools off the
      # caller's ambient PATH.
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
      ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          echo "  secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:mcp-public -- ${name}" >&2
          echo "  (needs Account > Cloudflare Tunnel:Edit + Access: Apps and Policies:Edit," >&2
          echo "   Access: Service Tokens:Edit, and Zone > DNS:Edit on ${domainName})" >&2
          echo "  NOT cf:cloudflare.com:api — measured 2026-09-14: that broad handle" >&2
          echo "  403s on /access/ai-controls/mcp/servers/*, so tofu aborts at refresh." >&2
          exit 1
        fi

        # Its OWN state directory — a different stack from the nixpi tunnel.
        # 0700 + umask 077 because this state holds BOTH the connector token
        # and the Access service-token secret.
        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-mcp-public"
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        cd "$state_dir"
        umask 077
        chmod 600 terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
        echo "tofu working directory: $state_dir" >&2

        rm -f config.tf.json
        cp ${mcpPublicConfig { inherit system publicServers; }} config.tf.json
        ${tofuRemoteStatePrelude}
        tofu init

        # GUARD — the twin of the site-free trap, shaped for THIS stack.
        # publicServers = [ ] is correct for the FIRST apply (create the
        # tunnel and Access objects before publishing anything). It is
        # destructive later: applying an empty render over state that already
        # holds registrations DELETES them, un-publishing every server while
        # reporting success. Refuse exactly that case.
        rendered=$(${pkgs.jq}/bin/jq '
          [.resource.cloudflare_zero_trust_access_ai_controls_mcp_server // {} | keys[]]
          | length' config.tf.json)
        # `2>/dev/null … || true` FAILED OPEN. A locked, corrupt or
        # otherwise-unreadable state produced an empty list, `in_state` read 0,
        # and the refusal below never fired — so the one situation where you most
        # want a refusal was the one that sailed straight through to an apply
        # that unpublishes every server. Separate the two cases it conflated:
        # "state says zero" and "state could not be read".
        # Unconditional, as in mkCfTunnelTofu: there is no local state left to probe.
        # ABSENT state and UNREADABLE state are different answers, and conflating
        # them either way is a wrong diagnosis. `tofu state list` exits 1 for BOTH
        # (measured against the pinned opentofu: absent state prints
        # "No state file was found"), so discriminate on the message: absent means
        # an empty roster and the actionable guards below, unreadable means this
        # run genuinely cannot tell and must refuse.
        if ! tofu state list > .state-addrs.raw 2> .state-list.err; then
          if grep -qF "No state file was found" .state-list.err; then
            : > .state-addrs.raw
          else
            echo "REFUSING: 'tofu state list' failed, so this run cannot tell whether" >&2
            echo "  an apply would unpublish live servers. tofu said:" >&2
            sed 's/^/    /' .state-list.err >&2
            exit 1
          fi
        fi
        in_state=$(grep -c '^cloudflare_zero_trust_access_ai_controls_mcp_server\.' \
          .state-addrs.raw || true)
        if [ "''${rendered:-0}" -eq 0 ] && [ "''${in_state:-0}" -gt 0 ]; then
          echo "REFUSING: this render publishes 0 servers but state holds ''${in_state}." >&2
          echo "  Applying would UNPUBLISH every one of them." >&2
          echo "  This is the public tree, where publicServers defaults to [ ]." >&2
          echo "  Pass the real list (config.fleet.publicMcpServers)," >&2
          echo "  or override if you genuinely mean to unpublish everything:" >&2
          echo "    MCP_PUBLIC_ALLOW_EMPTY=1 ${name}" >&2
          [ "''${MCP_PUBLIC_ALLOW_EMPTY:-}" = "1" ] || exit 1
          echo "WARNING: MCP_PUBLIC_ALLOW_EMPTY=1 — unpublishing all servers." >&2
        fi

        # PARTIAL loss, which the check above cannot see. It fires only when the
        # render publishes ZERO servers, so a render that keeps three of five
        # passes it and then deletes two registrations, their portal attachments
        # and their Access applications — reporting success. Same delta shape as
        # the nixpi builder, over every rendered type rather than an allow-list,
        # for the same reason: forgetting a type here deletes silently.
        grep -E '^cloudflare_[a-z0-9_]+\.' .state-addrs.raw \
          | sort > .state-addrs || true
        ${pkgs.jq}/bin/jq -r '
          .resource // {} | to_entries[] | .key as $type
          | .value | keys[] | $type + "." + .
        ' config.tf.json | sort > .render-addrs
        # EMPTY-STATE GUARD — the mirror of the drop check, and the hole it
        # closes was found the same day the drop check shipped. The comparison
        # above is state MINUS render, so an EMPTY state yields an empty
        # difference and refuses nothing, while the floor check passes because
        # the render is full. Both guards are blind to a CREATE over live infra.
        #
        # That is not hypothetical here: tofu state is per-USER, under this
        # account's XDG_STATE_HOME. A second admin on this Mac has no such
        # directory, so `tofu` from their session sees a pristine workspace and
        # plans to create a tunnel, DNS records and Access objects that already
        # exist. State has been lost twice before from a wrong working directory;
        # this is the same wound through a different door.
        #
        # A genuine first apply is indistinguishable from that by construction —
        # both are "no state, full render" — so this refuses BOTH and makes the
        # first apply say so explicitly. First applies are rare and deliberate;
        # the accident is neither.
        render_count=$(wc -l < .render-addrs | tr -d ' ')
        if [ ! -s .state-addrs ] && [ "''${render_count:-0}" -gt 0 ]; then
          echo "REFUSING: state is EMPTY but this render declares ''${render_count} resource(s)." >&2
          echo "  Working directory: $state_dir" >&2
          echo "  Applying now would try to CREATE infrastructure that may already" >&2
          echo "  exist, and a tofu apply has NO rollback." >&2
          echo "  Most likely you are running as a DIFFERENT USER than the one whose" >&2
          echo "  state holds the live stack — tofu state here is per-user." >&2
          echo "  If this really is the first apply for this account, say so:" >&2
          echo "    MCP_PUBLIC_ALLOW_CREATE=1 ${name}" >&2
          [ "''${MCP_PUBLIC_ALLOW_CREATE:-}" = "1" ] || exit 1
          echo "WARNING: MCP_PUBLIC_ALLOW_CREATE=1 set — proceeding against empty state." >&2
        fi

        dropped=$(comm -23 .state-addrs .render-addrs)
        if [ -n "$dropped" ]; then
          echo "REFUSING: this render DROPS objects that state already holds:" >&2
          printf '%s\n' "$dropped" | sed 's/^/    /' >&2
          echo "  Applying it would DELETE each of them, and a tofu apply has NO" >&2
          echo "  rollback. Usually this means config.fleet.publicMcpServers lost a" >&2
          echo "  name that Cloudflare still has registered." >&2
          echo "  Override only if you genuinely mean to delete them:" >&2
          echo "    MCP_PUBLIC_ALLOW_DROPS=1 ${name}" >&2
          [ "''${MCP_PUBLIC_ALLOW_DROPS:-}" = "1" ] || exit 1
          echo "WARNING: MCP_PUBLIC_ALLOW_DROPS=1 set — proceeding with the deletions." >&2
        fi

        # See the note on the nixpi builder: forwarded last, cannot weaken the
        # guard above, which exits before reaching here.
        tofu ${action} "$@"
      ''
      + nixpkgs.lib.optionalString (action == "apply") printToken;
    };

  # ---- Force the portal to re-poll every published server --------------------
  # A CLIENT of Cloudflare's own documented endpoint, not something our proxy
  # implements. The direction matters and is easy to get backwards: the portal is
  # an MCP CLIENT against upstream.<domain>, so it calls `initialize`,
  # `tools/list` and `prompts/list` on us. `/sync` is the opposite direction — WE
  # ask Cloudflare to run that poll now instead of waiting for its own schedule.
  #
  #   POST /accounts/{account_id}/access/ai-controls/mcp/servers/{id}/sync
  #   "Sync MCP Server Capabilities", NO request body
  #   — cloudflare/api-schemas openapi.json, one of nine ai-controls/mcp paths
  #
  # WHY IT EXISTS HERE. Restarting the gateway takes ~33s, and mcp-proxy does not
  # bind its socket until all 26 stdio children are spawned and handshaked
  # (mcp_server.py: loop at :183, uvicorn.Server at :237). So the whole window is
  # connection-REFUSED, and anything Cloudflare polls during it records
  # `status = error` — which does NOT self-heal on the next poll in practice.
  # Measured twice on 2026-09-22, once on telegram and once across the portal.
  #
  # So: activate, then run this. It converts "wait and hope the next poll is
  # clean" into a deterministic step with an exit code.
  #
  # NOT a health check we invented, and deliberately not a loop that watches
  # anything — there is no lifecycle protocol to drive (refresh/restart/health all
  # 404). The portal's entire model is poll-and-record; this is its one lever.
  mkMcpPublicSync =
    { system }:
    let
      pkgs = pkgsFor system;
      api = "https://api.cloudflare.com/client/v4/accounts/${cloudflareAccountId}/access/ai-controls/mcp/servers";

      # THE REGISTRATION ID IS NOT THE SERVER NAME for four of these, and calling
      # the wrong one is a silent 404 rather than an error. Cloudflare rejects `_`
      # in a registration id (`7001 ID must contain lowercase letters, numbers,
      # and hyphens only`), so infra/cloudflare/mcp-public.nix maps underscore to
      # hyphen for the id ONLY — the gmail-<sanitized-email> names keep their
      # underscores in the upstream URL, because that is the literal mcp-proxy
      # path.
      #
      # This is the same `cfId` transform, applied to the same list, and it has to
      # be: `publicMcpServers` holds NAMES, this endpoint addresses IDs. Found by
      # running the app — all four gmail entries came back unreachable while the
      # other 21 were ready.
      registrationIds = map (nixpkgs.lib.replaceStrings [ "_" ] [ "-" ]) publicMcpServers;
    in
    pkgs.writeShellApplication {
      name = "mcp-public-sync";
      runtimeInputs = [
        pkgs.curl
        pkgs.jq
        pkgs.coreutils
      ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          echo "  secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:mcp-public -- mcp-public-sync" >&2
          echo "  (NOT cf:cloudflare.com:api — that handle 403s on /access/ai-controls/*)" >&2
          exit 1
        fi

        ok=0
        bad=0
        for id in ${nixpkgs.lib.escapeShellArgs registrationIds}; do
          # No request body: the endpoint takes path parameters only.
          out=$(curl -sS --max-time 60 -X POST \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            "${api}/$id/sync" 2>/dev/null || true)

          status=$(printf '%s' "$out" | jq -r '.result.status // "unreachable"')
          tools=$(printf '%s' "$out" | jq -r '(.result.tools // []) | length')

          if [ "$status" = "ready" ]; then
            printf '  ok     %-34s tools=%s\n' "$id" "$tools"
            ok=$((ok + 1))
          else
            # error_details is documented and distinguishes the two failures that
            # look identical from outside: `is_upstream` is literally "True = MCP
            # server returned an error. False = couldn't reach the server". Print
            # it, because reading it wrong cost a wrong diagnosis twice.
            cause=$(printf '%s' "$out" | jq -r '.result.error_details.cause // .result.error // "?"')
            up=$(printf '%s' "$out" | jq -r '.result.error_details.is_upstream // "?"')
            printf '  FAIL   %-34s status=%s is_upstream=%s :: %s\n' "$id" "$status" "$up" "$cause"
            bad=$((bad + 1))
          fi
        done

        echo "----"
        echo "synced: $ok ready, $bad not ready"
        if [ "$bad" -gt 0 ]; then
          echo "" >&2
          echo "is_upstream=true  -> that SERVER answered badly. Check what it" >&2
          echo "                     advertises in initialize: a server that claims" >&2
          echo "                     prompts/resources and then errors on the list" >&2
          echo "                     call fails the whole registration." >&2
          echo "is_upstream=false -> Cloudflare could not REACH it. Check the" >&2
          echo "                     connector and that the proxy finished starting." >&2
          exit 1
        fi
      '';
    };

  # Prints ONLY the raw connector token to stdout — nothing else, no banner —
  # so it composes: `… | secret set cf:cloudflare.com:mcp-connector`. The value
  # never reaches a terminal, scrollback, the clipboard, or a transcript.
  # Read-only: `tofu init` then `tofu output`, never plan or apply.
  mkMcpPublicToken =
    { system }:
    let
      pkgs = pkgsFor system;
    in
    pkgs.writeShellApplication {
      name = "mcp-public-token";
      # coreutils for the prelude's `id -un`, as in every sibling wrapper.
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
      ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          exit 1
        fi
        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-mcp-public"
        # Gates on the RENDERED CONFIG, not on a local `terraform.tfstate`: ADR-005
        # moved this stack's state to GCS, so that file never exists and the old
        # gate made this app unreachable — the fleet's only non-shell path to the
        # connector token. `tofu init` below needs config.tf.json, which
        # mcp-public-apply leaves here.
        if [ ! -f "$state_dir/config.tf.json" ]; then
          echo "ERROR: no rendered config at $state_dir — run mcp-public-apply first." >&2
          exit 1
        fi
        cd "$state_dir"
        umask 077
        # Remote state is ENCRYPTED, so reading one output needs the same prelude
        # every other wrapper here runs. init writes to STDERR: stdout is the token.
        ${tofuRemoteStatePrelude}
        tofu init -input=false >&2
        # -raw, no trailing banner: stdout is exactly the token.
        tofu output -raw mcp_public_connector_token
      '';
    };

  # The acceptance test the tier split is worth nothing without. It answers ONE
  # question Cloudflare's docs do not: a per-server Access policy is documented to
  # keep a non-matching server "hidden from the bot's tool list" — a statement
  # about DISCOVERY. Nothing says what a `tools/call` NAMING a hidden server does.
  # That distinction is the whole difference between a boundary and obscurity, and
  # `modules/parts/identity.nix` is public, so every server name is already known.
  #
  # WHY A WRAPPER, and not two curl lines in a runbook: the worker credential
  # lives in ENCRYPTED remote state, so reading it by hand means reconstructing
  # TF_ENCRYPTION in an interactive shell — "the one secret-handling regression
  # every other wrapper here exists to avoid" (see mkCfAccessOrgImport above).
  # This reads the pair, uses it, and never prints it: stdout is server names and
  # HTTP codes only.
  mkMcpWorkerProbe =
    { system }:
    let
      pkgs = pkgsFor system;
    in
    pkgs.writeShellApplication {
      name = "mcp-worker-probe";
      runtimeInputs = [
        pkgs.opentofu
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      text = ''
        # The tool to attempt on a GATED server. Default is a READ-ONLY Gmail call
        # on an account this operator owns, so a boundary failure costs a label
        # list and nothing else. Override with argv[1] to probe another.
        forbidden="''${1:-gmail-ismail-kattakath-com_ismail_kattakath_com_list_email_labels}"

        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          exit 1
        fi
        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-mcp-public"
        if [ ! -f "$state_dir/config.tf.json" ]; then
          echo "ERROR: no rendered config at $state_dir — run mcp-public-apply first." >&2
          exit 1
        fi
        cd "$state_dir"
        umask 077

        # The expectation is DERIVED from the rendered config, never retyped: an
        # app carrying TWO policies is one the worker's Service Auth policy was
        # attached to. So this cannot drift from what was actually applied.
        expected="$(jq -r '
          .resource.cloudflare_zero_trust_access_application
          | to_entries
          | map(select(.key | startswith("portal_")))
          | map(select((.value.policies | length) == 2))
          | map(.key | sub("^portal_"; ""))
          | sort | .[]
        ' config.tf.json)"
        expected_n="$(printf '%s\n' "$expected" | grep -c . || true)"

        ${tofuRemoteStatePrelude}
        tofu init -input=false >&2

        cid="$(tofu output -raw mcp_worker_client_id)"
        csec="$(tofu output -raw mcp_worker_client_secret)"
        if [ -z "$cid" ] || [ -z "$csec" ]; then
          echo "ERROR: worker token outputs are empty — is mcp_worker applied?" >&2
          exit 1
        fi

        portal="https://mcp.${domainName}/mcp"
        hdrs="$(mktemp)"; body="$(mktemp)"
        trap 'rm -f "$hdrs" "$body"' EXIT

        # Streamable HTTP may answer as SSE; take the last `data:` payload if so.
        payload() {
          if head -c 1 "$1" | grep -q '{'; then cat "$1";
          else grep '^data: ' "$1" | tail -1 | cut -c7-; fi
        }

        call() {
          curl -sS --max-time 30 -o "$body" -D "$hdrs" -w '%{http_code}' \
            -H "CF-Access-Client-Id: $cid" -H "CF-Access-Client-Secret: $csec" \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            ''${session:+-H "Mcp-Session-Id: $session"} \
            -X POST "$portal" -d "$1"
        }

        session=""
        echo "== step 0: initialize as the worker =="
        code="$(call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-worker-probe","version":"1"}}}')"
        echo "  HTTP $code"
        if [ "$code" != "200" ]; then
          echo "  the worker cannot reach the portal at all — Service Auth is not on the front door." >&2
          exit 1
        fi
        session="$(tr -d '\r' < "$hdrs" | awk 'tolower($1)=="mcp-session-id:"{print $2}')"

        # MANDATORY, and omitting it is not a no-op: without this the portal
        # answers tools/list with its OWN management tools and none of the
        # upstreams, which reads exactly like "the worker can see nothing".
        call '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

        echo "== step 1: tools/list — what can the worker SEE? =="
        code="$(call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
        seen="$(payload "$body" | jq -r '[.result.tools[]?.name] | sort | .[]' 2>/dev/null || true)"
        seen_n="$(printf '%s\n' "$seen" | grep -c . || true)"
        echo "  HTTP $code, $seen_n tools visible"
        echo "  worker-reachable servers per the rendered config ($expected_n):"
        printf '%s\n' "$expected" | sed 's/^/    /'

        leaked=""
        for s in $expected; do :; done
        while read -r t; do
          [ -z "$t" ] && continue
          hit=""
          for s in $expected; do
            case "$t" in "$s"_*) hit=1 ;; esac
          done
          [ -z "$hit" ] && leaked="$leaked $t"
        done <<< "$seen"
        if [ -n "$leaked" ]; then
          echo "  LEAK: tools visible that belong to NO worker-tier server:$leaked"
        else
          echo "  OK: every visible tool belongs to a worker-tier server"
        fi

        echo "== step 1a: what does the PORTAL say this session has? =="
        code="$(call '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"portal_list_servers","arguments":{}}}')"
        echo "  HTTP $code"
        payload "$body" | jq -r '.result.content[]?.text // empty' 2>/dev/null | head -40 | sed 's/^/    /'

        echo "== step 1b: can the worker TOGGLE a gated server ON? =="
        echo "  the portal's own management tools are reachable, so the tier is"
        echo "  only a boundary if they cannot re-enable what it excluded."
        # Deliberately a bogus id FIRST: the error lists every server the toggle
        # tool considers available, which is the roster this session could reach.
        code="$(call '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"portal_toggle_single_server","arguments":{"server_id":"__probe__","action":"enable"}}}')"
        echo "  roster the toggle tool offers this session:"
        payload "$body" | jq -r '.result.content[]?.text // empty' 2>/dev/null | tr ',' '\n' | sed 's/^ */    /' | head -40

        # THE escalation test. `arxiv` is TRUSTED tier — deliberately NOT in the
        # worker tier, and deliberately not a shell: if a non-identity session can
        # switch it on, the per-server policy is decoration, and proving that with
        # desktop-commander would be reckless.
        echo "  attempting to ENABLE a gated server (arxiv, trusted tier):"
        code="$(call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"portal_toggle_single_server","arguments":{"server_id":"arxiv","action":"enable"}}}')"
        echo "    HTTP $code -> $(payload "$body" | jq -r '.result.content[]?.text // .error.message // empty' 2>/dev/null | head -c 200)"
        code="$(call '{"jsonrpc":"2.0","id":11,"method":"tools/list"}')"
        after="$(payload "$body" | jq -r '[.result.tools[]?.name] | length' 2>/dev/null || echo 0)"
        echo "    tools visible AFTER the toggle: $after (was $seen_n)"
        if [ "$after" -gt "$seen_n" ]; then
          echo "    ESCALATION: a non-identity session switched on a server its policy excluded."
        else
          echo "    no escalation: the toggle did not widen this session."
        fi

        echo "== step 2: tools/call a GATED server — the question =="
        echo "  target: $forbidden"
        code="$(call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"$forbidden\",\"arguments\":{}}}")"
        out="$(payload "$body")"
        echo "  HTTP $code"
        echo "  response: $(printf '%s' "$out" | head -c 300)"
        echo
        if [ "$code" = "403" ]; then
          echo "VERDICT: BOUNDARY — Access refused the call outright (403)."
        elif printf '%s' "$out" | jq -e '.error' >/dev/null 2>&1; then
          echo "VERDICT: FILTERED — the portal rejected the tool (JSON-RPC error),"
          echo "  so a gated server is not merely hidden. Read the error above to"
          echo "  confirm it is 'unknown tool' and not a server-side argument error:"
          echo "  a server-side error would mean the call REACHED the gated server."
        else
          echo "VERDICT: OBSCURITY — the call SUCCEEDED against a gated server."
          echo "  The tier filters DISCOVERY only. Since fleet.publicMcpServers is"
          echo "  public, hiding a name bounds nothing; the answer is the second"
          echo "  hostname argument recorded in infra/cloudflare/mcp-public.nix."
        fi
      '';
    };

in
{
  # The renderers, exported for private/external callers (see the header).
  flake.lib = {
    inherit
      cfTunnelConfig
      mcpPublicConfig
      ;
  };

  perSystem =
    { config, system, ... }:
    {
      # Cloudflare tunnel provisioning apps (terranix -> OpenTofu), exposed as
      # packages too so `nix flake check` builds them and runs the
      # writeShellApplication shellcheck on each wrapper.
      packages = {
        # The two oldest stacks had no plan app until 2026-09-23, which made
        # CLAUDE.md's "*-plan first" unfollowable for the two LARGEST blast radii
        # — the Pi's tunnel and the MCP portal. Their apply was the only look you
        # got. Both builders already gate every apply-only side effect on
        # `action == "apply"` (the connector-token echo), so plan is the same
        # wrapper with the same guards and no writes.
        cf-tunnel-plan = mkCfTunnelTofu {
          inherit system hostedSites;
          name = "cf-tunnel-plan";
          action = "plan";
        };
        mcp-public-plan = mkMcpPublicTofu {
          inherit system;
          publicServers = publicMcpServers;
          name = "mcp-public-plan";
          action = "plan";
        };
        cf-tunnel-apply = mkCfTunnelTofu {
          inherit system hostedSites;
          name = "cf-tunnel-apply";
          action = "apply";
        };
        mcp-public-apply = mkMcpPublicTofu {
          inherit system;
          publicServers = publicMcpServers;
          name = "mcp-public-apply";
          action = "apply";
        };
        mcp-public-token = mkMcpPublicToken { inherit system; };
        mcp-worker-probe = mkMcpWorkerProbe { inherit system; };
        mcp-public-sync = mkMcpPublicSync { inherit system; };
        cf-zones-apply = mkCfZonesTofu {
          inherit system;
          name = "cf-zones-apply";
          action = "apply";
        };
        # No `cf-zones-destroy`. Tearing down this stack means deleting every DNS
        # record for the zone — mail included — and there is no scenario where
        # that is a thing you reach for as an app. Remove records from
        # modules/parts/dns.nix instead and let the drop guard make you confirm.
        cf-zones-plan = mkCfZonesTofu {
          inherit system;
          name = "cf-zones-plan";
          action = "plan";
        };
        # No `cf-access-org-destroy` — but NOT because destroy is dangerous here.
        # It is the opposite, and the distinction is worth getting right because
        # it is the panic button: the provider's Delete is an EMPTY function
        # (resource.go:225-227 @ 5.25.0), and its ModifyPlan says so out loud —
        # "will remove the resource from the Terraform state but will not change
        # it in the API". So `tofu destroy` / `tofu state rm` DETACHES Terraform
        # from the organisation and touches nothing at Cloudflare. That is the
        # right move the moment an apply looks wrong.
        #
        # It gets no app only because it is a one-line recovery in the state dir,
        # not something to make routine. Do not "fix" this comment back into
        # saying destroy is unsafe: an earlier draft claimed exactly that, and it
        # would have cost a reader the safest move available at the worst moment.
        cf-access-org-import = mkCfAccessOrgImport { inherit system; };
        cf-access-org-plan = mkCfAccessOrgTofu {
          inherit system;
          name = "cf-access-org-plan";
          action = "plan";
        };
        cf-access-org-apply = mkCfAccessOrgTofu {
          inherit system;
          name = "cf-access-org-apply";
          action = "apply";
        };
        gcp-foundation-plan = mkGcpFoundationTofu {
          inherit system;
          name = "gcp-foundation-plan";
          action = "plan";
        };
        gcp-foundation-apply = mkGcpFoundationTofu {
          inherit system;
          name = "gcp-foundation-apply";
          action = "apply";
        };
        gcp-budget-plan = mkGcpBudgetTofu {
          inherit system;
          name = "gcp-budget-plan";
          action = "plan";
        };
        gcp-budget-apply = mkGcpBudgetTofu {
          inherit system;
          name = "gcp-budget-apply";
          action = "apply";
        };
        # destroy intentionally keeps hostedSites/publicServers at their [ ]
        # default: rendering "nothing" against non-empty state is exactly what
        # trips the guards above, so tearing down the real stack still needs
        # the explicit CF_TUNNEL_ALLOW_SITE_FREE=1 / MCP_PUBLIC_ALLOW_EMPTY=1
        # override. That friction is a "do you really mean to destroy this"
        # gate, independent of whether this repo also holds the real data.
        mcp-public-destroy = mkMcpPublicTofu {
          inherit system;
          name = "mcp-public-destroy";
          action = "destroy";
        };
        cf-tunnel-destroy = mkCfTunnelTofu {
          inherit system;
          name = "cf-tunnel-destroy";
          action = "destroy";
        };
      };

      # ---- Every Access service token NAMES its own expiry ---------------------
      # `duration` is Optional+Computed with a provider default of 8760h, so
      # omitting it does not mean "no expiry" — it means a one-year expiry nobody
      # wrote down. For mcp-public that credential is the portal's ONLY one, so
      # its lapse takes every published server dark at once.
      #
      # Declared HERE rather than in modules/parts/checks.nix because `flake.lib`
      # exports only two of the six renderers; the other four are in scope only
      # inside this file.
      #
      # WHAT THIS CANNOT DO, so the limit is a choice and not an oversight: eval
      # is pure, so it cannot know today's date or read `expires_at`. It asserts
      # only that the window is a DECLARED number and that the number is legal.
      # Days-LEFT is a runtime concern, not a build-time one.
      checks.access-service-token-duration =
        let
          pkgs = pkgsFor system;
          inherit (nixpkgs) lib;
          # `.config` is terranix's passthru — the rendered Terraform attrset at
          # EVAL time, no build. Only strings escape, so this costs no
          # aarch64-linux build. The two GCP stacks are absent on purpose: a
          # Cloudflare resource cannot appear in them.
          renders = [
            {
              stack = "cf-tunnel";
              cfg = (cfTunnelConfig { inherit system hostedSites; }).config;
            }
            {
              stack = "mcp-public";
              cfg =
                (mcpPublicConfig {
                  inherit system;
                  publicServers = publicMcpServers;
                }).config;
            }
            {
              stack = "cf-zones";
              cfg = (cfZonesConfig { inherit system; }).config;
            }
            {
              stack = "cf-access-org";
              cfg = (cfAccessOrgConfig { inherit system; }).config;
            }
          ];

          # Deliberately STRICTER than Go's time.ParseDuration: no leading sign,
          # no bare `0`, no leading-dot form. A token lifetime is never negative
          # and never zero, so the narrowing is the point. The provider ships NO
          # validator on this attribute, so a typo is otherwise a 400 at apply.
          wellFormed =
            d: d == "forever" || builtins.match "([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+" d != null;

          tokens = lib.concatMap (
            r:
            lib.mapAttrsToList (name: v: {
              inherit name;
              inherit (r) stack;
              duration = v.duration or null;
            }) (r.cfg.resource.cloudflare_zero_trust_access_service_token or { })
          ) renders;

          problems =
            map (t: "${t.stack}: ${t.name} declares no duration, so it inherits the provider default 8760h") (
              lib.filter (t: t.duration == null) tokens
            )
            ++ map (t: "${t.stack}: ${t.name} duration ${t.duration} is neither a Go duration nor forever") (
              lib.filter (t: t.duration != null && !(wellFormed t.duration)) tokens
            );
        in
        pkgs.runCommand "access-service-token-duration" { } (
          if problems == [ ] then
            "echo 'access service tokens: ${toString (builtins.length tokens)} rendered, every one with an explicit duration' > $out"
          else
            ''
              echo "access-service-token-duration: a service token leaves its expiry to the provider." >&2
              ${lib.concatMapStringsSep "\n" (x: ''echo "  ${x}" >&2'') problems}
              echo "" >&2
              echo "  The default is 8760h and it is SILENT. For mcp-public that credential" >&2
              echo "  is the portal's only one, so its lapse takes every published server" >&2
              echo "  dark at once, with no partial failure first." >&2
              echo "  Declare duration in infra/cloudflare/<stack>.nix. Changing it later is" >&2
              echo "  an in-place update, not a replacement, so it cannot rotate the secret." >&2
              exit 1
            ''
        );

      # `nix run .#cf-tunnel-apply` / `.#cf-tunnel-destroy` — render
      # infra/cloudflare/nixpi-tunnel.nix (terranix) then `tofu init` + apply
      # (destroy). Provisions nixpi's remotely-managed tunnel + ingress +
      # proxied CNAME; cf-tunnel-apply additionally PRINTS the connector token to
      # be stored in the vault (`nix run .#nixpi-vault-token`) and planted on the
      # FIRMWARE partition (never written to git/store). Token scope: Account
      # Cloudflare Tunnel:Edit + Zone DNS:Edit on kattakath.com.
      #
      # All need a live token in the environment, e.g.
      #   CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-tunnel-apply
      apps = {
        cf-tunnel-plan = {
          type = "app";
          program = "${config.packages.cf-tunnel-plan}/bin/cf-tunnel-plan";
          meta.description = "Render infra/cloudflare/nixpi-tunnel.nix (terranix) and tofu PLAN nixpi's tunnel + ingress + zone settings — read-only, run it before cf-tunnel-apply (needs CLOUDFLARE_API_TOKEN)";
        };
        mcp-public-plan = {
          type = "app";
          program = "${config.packages.mcp-public-plan}/bin/mcp-public-plan";
          meta.description = "Render infra/cloudflare/mcp-public.nix (terranix) and tofu PLAN the published MCP gateway — read-only, and unlike the apply it prints no connector token (needs CLOUDFLARE_API_TOKEN)";
        };
        cf-tunnel-apply = {
          type = "app";
          program = "${config.packages.cf-tunnel-apply}/bin/cf-tunnel-apply";
          meta.description = "Render infra/cloudflare/nixpi-tunnel.nix (terranix), tofu apply it, and print the connector token (needs CLOUDFLARE_API_TOKEN)";
        };
        mcp-public-apply = {
          type = "app";
          program = "${config.packages.mcp-public-apply}/bin/mcp-public-apply";
          meta.description = "Render infra/cloudflare/mcp-public.nix (terranix), tofu apply it, and print the Mac connector token (needs CLOUDFLARE_API_TOKEN)";
        };
        gcp-foundation-plan = {
          type = "app";
          program = "${config.packages.gcp-foundation-plan}/bin/gcp-foundation-plan";
          meta.description = "Render infra/gcp/foundation.nix (terranix) and tofu PLAN the GCP APIs, automation identity and state bucket — read-only (needs ADC)";
        };
        gcp-foundation-apply = {
          type = "app";
          program = "${config.packages.gcp-foundation-apply}/bin/gcp-foundation-apply";
          meta.description = "tofu apply the GCP foundation — enabled APIs, the impersonated automation service account, and the OpenTofu state bucket (needs ADC)";
        };
        gcp-budget-plan = {
          type = "app";
          program = "${config.packages.gcp-budget-plan}/bin/gcp-budget-plan";
          meta.description = "Render infra/gcp/budget.nix (terranix) and tofu PLAN the GCP spend ALERT — read-only (needs ADC, not an API token)";
        };
        gcp-budget-apply = {
          type = "app";
          program = "${config.packages.gcp-budget-apply}/bin/gcp-budget-apply";
          meta.description = "tofu apply the GCP billing budget — an ALERT at thresholds, NOT a spending cap; Google offers no hard cap (needs ADC)";
        };
        cf-zones-plan = {
          type = "app";
          program = "${config.packages.cf-zones-plan}/bin/cf-zones-plan";
          meta.description = "Render infra/cloudflare/zones.nix (terranix) and tofu PLAN kattakath.com's DNS records — read-only, run it before cf-zones-apply (needs CLOUDFLARE_API_TOKEN)";
        };
        cf-access-org-import = {
          type = "app";
          program = "${config.packages.cf-access-org-import}/bin/cf-access-org-import";
          meta.description = "Import the EXISTING Cloudflare Zero Trust organisation into state — read-only at Cloudflare, and the mandatory first step before any cf-access-org plan or apply (needs CLOUDFLARE_API_TOKEN)";
        };
        cf-access-org-plan = {
          type = "app";
          program = "${config.packages.cf-access-org-plan}/bin/cf-access-org-plan";
          meta.description = "Render infra/cloudflare/access-org.nix (terranix) and tofu PLAN the Access organisation + login-page branding — read-only; it must report NO changes (needs CLOUDFLARE_API_TOKEN)";
        };
        cf-access-org-apply = {
          type = "app";
          program = "${config.packages.cf-access-org-apply}/bin/cf-access-org-apply";
          meta.description = "tofu apply the Access organisation — refuses an un-imported state, an auth_domain change, and any attribute state holds that the render omits (an omission here DELETES it); -auto-approve is rejected (needs CLOUDFLARE_API_TOKEN)";
        };
        cf-zones-apply = {
          type = "app";
          program = "${config.packages.cf-zones-apply}/bin/cf-zones-apply";
          meta.description = "tofu apply kattakath.com's DNS records (mail included) — refuses a shrunken render, an empty state, or any dropped record (needs CLOUDFLARE_API_TOKEN)";
        };
        mcp-public-sync = {
          type = "app";
          program = "${config.packages.mcp-public-sync}/bin/mcp-public-sync";
          meta.description = "Ask Cloudflare to re-poll every published MCP server NOW (POST .../servers/{id}/sync) — run it after `activate`, since the proxy refuses connections for ~33s while it spawns and anything polled in that window latches status=error (needs CLOUDFLARE_API_TOKEN)";
        };
        mcp-public-token = {
          type = "app";
          program = "${config.packages.mcp-public-token}/bin/mcp-public-token";
          meta.description = "Print ONLY the published-gateway connector token to stdout, for piping into `secret set` (needs CLOUDFLARE_API_TOKEN)";
        };
        mcp-public-destroy = {
          type = "app";
          program = "${config.packages.mcp-public-destroy}/bin/mcp-public-destroy";
          meta.description = "tofu destroy the published MCP gateway stack — NOTE the provider cannot destroy the tunnel config or the portal registrations, which survive in the API and need deleting by hand (needs CLOUDFLARE_API_TOKEN)";
        };
        cf-tunnel-destroy = {
          type = "app";
          program = "${config.packages.cf-tunnel-destroy}/bin/cf-tunnel-destroy";
          meta.description = "tofu destroy the nixpi Cloudflare tunnel/ingress/CNAME (needs CLOUDFLARE_API_TOKEN)";
        };
      };
    };
}
