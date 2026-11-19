# ---- The self-hosted MCP servers: Cloud Run upstreams of the Workspace MCP portal ----
#
# Imported by ./foundation.nix (gcp-foundation stack, operator ADC). Every portal app in
# infra/cloudflare/workspace-mcp-apps.nix that carries `selfHosted` gets ONE Cloud Run service here: one tool family, one scope set,
# one blast radius, each scaling to zero. A module of its own because its resource
# types (service accounts) are also declared in foundation.nix, and the module system
# merges the two where one attrset literal could not.
#
# STATELESS, unlike the 2026-11-07 deployment that was rolled back: the portal runs the
# Google sign-in and keeps each user's grant, and forwards the Google access token as a
# Bearer (EXTERNAL_OAUTH21_PROVIDER). Upstream taylorwilsdon/google_workspace_mcp
# validates it against Google's userinfo (auth/external_oauth_provider.py,
# verify_token) and keeps nothing: no bucket, no volume, no client secret.
#
# PUBLIC on purpose, like the portal's Google upstreams: Cloudflare cannot present a
# Google identity token to Cloud Run. Any valid Google token is accepted, and it can
# reach only that token's OWN data; one instance per service caps what a caller costs.
{
  lib,
  projectId,
  projectNumber,
  ...
}:
let
  # Name, region, tool family and read-only flag are owned by the portal's app list, so
  # the URL the portal calls and the service here cannot disagree.
  appList = import ../cloudflare/workspace-mcp-apps.nix;
  selfHosted = lib.mapAttrs (_: a: a.selfHosted) (
    lib.filterAttrs (_: a: a ? selfHosted) appList.apps
  );

  # ONE region for all of them, because they share the one `ghcr` pull-through repo.
  region =
    let
      regions = lib.unique (lib.mapAttrsToList (_: h: h.region) selfHosted);
    in
    assert lib.assertMsg (
      lib.length regions == 1
    ) "self-hosted MCP apps must share one region (one ghcr repo)";
    lib.head regions;

  # Pinned by DIGEST (the 2.5.0 manifest list on ghcr.io, read 2026-11-18), pulled
  # through the `ghcr` remote repo below: Cloud Run cannot pull from ghcr.io directly.
  image = "${region}-docker.pkg.dev/${projectId}/ghcr/taylorwilsdon/google_workspace_mcp@sha256:fa5fd1afc88113b0d67fb69fe770e964bfc5e971142fadf49676738f2c793989";

  # Plain env (nothing secret). Each was measured with 2.5.0 on the Mac 2026-11-18.
  envOf =
    h:
    {
      MCP_ENABLE_OAUTH21 = "true";
      # The portal performs the code exchange and sends the access token as a Bearer.
      EXTERNAL_OAUTH21_PROVIDER = "true";
      # Multi-user, zero disk writes.
      WORKSPACE_MCP_STATELESS_MODE = "true";
      # Required to be non-empty (core/server.py refuses to start without it), never
      # used in this mode: a ya29.* token is checked at userinfo, with no audience test.
      GOOGLE_OAUTH_CLIENT_ID = "unused-in-external-mode.apps.googleusercontent.com";
      # The resource URL its protected-resource metadata advertises.
      WORKSPACE_EXTERNAL_URL = "https://${appList.runAppHost projectNumber h}";
      # The image's CMD turns these two into `--tools` / `--tool-tier` (upstream
      # Dockerfile at v2.5.0). Cloud Run's PORT=8080 is read by core/config.py.
      TOOLS = h.family;
      # `complete`, not the default: e.g. the task-LIST tools are complete-tier only.
      TOOL_TIER = "complete";
    }
    # Registers only read tools and requests only read scopes (main.py, --read-only).
    // lib.optionalAttrs (h.readOnly or false) { WORKSPACE_MCP_READ_ONLY = "true"; };

  # Terraform address of each app's objects; `tasks` keeps the names it was applied with.
  addr = app: "${app}_mcp";

  # The ONE signing-key secret, shared (its id predates the others; renaming would
  # destroy the value). Secret Manager's free tier is 6 active versions, so not one each.
  secret = "\${google_secret_manager_secret.tasks_mcp_jwt_signing_key.secret_id}";

  perApp = f: lib.mapAttrs' (app: h: lib.nameValuePair (addr app) (f app h)) selfHosted;
in
{
  resource = {
    google_artifact_registry_repository.ghcr = {
      project = projectId;
      location = region;
      repository_id = "ghcr";
      format = "DOCKER";
      mode = "REMOTE_REPOSITORY";
      description = "Pull-through proxy for ghcr.io (the self-hosted MCP servers' image)";
      remote_repository_config.common_repository.uri = "https://ghcr.io";
    };

    google_service_account = perApp (
      app: h: {
        project = projectId;
        account_id = h.service;
        display_name = "${app} MCP server (Cloud Run)";
        description = "Runs the ${h.service} service. No project roles: reads only the shared signing-key secret.";
      }
    );

    # Upstream refuses to start without a client secret OR this key ("Public client
    # OAuth 2.1 requires FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY", measured with
    # 2.5.0), and a token that is not ya29.* falls through to a JWT check under it, so it
    # must not be a literal in a public repo. Only the CONTAINER is declared; the value
    # was posted to Secret Manager out of band, so it never reaches state.
    google_secret_manager_secret.tasks_mcp_jwt_signing_key = {
      project = projectId;
      secret_id = "tasks-mcp-jwt-signing-key";
      replication.auto = { };
    };

    google_secret_manager_secret_iam_member = lib.mapAttrs' (
      app: _:
      lib.nameValuePair "${addr app}_jwt_signing_key" {
        project = projectId;
        secret_id = secret;
        role = "roles/secretmanager.secretAccessor";
        member = "serviceAccount:\${google_service_account.${addr app}.email}";
      }
    ) selfHosted;

    google_cloud_run_v2_service = perApp (
      app: h: {
        project = projectId;
        name = h.service;
        location = h.region;
        ingress = "INGRESS_TRAFFIC_ALL";
        # Stateless, so a replace loses nothing; protection would only make a rename a
        # two-step (the 2026-11-07 teardown hit it).
        deletion_protection = false;
        template = {
          service_account = "\${google_service_account.${addr app}.email}";
          timeout = "300s";
          scaling = {
            min_instance_count = 0;
            max_instance_count = 1;
          };
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
              # The server's own GET /health (core/server.py, custom_route; 200 measured
              # for every family). Cloud Run counts 2xx/3xx as healthy; without a startup
              # probe it falls back to one TCP check per 240 s
              # (docs.cloud.google.com/run/docs/configuring/healthchecks).
              startup_probe = {
                http_get.path = "/health";
                period_seconds = 3;
                timeout_seconds = 2;
                failure_threshold = 20;
              };
              liveness_probe = {
                http_get.path = "/health";
                period_seconds = 30;
                timeout_seconds = 5;
                failure_threshold = 3;
              };
              env = lib.mapAttrsToList (name: value: { inherit name value; }) (envOf h) ++ [
                {
                  name = "FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY";
                  value_source.secret_key_ref = {
                    inherit secret;
                    version = "latest";
                  };
                }
              ];
            }
          ];
        };
        # The image is a plain string, so tofu sees no edge to the repo it comes through.
        depends_on = [
          "google_artifact_registry_repository.ghcr"
          "google_secret_manager_secret_iam_member.${addr app}_jwt_signing_key"
        ];
        # gcloud stamps these on every deploy; they are not configuration.
        lifecycle.ignore_changes = [
          "client"
          "client_version"
        ];
      }
    );

    google_cloud_run_v2_service_iam_member = lib.mapAttrs' (
      app: h:
      lib.nameValuePair "${addr app}_public" {
        project = projectId;
        name = "\${google_cloud_run_v2_service.${addr app}.name}";
        location = h.region;
        role = "roles/run.invoker";
        member = "allUsers";
      }
    ) selfHosted;
  };

  output.mcp_urls.value = lib.mapAttrs (
    app: _: "\${google_cloud_run_v2_service.${addr app}.uri}"
  ) selfHosted;
}
