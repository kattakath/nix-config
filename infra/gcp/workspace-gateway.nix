# ---- Workspace gateway: TOMBSTONE render (2026-11-14) -------------------------
#
# The Pomerium gateway on Cloud Run, its Neon token store, secrets, bucket, service
# account and domain mappings are RETIRED: Cloudflare MCP portals now do the whole job
# (infra/cloudflare/mcp-portals.nix has why). This render declares the providers and
# NO resources, so the stack's next apply DESTROYS everything its state holds (the drop
# guard asks for GCP_WORKSPACE_GATEWAY_ALLOW_DROP=1). Providers stay because tofu needs
# them to delete what state tracks.
#
# After that apply reads "Destroy complete", this file and the stack's wiring in
# modules/parts/terranix.nix are deleted. The full stack is in git history (the commit
# before this one) if it is ever wanted back.
{ projectId, ... }:
{
  terraform.required_providers = {
    google = {
      source = "hashicorp/google";
      version = "= ${(import ../provider-pins.nix).google}";
    };
    neon = {
      source = "kislerdm/neon";
      version = "= ${(import ../provider-pins.nix).neon}";
    };
  };

  provider.google = {
    project = projectId;
    region = "us-central1";
  };
  # Reads NEON_API_KEY.
  provider.neon = { };
}
