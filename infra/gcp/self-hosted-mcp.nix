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
#
# Not every app is workspace-mcp: `selfHosted.server` picks the image, env and probes
# (`mcp-nixos` since 2026-11-19, a `public` app with no token at all, serving only
# public nixpkgs/NixOS search data). Only workspace-mcp apps read the signing key.
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

  # Which upstream server an app runs (`selfHosted.server`); workspace-mcp unless named.
  serverOf = h: h.server or "workspace-mcp";
  isWorkspace = h: serverOf h == "workspace-mcp";

  # Pinned by DIGEST (each manifest list on ghcr.io, read on the date given), pulled
  # through the `ghcr` remote repo below: Cloud Run cannot pull from ghcr.io directly.
  images = {
    # 2.5.0, read 2026-11-18.
    workspace-mcp = "${region}-docker.pkg.dev/${projectId}/ghcr/taylorwilsdon/google_workspace_mcp@sha256:fa5fd1afc88113b0d67fb69fe770e964bfc5e971142fadf49676738f2c793989";
    # 3.1.1 (amd64 + arm64 manifest list), read 2026-11-19. Upstream's own Nix-built
    # image; its entrypoint is mcp-nixos, configured only by the MCP_NIXOS_* env below.
    mcp-nixos = "${region}-docker.pkg.dev/${projectId}/ghcr/utensils/mcp-nixos@sha256:195c29fe882a00a689a06d6c9e862e7d021905436acca195618ed56cd6413977";
  };

  # Plain env (nothing secret).
  envOf = h: if isWorkspace h then workspaceEnv h else nixosEnv;

  # mcp-nixos (server.py main(), read 2026-11-19 at 3.0.2 and 3.1.1, same names): it ignores Cloud Run's PORT and
  # binds 127.0.0.1:8000 unless told otherwise. Stateless HTTP, because the service scales
  # to zero and a session would not survive it (measured on the Mac: initialize and
  # tools/list both answer with no session id).
  nixosEnv = {
    MCP_NIXOS_TRANSPORT = "http";
    MCP_NIXOS_HOST = "0.0.0.0";
    MCP_NIXOS_PORT = "8080";
    MCP_NIXOS_PATH = "/mcp";
    MCP_NIXOS_STATELESS_HTTP = "true";
  };

  # Each was measured with 2.5.0 on the Mac 2026-11-18.
  workspaceEnv =
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
  # Only workspace-mcp reads the signing key; nothing else gets access to it.
  keyed = lib.filterAttrs (_: isWorkspace) selfHosted;

  # A server with a 200 health route gets HTTP probes on it; one without (mcp-nixos: GET
  # /mcp is 405) gets a TCP check, since Cloud Run counts only 2xx/3xx as healthy.
  probe =
    h: extra:
    let
      hc = appList.healthOf h;
    in
    (if hc.status == 200 then { http_get.path = hc.path; } else { tcp_socket.port = 8080; }) // extra;
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
        description =
          if isWorkspace h then
            "Runs the ${h.service} service. No project roles: reads only the shared signing-key secret."
          else
            "Runs the ${h.service} service. No project roles and no secrets.";
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
    ) keyed;

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
            (
              {
                image = images.${serverOf h};
                ports.container_port = 8080;
                resources = {
                  limits = {
                    cpu = "1";
                    memory = "512Mi";
                  };
                  startup_cpu_boost = true;
                  cpu_idle = true;
                };
                # workspace-mcp's own GET /health (core/server.py, custom_route; 200 measured
                # for every family). Cloud Run counts 2xx/3xx as healthy; without a startup
                # probe it falls back to one TCP check per 240 s
                # (docs.cloud.google.com/run/docs/configuring/healthchecks).
                startup_probe = probe h {
                  period_seconds = 3;
                  timeout_seconds = 2;
                  failure_threshold = 20;
                };
                env =
                  lib.mapAttrsToList (name: value: { inherit name value; }) (envOf h)
                  ++ lib.optional (isWorkspace h) {
                    name = "FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY";
                    value_source.secret_key_ref = {
                      inherit secret;
                      version = "latest";
                    };
                  };
              }
              # Liveness probes take HTTP or gRPC only (same doc), so a server with no 200
              # route runs on the startup probe alone.
              // lib.optionalAttrs ((appList.healthOf h).status == 200) {
                liveness_probe = probe h {
                  period_seconds = 30;
                  timeout_seconds = 5;
                  failure_threshold = 3;
                };
              }
            )
          ];
        };
        # The image is a plain string, so tofu sees no edge to the repo it comes through.
        depends_on = [
          "google_artifact_registry_repository.ghcr"
        ]
        ++ lib.optional (isWorkspace h) "google_secret_manager_secret_iam_member.${addr app}_jwt_signing_key";
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
