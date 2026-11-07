# ---- workspace-mcp: one remote MCP server for every Google service (terranix -> OpenTofu)
#
# WHY IT EXISTS: claude.ai cloud routines can only reach REMOTE MCP servers (custom
# connectors), Google ships no connector for Tasks or Chat, an official connector
# binds ONE Google account, and neither the Mac nor nixpi is always on. One
# deployment serves every account: each claude.ai connector is its own sign-in, and
# claude.ai refuses a duplicate URL, so further accounts add an ignored query tag
# (`/mcp?account=personal`, measured 2026-11-07). So the upstream server the local plugin already runs
# (taylorwilsdon/google_workspace_mcp, MIT) runs here instead, on Cloud Run, behind
# https://workspace.kattakath.com/mcp. Built and measured imperatively on 2026-11-06,
# then codified and ADOPTED by the import blocks below: an import is correct when
# the plan is EMPTY.
#
# WHAT TERRAFORM CANNOT HOLD, and so lives outside this file (google 8.4.0 schema,
# measured 2026-11-06 — no resource exists for any of them):
#   - the Google Auth Platform OAuth client `workspace-mcp` (Web, "AI-powered agent"
#     ticked, redirect https://workspace.kattakath.com/oauth2callback) and the
#     project's consent branding. `google_iap_*` is gone from 8.x, and
#     `google_iam_oauth_client` is Workforce Identity Federation, a different thing.
#   - the Search Console property `sc-domain:<domain>` itself. Its prerequisite,
#     DOMAIN OWNERSHIP, is declared below; the TXT proof is in cf-zones.
#   - the claude.ai custom connector pointing at the URL.
#   - secret VALUES. Only the containers are declared, so no value reaches state.
#
# Runs as the OPERATOR through ADC, like gcp-foundation and for its reason: this
# stack creates a service account and grants IAM, which the automation account must
# not be able to do to itself. ADC needs the `siteverification` scope on top of
# cloud-platform for the web resource below.
{
  lib,
  projectId,
  domainName,
  ...
}:
let
  region = "us-central1";
  service = "workspace-mcp";
  hostname = "workspace.${domainName}";
  externalUrl = "https://${hostname}";
  saEmail = "${service}@${projectId}.iam.gserviceaccount.com";
  bucket = "kattakath-${service}";

  # Pinned by DIGEST (the 2.3.0 manifest list), pulled through the ghcr remote repo
  # below because Cloud Run cannot pull from ghcr.io directly.
  image = "${region}-docker.pkg.dev/${projectId}/ghcr/taylorwilsdon/google_workspace_mcp@sha256:f6729c8497b026911641a7358aabef89a941df2a5327c9fd13cf3dd43e0034b5";

  # The OAuth client ID is not a secret (it is in every authorize URL).
  oauthClientId = "305924238191-5ngfmnj6fijfch9ac3n21nitgcg01l13.apps.googleusercontent.com";

  # Plain env. The upstream image is built WITHOUT the `gcs` extra, so the GCS
  # credential backend crashes at startup (`cannot import name 'storage'`). The
  # bucket is mounted at /data instead, and both stores are directories on it; the
  # OAuth proxy store is Fernet-encrypted with a key derived from the client secret.
  env = {
    MCP_ENABLE_OAUTH21 = "true";
    GOOGLE_OAUTH_CLIENT_ID = oauthClientId;
    WORKSPACE_EXTERNAL_URL = externalUrl;
    GOOGLE_OAUTH_REDIRECT_URI = "${externalUrl}/oauth2callback";
    WORKSPACE_MCP_CREDENTIAL_STORE_BACKEND = "local_directory";
    WORKSPACE_MCP_CREDENTIALS_DIR = "/data/credentials";
    WORKSPACE_MCP_OAUTH_PROXY_STORAGE_BACKEND = "disk";
    WORKSPACE_MCP_OAUTH_PROXY_DISK_DIRECTORY = "/data/oauth-proxy";
    # Unset, any client may register any redirect URI. claude.ai and Claude Code only.
    WORKSPACE_MCP_ALLOWED_CLIENT_REDIRECT_URIS = lib.concatStringsSep "," [
      "https://claude.ai/api/mcp/auth_callback"
      "https://claude.com/api/mcp/auth_callback"
      "http://localhost:*/callback"
    ];
    # Every Google service upstream ships, replacing the official claude.ai Google
    # connectors. `extended` = 87 tools (measured from upstream tool_tiers.yaml at
    # 2.3.0): the official connectors' feature set without the batch/admin extras
    # `complete` adds (119), which every routine would otherwise load.
    TOOLS = "gmail drive calendar docs sheets slides forms chat tasks contacts appscript";
    WORKSPACE_MCP_TOOL_TIER = "extended";
  };

  # Env var -> Secret Manager secret id. Values are added out of band (clipboard ->
  # `gcloud secrets versions add`), never through this stack.
  # ONE secret on purpose. Without FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY the
  # server derives the JWT and storage keys from the client secret
  # (validate_and_derive_jwt_key in upstream core/server.py; a separate key is
  # required only for a public client). A second secret was the 7th active version
  # on the billing account, past the free 6 (the keychain-secrets backend's cap).
  # The cost: rotating the client secret invalidates every stored session.
  secrets = {
    GOOGLE_OAUTH_CLIENT_SECRET = "workspace-mcp-oauth-client-secret";
  };

  tfName = lib.replaceStrings [ "-" ] [ "_" ];
  saMember = "serviceAccount:${saEmail}";
  runId = "projects/${projectId}/locations/${region}/services/${service}";
in
{
  terraform.required_providers.google = {
    source = "hashicorp/google";
    version = "= ${(import ../provider-pins.nix).google}";
  };

  provider.google = {
    project = projectId;
    inherit region;
    # Site Verification refuses user ADC without a quota project (measured 403,
    # "requires a quota project"). Unlike gcp-budget, nothing here impersonates, so
    # the x-goog-user-project header this adds breaks nothing.
    user_project_override = true;
    billing_project = projectId;
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
      "https://www.googleapis.com/auth/userinfo.email"
      "https://www.googleapis.com/auth/siteverification"
    ];
  };

  resource = {
    # ---- Domain ownership ----------------------------------------------------
    # Search Console's sc-domain property and the Cloud Run domain mapping both rest
    # on it. PREVENT: removing this entry must never un-verify the domain.
    google_site_verification_web_resource.domain = {
      site = {
        type = "INET_DOMAIN";
        identifier = domainName;
      };
      verification_method = "DNS_TXT";
      deletion_policy = "PREVENT";
      # The API never returns the method, so an import reads it as null and plans a
      # REPLACEMENT (measured on the first plan). Ignored, it stays documentation.
      lifecycle.ignore_changes = [ "verification_method" ];
    };

    google_artifact_registry_repository.ghcr = {
      location = region;
      repository_id = "ghcr";
      format = "DOCKER";
      mode = "REMOTE_REPOSITORY";
      description = "Pull-through proxy for ghcr.io (workspace-mcp)";
      remote_repository_config.common_repository.uri = "https://ghcr.io";
    };

    google_storage_bucket.workspace_mcp = {
      name = bucket;
      location = lib.toUpper region;
      storage_class = "STANDARD";
      uniform_bucket_level_access = true;
      public_access_prevention = "enforced";
      # It holds every connected account's encrypted refresh tokens.
      force_destroy = false;
    };

    google_service_account.workspace_mcp = {
      account_id = service;
      display_name = "workspace-mcp Cloud Run";
    };

    google_storage_bucket_iam_member.workspace_mcp = {
      inherit bucket;
      role = "roles/storage.objectUser";
      member = saMember;
    };

    google_secret_manager_secret = lib.mapAttrs' (_env: id: {
      name = tfName id;
      value = {
        secret_id = id;
        replication.auto = { };
      };
    }) secrets;

    google_secret_manager_secret_iam_member = lib.mapAttrs' (_env: id: {
      name = tfName id;
      value = {
        secret_id = "projects/${projectId}/secrets/${id}";
        role = "roles/secretmanager.secretAccessor";
        member = saMember;
      };
    }) secrets;

    google_cloud_run_v2_service.workspace_mcp = {
      name = service;
      location = region;
      ingress = "INGRESS_TRAFFIC_ALL";
      deletion_protection = true;
      template = {
        service_account = saEmail;
        execution_environment = "EXECUTION_ENVIRONMENT_GEN2";
        timeout = "300s";
        max_instance_request_concurrency = 80;
        # One instance: the OAuth session map is in memory, so a second would split it.
        scaling = {
          min_instance_count = 0;
          max_instance_count = 1;
        };
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
            ports.container_port = 8080;
            resources = {
              limits = {
                cpu = "1";
                memory = "512Mi";
              };
              startup_cpu_boost = true;
              cpu_idle = true;
            };
            volume_mounts = [
              {
                name = "data";
                mount_path = "/data";
              }
            ];
            env =
              lib.mapAttrsToList (name: value: { inherit name value; }) env
              ++ lib.mapAttrsToList (name: id: {
                inherit name;
                value_source.secret_key_ref = {
                  secret = id;
                  version = "latest";
                };
              }) secrets;
          }
        ];
      };
      # gcloud stamps these on every deploy; they are not configuration.
      lifecycle.ignore_changes = [
        "client"
        "client_version"
      ];
    };

    # Public on purpose: the server's own OAuth 2.1 layer is the gate, and claude.ai
    # cannot present a Google identity token to Cloud Run.
    google_cloud_run_v2_service_iam_member.public_invoker = {
      name = service;
      location = region;
      role = "roles/run.invoker";
      member = "allUsers";
    };

    # Needs the domain verified (above) and the CNAME to ghs.googlehosted.com (cf-zones).
    google_cloud_run_domain_mapping.workspace = {
      name = hostname;
      location = region;
      metadata.namespace = projectId;
      spec.route_name = service;
      # Re-creating it re-provisions the managed cert from scratch: no TLS until done.
      deletion_policy = "PREVENT";
    };
  };

  # ---- Adoption --------------------------------------------------------------
  # Everything above was created imperatively first. OpenTofu skips an import whose
  # address is already in state, so these stay inert after the first apply.
  import = [
    {
      to = "google_site_verification_web_resource.domain";
      id = "webResource/${lib.escapeURL "dns://${domainName}"}";
    }
    {
      to = "google_artifact_registry_repository.ghcr";
      id = "projects/${projectId}/locations/${region}/repositories/ghcr";
    }
    {
      to = "google_storage_bucket.workspace_mcp";
      id = bucket;
    }
    {
      to = "google_service_account.workspace_mcp";
      id = "projects/${projectId}/serviceAccounts/${saEmail}";
    }
    {
      to = "google_storage_bucket_iam_member.workspace_mcp";
      id = "b/${bucket} roles/storage.objectUser ${saMember}";
    }
    {
      to = "google_cloud_run_v2_service.workspace_mcp";
      id = runId;
    }
    {
      to = "google_cloud_run_v2_service_iam_member.public_invoker";
      id = "${runId} roles/run.invoker allUsers";
    }
    {
      to = "google_cloud_run_domain_mapping.workspace";
      id = "locations/${region}/namespaces/${projectId}/domainmappings/${hostname}";
    }
  ]
  ++ lib.concatMap (id: [
    {
      to = "google_secret_manager_secret.${tfName id}";
      id = "projects/${projectId}/secrets/${id}";
    }
    {
      to = "google_secret_manager_secret_iam_member.${tfName id}";
      id = "projects/${projectId}/secrets/${id} roles/secretmanager.secretAccessor ${saMember}";
    }
  ]) (lib.attrValues secrets);
}
