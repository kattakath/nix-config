# ---- terranix (Nix -> OpenTofu JSON) and the three tofu app families --------
#
# Renderers + `writeShellApplication` wrappers, moved verbatim from flake.nix's
# `let` (ADR-002 wave 2). Every guard here — the site-free refusal, the
# unpublish refusal, the pinned 0700 state directory — is a recorded incident,
# not hygiene; none of it is rewritten, only rehomed.
#
# `cfTunnelConfig` / `mcpPublicConfig` / `terranixRender` join `flake.lib`
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
    ;

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
  # the second mcp-proxy (127.0.0.1:8097), the proxied CNAME, ONE Access
  # application gated by a SERVICE TOKEN, and one portal registration per
  # published server.
  #
  # `publicServers` MUST mirror `services.mcpGateway.public`. It is passed
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
        {
          _module.args = {
            inherit
              domainName
              publicServers
              publicSubdomain
              externalServers
              ;
            accountId = cloudflareAccountId;
            zoneId = cloudflareZoneId;
          };
        }
      ];
    };

  # ---- Generic terranix renderer for external/private callers -----------
  # A raw wrapper around this flake's own pinned `terranix` input -- lets a
  # private composition flake render ITS OWN terranix module (e.g. a
  # different Cloudflare account's tunnel stack) without needing its own
  # terranix flake input. No site-specific content lives here; this is
  # purely a library primitive, mirroring cfTunnelConfig's own closure
  # trick but fully generic (any modules list, any system).
  terranixRender =
    { system, modules }:
    terranix.lib.terranixConfiguration {
      inherit system modules;
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
      runtimeInputs = [ pkgs.opentofu ];
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
        # where the app is invoked from. NOTE: this state contains the tunnel
        # CONNECTOR TOKEN in plaintext (it is a `data` source result), so the
        # directory is created 0700 and must never be committed or synced.
        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-cf-tunnel"
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        cd "$state_dir"
        # 0600 on everything tofu writes from here on. Verified: the state file
        # really does carry
        # cloudflare_zero_trust_tunnel_cloudflared_token.nixpi.token, so this is
        # load-bearing, not hygiene. umask covers files tofu creates itself.
        umask 077
        chmod 600 terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
        echo "tofu working directory: $state_dir" >&2

        rm -f config.tf.json
        cp ${cfTunnelConfig { inherit system; }} config.tf.json

        # SITE-FREE GUARD — the twin of the `deploy` trap.
        # The public repo's cf-tunnel apps call cfTunnelConfig with no
        # `hostedSites` (it defaults to [ ]), which renders a tunnel whose
        # ingress is SSH + the catch-all 404 and NO site DNS/redirects. A
        # successful apply of that would take every site dark and delete the
        # records/rulesets from state, while reporting SUCCESS. The real site
        # list lives in the private nix-personal flake; run it from there.
        # One ingress entry == SSH only; two == SSH + catch-all, still site-free.
        ingress_count=$(
          ${pkgs.jq}/bin/jq '
            [.resource.cloudflare_zero_trust_tunnel_cloudflared_config.nixpi.config.ingress[]?]
            | length' config.tf.json
        )
        if [ "''${ingress_count:-0}" -le 2 ]; then
          echo "REFUSING: rendered config is SITE-FREE (ingress entries: ''${ingress_count})." >&2
          echo "  This is the public tree, where hostedSites defaults to [ ]." >&2
          echo "  Applying it would blank the live tunnel's ingress and delete" >&2
          echo "  every site CNAME + www->apex ruleset that is in state." >&2
          echo "  Run the cf-tunnel apps from the PRIVATE nix-personal flake instead." >&2
          echo "  Override only if you genuinely mean a site-free tunnel:" >&2
          echo "    CF_TUNNEL_ALLOW_SITE_FREE=1 ${name}" >&2
          [ "''${CF_TUNNEL_ALLOW_SITE_FREE:-}" = "1" ] || exit 1
          echo "WARNING: CF_TUNNEL_ALLOW_SITE_FREE=1 set — proceeding site-free." >&2
        fi

        tofu init
        # "$@" is forwarded LAST so a caller can add flags (-auto-approve,
        # -target, -refresh=false) without a second app. It cannot weaken the
        # guards above: those run before tofu is invoked at all, and refusing
        # exits the script rather than falling through to this line.
        tofu ${action} "$@"
      ''
      + nixpkgs.lib.optionalString (action == "apply") printToken;
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
        echo "  secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:api -- \\"
        echo "    nix run .#mcp-public-token | secret set cf:cloudflare.com:mcp-connector"
        echo ""
        echo "Then set services.mcpGateway.public (from nix-personal) and activate."
      '';
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.opentofu ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          echo "  secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:api -- ${name}" >&2
          echo "  (needs Account > Cloudflare Tunnel:Edit + Access: Apps and Policies:Edit," >&2
          echo "   Access: Service Tokens:Edit, and Zone > DNS:Edit on ${domainName})" >&2
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
        tofu init

        # GUARD — the twin of the site-free trap, shaped for THIS stack.
        # The public tree renders publicServers = [ ], which is correct for the
        # FIRST apply (create the tunnel and Access objects before publishing
        # anything). It is destructive later: applying an empty render over
        # state that already holds registrations DELETES them, un-publishing
        # every server while reporting success. Refuse exactly that case.
        rendered=$(${pkgs.jq}/bin/jq '
          [.resource.cloudflare_zero_trust_access_ai_controls_mcp_server // {} | keys[]]
          | length' config.tf.json)
        in_state=$(tofu state list 2>/dev/null \
          | grep -c '^cloudflare_zero_trust_access_ai_controls_mcp_server\.' || true)
        if [ "''${rendered:-0}" -eq 0 ] && [ "''${in_state:-0}" -gt 0 ]; then
          echo "REFUSING: this render publishes 0 servers but state holds ''${in_state}." >&2
          echo "  Applying would UNPUBLISH every one of them." >&2
          echo "  This is the public tree, where publicServers defaults to [ ]." >&2
          echo "  Pass the real list (it must mirror services.mcpGateway.public)," >&2
          echo "  or override if you genuinely mean to unpublish everything:" >&2
          echo "    MCP_PUBLIC_ALLOW_EMPTY=1 ${name}" >&2
          [ "''${MCP_PUBLIC_ALLOW_EMPTY:-}" = "1" ] || exit 1
          echo "WARNING: MCP_PUBLIC_ALLOW_EMPTY=1 — unpublishing all servers." >&2
        fi

        # See the note on the nixpi builder: forwarded last, cannot weaken the
        # guard above, which exits before reaching here.
        tofu ${action} "$@"
      ''
      + nixpkgs.lib.optionalString (action == "apply") printToken;
    };

  # Prints ONLY the raw connector token to stdout — nothing else, no banner —
  # so it composes: `… | secret set cf:cloudflare.com:mcp-connector`. The value
  # never reaches a terminal, scrollback, the clipboard, or a transcript.
  # Read-only: it runs `tofu output`, never plan or apply.
  mkMcpPublicToken =
    { system }:
    let
      pkgs = pkgsFor system;
    in
    pkgs.writeShellApplication {
      name = "mcp-public-token";
      runtimeInputs = [ pkgs.opentofu ];
      text = ''
        if [ -z "''${CLOUDFLARE_API_TOKEN:-}" ]; then
          echo "ERROR: CLOUDFLARE_API_TOKEN is unset." >&2
          exit 1
        fi
        state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-mcp-public"
        if [ ! -f "$state_dir/terraform.tfstate" ]; then
          echo "ERROR: no state at $state_dir — run mcp-public-apply first." >&2
          exit 1
        fi
        cd "$state_dir"
        # -raw, no trailing banner: stdout is exactly the token.
        tofu output -raw mcp_public_connector_token
      '';
    };

in
{
  # The renderers, exported for private/external callers (see the header).
  flake.lib = {
    inherit
      cfTunnelConfig
      mcpPublicConfig
      terranixRender
      ;
  };

  perSystem =
    { config, system, ... }:
    {
      # Cloudflare tunnel provisioning apps (terranix -> OpenTofu), exposed as
      # packages too so `nix flake check` builds them and runs the
      # writeShellApplication shellcheck on each wrapper.
      packages = {
        cf-tunnel-apply = mkCfTunnelTofu {
          inherit system;
          name = "cf-tunnel-apply";
          action = "apply";
        };
        mcp-public-apply = mkMcpPublicTofu {
          inherit system;
          name = "mcp-public-apply";
          action = "apply";
        };
        mcp-public-token = mkMcpPublicToken { inherit system; };
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
