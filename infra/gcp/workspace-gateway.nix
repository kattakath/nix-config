# ---- Kattakath Workspace gateway: Pomerium on Cloud Run (terranix -> OpenTofu) --
#
# WHY IT EXISTS: claude.ai reaches only REMOTE MCP servers, and Google's own hosted
# Workspace MCP servers (gmailmcp/calendarmcp/... .googleapis.com) each want a Google
# OAuth client of their own. Pomerium's MCP mode fronts all of them: claude.ai signs
# in to Pomerium once (Google IdP, one email allowed), and Pomerium holds each
# upstream's Google token. Configuration only, no code of ours: the OFFICIAL image,
# this file, and the routes in Secret Manager.
#
# REPLACES NOTHING LIVE. The earlier gcp-workspace-mcp stack (a different server,
# taylorwilsdon/google_workspace_mcp) was reverted 2026-11-07 and its objects torn
# down: run + artifactregistry were DISABLED (audit log), its state prefix is gone
# from the bucket. So this is a clean CREATE, not an adoption — no import blocks.
# Its recorded traps are reused below where they still apply.
#
# DECISIONS (operator, 2026-11-14), one line of why each:
#   - Cloud Run, REQUEST-BASED billing (`cpu_idle`): CPU bills only while a request
#     is open, so an idle gateway costs nothing inside the free tier.
#   - min 0 / max 1 instances: scale to zero for cost; max 1 because the file token
#     store must never have two writers.
#   - us-central1: the region the state bucket already uses, and one of the three
#     (us-central1/us-east1/us-west1) where the 5 GB Cloud Storage free tier applies.
#   - NO Alloy metrics sidecar: Cloud Run's built-in Cloud Monitoring metrics cover
#     the platform. TODO: read them from Grafana's Google Cloud Monitoring datasource
#     (infra/grafana), not added in this change.
#   - Logs: Pomerium writes to stdout, which Cloud Run ships to Cloud Logging with
#     no agent and no grant.
#   - Usage reporting OFF: `runtime_flags.product_analytics = false`, the only gate
#     in v0.34.1's source.
#
# DATABROKER: `file` (pebble) on a GCS volume at /data, NOT postgres.
#   Why: no new credential (a postgres DSN would be a 4th Secret Manager secret,
#   6/6 on the free tier), no new vendor, $0. Memory storage is out: with min 0,
#   every cold start would drop every session and every upstream token, so each
#   app would re-ask for Google consent.
#   WEAKEST ASSUMPTION: pebble was measured on a LOCAL directory in the spike, never
#   on Cloud Storage FUSE. gcsfuse offers no flock and rewrites whole objects, and
#   Google's Cloud Run docs warn against databases on a GCS volume. max 1 instance
#   removes concurrent writers, but a revision rollout can briefly run the old and
#   new instance together. Verify on the first deploy (sign in, force a cold start,
#   confirm the upstream tokens survive). The fallback is postgres (Neon) with its
#   DSN as the 4th secret.
#
# SECRETS: THREE Secret Manager secrets. Measured 2026-11-14: the billing account
# holds 2 billable versions (both in this project; jsonresume-connect has Secret
# Manager disabled), so three makes 5 of the free 6 and leaves `secrets-push`
# (keychain-secrets, capped at 6) one slot.
#   workspace-gateway-policy          env POLICY: base64 of the routes YAML. Routes
#       must come in whole because upstream_oauth2.client_secret has no *_file key.
#   workspace-gateway-idp-client-secret  env IDP_CLIENT_SECRET. The SAME Google value
#       as inside POLICY.
#   workspace-gateway-key             env SHARED_SECRET and env COOKIE_SECRET, one
#       value. Precedent: upstream does exactly this itself in all-in-one mode — both
#       getters fall back to the one `randomSharedKey` (config/options.go,
#       GetSharedKey and GetCookieSecret). They must not be left unset here: that
#       random key is regenerated per process, and with min 0 every cold start is a
#       new process, so every cookie and every stored token would be lost.
#   REJECTED: four secrets (6/6, no headroom for secrets-push); the keys as files in
#   the data bucket (the key would sit beside the data it protects).
#
# THIS STACK WRITES POLICY AND IDP_CLIENT_SECRET ITSELF, through WRITE-ONLY
# attributes (`secret_data_wo`, google 8.4.0; OpenTofu >= 1.11, the pin is 1.13.1).
# A write-only value is sent to the API and never stored in plan or state, which
# is the reason the reverted gcp-workspace-mcp stack kept values out of tofu — so
# that reason no longer holds, and the routes and allowlist stay declared here.
# The client secret is an EPHEMERAL variable for the same reason.
#   Versions REPLACE on change (`secret_data_wo_version` is ForceNew in v8.4.0), so
#   the old version is destroyed and the free-tier count stays at one per secret.
#   create_before_destroy keeps `latest` from being empty in between, and the
#   service PINS these two versions rather than `latest`: env secrets are read only
#   at instance start, so a pin is what rolls a new revision and makes a removed
#   email lose access at once instead of at the next scale-to-zero.
#   POLICY's version is a hash of every non-ephemeral input (routes, client id,
#   allowlist, generation), so adding an email rewrites it on the next apply. The
#   client secret is ephemeral and cannot be hashed: after ROTATING it, bump
#   `client_secret_generation`, which rewrites both secrets.
#
# FAMILY-ONLY ACCESS (operator, 2026-11-14): every route allows exactly the emails
# in `gateway_allowed_emails`, a sensitive list variable fed from the Keychain, so
# the names never reach this public repo. Today it holds only the operator's own
# Workspace email. ADDING A FAMILY MEMBER: add their email to that Keychain item
# (a JSON list) and re-apply; each person then adds the connectors from their OWN
# Claude account and signs in as themselves.
#
# FIRST APPLY IS TWO-STEP for the key alone, because a Cloud Run revision will not
# start on a secret with no version (Cloud Run resolves `latest` at deploy):
#   1. nix develop -c nix run .#gcp-foundation-apply    (run + artifactregistry APIs)
#   2. the key's container alone, with the three TF_VARs (the credential check needs
#      them) and the empty-state override (it refuses any apply on empty state):
#        secret exec <the three TF_VARs> -- env GCP_WORKSPACE_GATEWAY_ALLOW_CREATE=1 \
#          nix run .#gcp-workspace-gateway-apply -- -target=google_secret_manager_secret.workspace_gateway_key
#   3. add the key (below), then `-plan -- -out=<f>` (23 add) and `-apply -- <f>`.
#   A FIRST REVISION THAT FAILS (bad POLICY, pebble on gcsfuse) is not fixed by
#   re-running apply: deletion_protection refuses the replace. Read Cloud Logging
#   and fix the render; recovery may need an import block.
# The key stays out of tofu because it is re-issuable randomness with no other
# home: regenerating it costs one sign-in per person, so it needs no Keychain copy.
#   32 random bytes, base64, NO trailing newline (GetSharedKey refuses whitespace),
#   piped, never printed, inside `nix develop` with CLOUDSDK_CONFIG=~/.config/gcloud-nix-config:
#     openssl rand -base64 32 | tr -d '\n' | gcloud secrets versions add workspace-gateway-key --data-file=-
#   A rotation is a 6th billable version until the old one is destroyed:
#   `gcloud secrets versions destroy <n> --secret=workspace-gateway-key`.
#
# WHAT TERRAFORM CANNOT HOLD (google 8.4.0, unchanged since gcp-workspace-mcp):
#   - the Google Auth Platform OAuth client and its redirect URIs. The URIs it needs
#     are this stack's `oauth_redirect_uris` output; add them in the console.
#   - domain ownership in Search Console. Cloud Run domain mappings need kattakath.com
#     verified for the applying account; its DNS_TXT proof is cf-zones' txt_apex_4,
#     kept when gcp-workspace-mcp was reverted.
#   - the key's value (above) and the claude.ai custom connectors (one per app host).
#
# Runs as the OPERATOR through ADC, like gcp-foundation and for its reason: this
# stack creates a service account and grants it IAM, which the automation account
# must not be able to do for itself.
{
  lib,
  projectId,
  # The gateway's base domain, today the zone itself (apex hosts); terranix.nix owns it.
  gatewayDomain,
  # infra/gcp/workspace-gateway-apps.nix, one entry per app host.
  apps,
  # Pomerium's sign-in host label, from the same file.
  authenticateLabel,
  ...
}:
let
  region = "us-central1";
  service = "workspace-gateway";
  # A REFERENCE, not the literal email: a literal gives OpenTofu no dependency, so the
  # IAM members raced the account's creation ("does not exist", first apply 2026-11-14).
  saMember = "serviceAccount:\${google_service_account.gateway.email}";
  bucket = "kattakath-${service}";
  authHost = "${authenticateLabel}.${gatewayDomain}";

  # The OFFICIAL image, pinned by DIGEST: the v0.34.1 OCI index (linux/amd64 +
  # linux/arm64), read from registry-1.docker.io 2026-11-14. Pulled through the
  # Docker Hub remote repository below, because Cloud Run cannot pull docker.io.
  image = "${region}-docker.pkg.dev/${projectId}/dockerhub/pomerium/pomerium@sha256:386ba3b0b83b43146e3524f7579f02106ac36016aae06cd8af20af4880035a2f";

  # ---- Pomerium config.yaml (non-secret) ------------------------------------
  # Rendered as JSON, which is valid YAML, into the data bucket and read through the
  # mount. Every key here was exercised in the 2026-11-14 spike except the
  # databroker path and the otel keys. Nothing per-person: the client id arrives as
  # env IDP_CLIENT_ID (Pomerium binds every key to its upper-cased env name,
  # bindEnvsRecursive in config/options.go), and the routes are the POLICY secret.
  pomeriumConfig = lib.filterAttrs (_: v: v != null) {
    address = ":8080";
    # Cloud Run terminates TLS and forwards plain HTTP to the container.
    insecure_server = true;
    authenticate_service_url = "https://${authHost}";
    idp_provider = "google";
    databroker_storage_type = "file";
    databroker_storage_connection_string = "file:///data/databroker";
    # Only claude.ai may register as an MCP client (Client ID Metadata Documents).
    mcp_allowed_client_id_domains = [ "claude.ai" ];
    runtime_flags.product_analytics = false;
    log_level = "info";
    # TRACES: "none" until Grafana Cloud's OTLP endpoint and token are wired. TODO:
    # set "otlp", the endpoint below, and `otel_exporter_otlp_headers` carrying the
    # token — which would be a 4th secret (6/6), so it waits on a decision. A
    # placeholder endpoint would log an export failure per batch instead.
    # Under request-based billing the batch exporter can stall between requests
    # (CPU is throttled), so spans may arrive late or be lost at scale-down:
    # accepted.
    otel_traces_exporter = "none";
    otel_exporter_otlp_endpoint = null;
  };
  configText = builtins.toJSON pomeriumConfig;

  hosts = [ authHost ] ++ map (app: "${app}.${gatewayDomain}") (lib.attrNames apps);

  # ---- Routes (POLICY) ------------------------------------------------------
  # Shape measured in the 2026-11-14 spike. Three values are tofu VARIABLES, not
  # Nix, and are spliced in as HCL below: the client id (per-person data), the
  # client secret (ephemeral) and the allowlist (family data). Everything else is
  # this repo's.
  sentinel = {
    clientId = "@@CLIENT_ID@@";
    clientSecret = "@@CLIENT_SECRET@@";
    allow = "@@ALLOW@@";
  };
  routes = lib.mapAttrsToList (app: a: {
    id = "kattakath-${app}";
    name = "Kattakath ${a.title}";
    from = "https://${app}.${gatewayDomain}";
    to = "https://${a.upstream}";
    mcp.server = {
      path = "/mcp/v1";
      upstream_oauth2 = {
        client_id = sentinel.clientId;
        client_secret = sentinel.clientSecret;
        inherit (a) scopes;
        endpoint = {
          auth_url = "https://accounts.google.com/o/oauth2/auth";
          token_url = "https://oauth2.googleapis.com/token";
        };
        # offline + consent: Google returns a refresh token only on a consent screen.
        authorization_url_params = {
          access_type = "offline";
          prompt = "consent";
        };
      };
    };
    # `or`, one clause per allowed email (operator decision, header).
    policy.allow."or" = sentinel.allow;
  }) apps;
  # toJSON output is also a valid HCL expression (HCL object constructors accept
  # `"key": value`), so the sentinels can be swapped for HCL references. The routes
  # carry no `${` or `%{`, so nothing else in them is read as a template.
  routesTemplate = builtins.toJSON routes;
  routesHcl =
    assert lib.assertMsg (
      !(lib.hasInfix "\${" routesTemplate || lib.hasInfix "%{" routesTemplate)
    ) "workspace-gateway: a route contains a template sequence";
    lib.replaceStrings
      [
        ''"${sentinel.clientId}"''
        ''"${sentinel.clientSecret}"''
        ''"${sentinel.allow}"''
      ]
      [
        "var.google_oauth_client_id"
        "var.google_oauth_client_secret"
        "[for e in var.gateway_allowed_emails : { email = { is = e } }]"
      ]
      routesTemplate;
  tfName = lib.replaceStrings [ "-" "." ] [ "_" "_" ];

  # The secrets whose versions this stack writes (write-only); the key is added by hand.
  written = [
    "${service}-policy"
    "${service}-idp-client-secret"
  ];

  # Secret id -> the env vars it feeds. One secret may feed two (the key).
  secrets = {
    "${service}-policy" = [ "POLICY" ];
    "${service}-idp-client-secret" = [ "IDP_CLIENT_SECRET" ];
    "${service}-key" = [
      "SHARED_SECRET"
      "COOKIE_SECRET"
    ];
  };
in
{
  terraform.required_providers.google = {
    source = "hashicorp/google";
    version = "= ${(import ../provider-pins.nix).google}";
  };

  provider.google = {
    project = projectId;
    inherit region;
  };

  # Per-person data (no data in the repo): the OAuth client id, fed at plan time by
  # `secret exec TF_VAR_google_oauth_client_id=gcp:workspace-gateway:oauth-client-id`.
  # Not a secret — it is in every authorize URL — so not `sensitive`.
  variable = {
    google_oauth_client_id = {
      type = "string";
      description = "Google OAuth client id (Web) the gateway signs users in with and that each route uses upstream.";
    };
    # Ephemeral: never written to a plan file or state. Only write-only attributes
    # may read it.
    google_oauth_client_secret = {
      type = "string";
      sensitive = true;
      ephemeral = true;
      description = "That client's secret, written into POLICY and IDP_CLIENT_SECRET only.";
    };
    # Family data, so never in the repo, and sensitive so a plan does not print it.
    # No default: an apply that forgot it must fail, not shrink the allowlist.
    gateway_allowed_emails = {
      type = "list(string)";
      sensitive = true;
      description = "Every email allowed through every route. Adding one = edit the Keychain item and re-apply.";
    };
    client_secret_generation = {
      type = "number";
      default = 1;
      description = "Bump after rotating the OAuth client secret: rewrites POLICY and IDP_CLIENT_SECRET.";
    };
  };

  resource = {
    google_artifact_registry_repository.dockerhub = {
      location = region;
      repository_id = "dockerhub";
      format = "DOCKER";
      mode = "REMOTE_REPOSITORY";
      description = "Pull-through proxy for Docker Hub (the official pomerium image)";
      remote_repository_config.docker_repository.public_repository = "DOCKER_HUB";
    };

    google_storage_bucket.gateway = {
      name = bucket;
      location = lib.toUpper region;
      storage_class = "STANDARD";
      uniform_bucket_level_access = true;
      public_access_prevention = "enforced";
      # It holds every upstream refresh token (the databroker).
      force_destroy = false;
      # Soft delete OFF: pebble rewrites and deletes files on every compaction, and
      # the 7-day default would keep each deleted version as billable bytes.
      soft_delete_policy.retention_duration_seconds = 0;
    };

    google_storage_bucket_object.config = {
      # Reference, not the name: orders the upload after the bucket exists (same race).
      bucket = "\${google_storage_bucket.gateway.name}";
      name = "config/config.yaml";
      content = configText;
      content_type = "application/yaml";
    };

    google_service_account.gateway = {
      account_id = service;
      display_name = "Workspace gateway (Pomerium) on Cloud Run";
      description = "No keys. Reads its 3 secrets and the ${bucket} bucket, nothing else (infra/gcp/workspace-gateway.nix).";
    };

    google_storage_bucket_iam_member.gateway = {
      bucket = "\${google_storage_bucket.gateway.name}";
      role = "roles/storage.objectUser";
      member = saMember;
    };

    google_secret_manager_secret = lib.mapAttrs' (id: _envs: {
      name = tfName id;
      value = {
        secret_id = id;
        replication.auto = { };
      };
    }) secrets;

    google_secret_manager_secret_iam_member = lib.mapAttrs' (id: _envs: {
      name = tfName id;
      value = {
        secret_id = "\${google_secret_manager_secret.${tfName id}.id}";
        role = "roles/secretmanager.secretAccessor";
        member = saMember;
      };
    }) secrets;

    # The two client-secret-bearing values, written through write-only attributes.
    google_secret_manager_secret_version = {
      ${tfName "${service}-policy"} = {
        secret = "\${google_secret_manager_secret.${tfName "${service}-policy"}.id}";
        secret_data_wo = "\${base64encode(jsonencode(${routesHcl}))}";
        secret_data_wo_version = "\${parseint(substr(sha256(jsonencode([${builtins.toJSON (builtins.hashString "sha256" routesTemplate)}, var.google_oauth_client_id, var.gateway_allowed_emails, var.client_secret_generation])), 0, 8), 16)}";
        lifecycle.create_before_destroy = true;
      };
      ${tfName "${service}-idp-client-secret"} = {
        secret = "\${google_secret_manager_secret.${tfName "${service}-idp-client-secret"}.id}";
        secret_data_wo = "\${var.google_oauth_client_secret}";
        secret_data_wo_version = "\${var.client_secret_generation}";
        lifecycle.create_before_destroy = true;
      };
    };

    google_cloud_run_v2_service.gateway = {
      name = service;
      location = region;
      ingress = "INGRESS_TRAFFIC_ALL";
      deletion_protection = true;
      template = {
        service_account = "\${google_service_account.gateway.email}";
        # GCS volumes need the second-generation environment.
        execution_environment = "EXECUTION_ENVIRONMENT_GEN2";
        timeout = "300s";
        max_instance_request_concurrency = 80;
        scaling = {
          min_instance_count = 0;
          max_instance_count = 1;
        };
        # A changed config.yaml rolls a new revision. gcsfuse delivers no file-change
        # events, so a running Pomerium would otherwise keep the old config.
        labels.config-sha = builtins.substring 0 16 (builtins.hashString "sha256" configText);
        volumes = [
          {
            name = "data";
            gcs = {
              inherit bucket;
              read_only = false;
            };
          }
        ];
        containers = [
          {
            inherit image;
            # The image's CMD is `--config /pomerium/config.yaml` (an empty file).
            args = [
              "--config"
              "/data/config/config.yaml"
            ];
            ports.container_port = 8080;
            resources = {
              limits = {
                cpu = "1";
                # Pomerium embeds Envoy; 1 GiB is headroom, not a measurement.
                memory = "1Gi";
              };
              startup_cpu_boost = true;
              # Request-based billing: CPU only while a request is in flight.
              cpu_idle = true;
            };
            volume_mounts = [
              {
                name = "data";
                mount_path = "/data";
              }
            ];
            env = [
              {
                name = "IDP_CLIENT_ID";
                value = "\${var.google_oauth_client_id}";
              }
            ]
            ++ lib.concatLists (
              lib.mapAttrsToList (
                id: envs:
                map (name: {
                  inherit name;
                  value_source.secret_key_ref = {
                    secret = id;
                    # Pinned where tofu writes the version (header); `latest` for the key.
                    version =
                      if builtins.elem id written then
                        "\${google_secret_manager_secret_version.${tfName id}.version}"
                      else
                        "latest";
                  };
                }) envs
              ) secrets
            );
          }
        ];
      };
      # gcloud stamps these on every deploy; they are not configuration.
      lifecycle.ignore_changes = [
        "client"
        "client_version"
      ];
      depends_on = [
        "google_secret_manager_secret_version.${tfName "${service}-policy"}"
        "google_secret_manager_secret_version.${tfName "${service}-idp-client-secret"}"
        "google_secret_manager_secret_iam_member.${tfName "${service}-policy"}"
        "google_secret_manager_secret_iam_member.${tfName "${service}-idp-client-secret"}"
        "google_secret_manager_secret_iam_member.${tfName "${service}-key"}"
        "google_storage_bucket_iam_member.gateway"
        "google_storage_bucket_object.config"
      ];
    };

    # Public on purpose: Pomerium is the gate (one allowed email per route), and
    # claude.ai cannot present a Google identity token to Cloud Run.
    google_cloud_run_v2_service_iam_member.public_invoker = {
      name = "\${google_cloud_run_v2_service.gateway.name}";
      location = region;
      role = "roles/run.invoker";
      member = "allUsers";
    };

    # One mapping per host. Each needs the domain verified (header) and its DNS-only
    # CNAME to ghs.googlehosted.com (cf-zones, from the same apps list).
    google_cloud_run_domain_mapping = lib.listToAttrs (
      map (host: {
        name = tfName host;
        value = {
          name = host;
          location = region;
          metadata.namespace = projectId;
          spec.route_name = "\${google_cloud_run_v2_service.gateway.name}";
          # Re-creating one re-provisions its managed cert from scratch: no TLS until done.
          deletion_policy = "PREVENT";
        };
      }) hosts
    );
  };

  # The OAuth client is not terraformable: these go into its "Authorized redirect
  # URIs" by hand. Pomerium's own sign-in, then one MCP client callback per app host.
  output.oauth_redirect_uris.value = [
    "https://${authHost}/oauth2/callback"
  ]
  ++ map (app: "https://${app}.${gatewayDomain}/.pomerium/mcp/client/oauth/callback") (
    lib.attrNames apps
  );
  output.service_uri.value = "\${google_cloud_run_v2_service.gateway.uri}";
}
