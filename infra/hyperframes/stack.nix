# infra/hyperframes/stack.nix — terranix (Nix → OpenTofu/Terraform JSON)
#
# Generates a thin OpenTofu plan that stamps secrets into the public
# hyperframes-selfhost tree and runs `docker compose up -d --build`.
#
# Dual delivery:
#   • Nix operators:  nix run .#hf-apply   (renders this module → tofu apply)
#   • Non-Nix users:  use packages/hyperframes-selfhost/terraform/main.tf
#                     (hand-maintained twin of this module) or ./install.sh
#
# Runtime stack (all on the Linux VM — never on the Darwin host):
#   Tailscale Funnel → Caddy → mcp-auth-proxy (Google OAuth allowlist) → Kinocut + HyperFrames
#
# Args (from flake.nix _module.args):
#   operatorEmail, stackDir (absolute path to the compose root on the target),
#   externalUrl, tsHostname
{
  operatorEmail,
  stackDir,
  externalUrl ? "",
  tsHostname ? "hyperframes",
  ...
}:
{
  terraform.required_version = ">= 1.6.0";

  terraform.required_providers.null = {
    source = "hashicorp/null";
    version = "~> 3.2";
  };
  terraform.required_providers.local = {
    source = "hashicorp/local";
    version = "~> 2.5";
  };

  # Secrets are NEVER in Nix — they arrive as TF variables / env at apply time.
  variable.ts_authkey = {
    type = "string";
    sensitive = true;
    description = "Tailscale auth key for the VM node";
  };
  variable.google_client_id = {
    type = "string";
    sensitive = true;
  };
  variable.google_client_secret = {
    type = "string";
    sensitive = true;
  };
  variable.google_allowed_users = {
    type = "string";
    description = "Comma-separated allowlisted emails (defaults to operatorEmail when empty at apply)";
    default = operatorEmail;
  };
  variable.external_url = {
    type = "string";
    description = "Public Funnel URL https://<node>.ts.net";
    default = externalUrl;
  };
  variable.stack_dir = {
    type = "string";
    default = stackDir;
    description = "Absolute path to packages/hyperframes-selfhost (or a published clone)";
  };
  variable.ts_hostname = {
    type = "string";
    default = tsHostname;
  };

  locals = {
    root = "\${abspath(var.stack_dir)}";
    env_content = ''
      TS_AUTHKEY=''${var.ts_authkey}
      TS_HOSTNAME=''${var.ts_hostname}
      EXTERNAL_URL=''${var.external_url}
      GOOGLE_CLIENT_ID=''${var.google_client_id}
      GOOGLE_CLIENT_SECRET=''${var.google_client_secret}
      GOOGLE_ALLOWED_USERS=''${var.google_allowed_users}
      WORKSPACE_DIR=./workspace
      CADDY_HTTP_PORT=8080
      MCP_LISTEN=:8090
    '';
  };

  resource.local_sensitive_file.env = {
    filename = "\${local.root}/.env";
    content = "\${local.env_content}";
    file_permission = "0600";
  };

  resource.null_resource.workspace = {
    provisioner.local-exec = {
      command = "mkdir -p '\${local.root}/workspace'";
    };
  };

  resource.null_resource.compose_up = {
    depends_on = [
      "local_sensitive_file.env"
      "null_resource.workspace"
    ];
    triggers = {
      env_sha = "\${sha256(local.env_content)}";
    };
    provisioner.local-exec = {
      working_dir = "\${local.root}";
      command = "docker compose up -d --build";
    };
  };

  output.mcp_url = {
    value = "\${trimsuffix(var.external_url, \"/\")}/mcp";
    description = "MCP connector URL for Claude/Grok/Cursor";
  };
  output.oauth_redirect_uri = {
    value = "\${trimsuffix(var.external_url, \"/\")}/.auth/google/callback";
    description = "Google OAuth Web client redirect URI";
  };
  output.operator_email = {
    value = operatorEmail;
    description = "Default allowlisted operator (from flake identity)";
  };
  output.architecture = {
    value = "Funnel(VM) → Caddy → mcp-auth-proxy(Google) → Kinocut+HyperFrames";
  };
}
