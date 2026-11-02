# ---- The ONE place every terranix stack's provider VERSION is pinned ----------
#
# Plain data, imported by each stack's `terraform.required_providers` block and
# rendered as an EXACT constraint (`= <version>`). The SOURCE address stays in each
# stack file and must not change here: a different source is a different provider
# to OpenTofu and needs `tofu state replace-provider`
# (docs/secrets-recovery-and-identity-adr.md).
#
# WHY EXACT, AND WHY HERE. `.terraform.lock.hcl` lives in each stack's state dir,
# outside git (.gitignore), so the lock is not the pin — this file is. Every value
# below is the version `tofu init` had already locked for the live stacks (read
# 2026-11-02: cf-zones + cf-access-org 5.25.0, gcp-foundation + gcp-budget 8.4.0,
# hc-checks 2.3.0), so for those the pin moves nothing — same version, same
# binary, no plan churn. cf-tunnel's lock was NOT read: its state dir is on the
# secret-read deny list (modules/_lib/secret-read-paths.nix). If it is older,
# the next `tofu init` there refuses loudly, before any plan.
#
# WHY NOT nixpkgs `opentofu.withPlugins`, which would make the provider a store path
# instead of a registry download. The pinned nixpkgs' providers.json ships
# cloudflare 5.19.1 and google 7.32.0 — both OLDER than what the live state was
# written with (5.25.0, 8.4.0), google by a whole major — and does not package
# kristofferahl/healthchecksio at all. Adopting it would mean DOWNGRADING the
# providers under existing state, and splitting hc-checks onto a second lane.
# Revisit when nixpkgs' versions reach these (or a bump here is due anyway).
#
# BUMPING ONE: cloudflare is shared by three stacks on purpose (one provider
# version across the account), and infra/cloudflare/access-org.nix's safety
# argument is a reading of THIS version's encoder — re-derive it before raising it.
# A bump changes the constraint, so the next `tofu init` refuses the old lock until
# it is re-run with `-upgrade`.
{
  cloudflare = "5.25.0";
  google = "8.4.0";
  healthchecksio = "2.3.0";
}
