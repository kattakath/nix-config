# ---- The RAG corpus: ONE Cloudflare AI Search instance (stack cf-ai-search) ----------
#
# Operator decision 2026-11-19: the local ragdb corpus (local-rag capsule, pgvector +
# Ollama on the Mac) moves here, so retrieval works on EVERY Claude surface through the
# account-wide claude.ai Cloudflare connector (`execute` -> POST .../search), not only
# where a local postgres MCP server runs. AI Search embeds the QUERY server-side, which
# the model on web, phone or a cloud routine cannot do for itself.
#
# This file declares the instance only. Its CONTENT is data and never enters the repo:
# managed upload-only storage (no `source`/`type`, measured 2026-11-19 with a throwaway
# instance), filled through the items API by the operator's export, the rag plugin and
# the ircc-whatsapp-bot. Rejected: an R2 bucket source (a second store to keep in step
# with the items, for no gain at this size) and Supabase (pauses after a week idle, no
# server-side query embedding path from its connector).
#
# PRIVATE: the public endpoint (and its MCP and chat routes) stays OFF. The only callers
# are bearers of a Cloudflare token with AI Search access: the operator's claude.ai
# connector grant and the `cf:cloudflare.com:ai-search` Keychain token.
#
# Billing (developers.cloudflare.com/ai-search/platform/limits-pricing/, updated
# 2026-11-17; billing starts 2026-12-01): every account gets 5 M ingestion tokens,
# 10 GB-month, 1,000 semantic and 1,000 full-text queries a month; then $0.75 per 1,000
# semantic queries. The corpus is ~5.85 M characters (~1.5 M tokens, measured).
{ accountId, ... }:
{
  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = "= ${(import ../provider-pins.nix).cloudflare}";
  };

  resource.cloudflare_ai_search_instance.rag = {
    account_id = accountId;
    id = "rag";
    # Pinned instead of the default, so a default change upstream cannot silently
    # re-embed the corpus. 1024 dimensions (measured on the throwaway instance).
    embedding_model = "@cf/qwen/qwen3-embedding-0.6b";
    # Hybrid: IRCC answers hinge on exact program names and form numbers, where BM25
    # beats a vector alone. The provider defaults to vector-only, the API to both.
    index_method = {
      vector = true;
      keyword = true;
    };
    # The five filterable fields (the API's maximum). Every item carries `corpus`
    # (ircc | ircc-live | repo | web | misc) so one corpus can be searched alone.
    custom_metadata =
      map
        (f: {
          field_name = f;
          data_type = "text";
        })
        [
          "corpus"
          "source"
          "url"
          "repo"
          "title"
        ];
    # OFF, and flipping `enabled` alone would expose search, chat AND the MCP endpoint at
    # once (their own flags default to on): turn each sub-endpoint off before ever doing so.
    public_endpoint_params.enabled = false;
    # A REPLACE keeps the address, so the wrapper's drop guard (address-based) cannot see
    # it, and it would delete every item. Only `id`, `account_id` and `type` force one
    # (provider 5.25.0 schema). Never declare `hybrid_search_enabled` to quiet a diff: it
    # is RequiresReplaceIfConfigured (infra review 2026-11-19).
    lifecycle.prevent_destroy = true;
  };

  output.ai_search_instance.value = "\${cloudflare_ai_search_instance.rag.id}";
}
