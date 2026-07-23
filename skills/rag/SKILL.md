---
name: rag
description: >-
  Do retrieval-augmented generation over the local pgvector store. Use when the
  user wants to ingest documents/text into a searchable knowledge base, or ask
  questions answered from that stored corpus ("index this", "add to my notes DB",
  "what do my docs say about X", "search my knowledge base", "RAG over these
  files"). Runs entirely local via the `postgres` MCP server + in-DB embeddings
  (Ollama); no API keys, nothing leaves the machine.
---

# Local RAG over pgvector

Everything runs through the **`postgres` MCP server** as plain SQL against database
`ragdb`. Embeddings are generated **inside Postgres** by `embed(text)`, which calls a
local Ollama model — so you never compute or handle vectors yourself. Nothing leaves
the machine.

## The store (already provisioned)

- Table **`docs`**: `id bigserial`, `content text`, `metadata jsonb`, `embedding vector(768)`.
- Function **`embed(text) -> vector`**: returns the embedding of the text via local Ollama
  (`nomic-embed-text`, 768-dim). Call it inline in SQL; it's the only interface you need.
- An **HNSW cosine index** on `embedding` — always order by the cosine operator `<=>` so the
  index is used.

You do **not** create the table or the function — they exist. Just use them.

## Ingesting content

1. **Get the text.** For files/URLs, extract text first with the right tool — the `fetch`
   MCP server (web pages), the `pdf` / `docx` / `pptx` / `xlsx` skills (documents), or
   `desktop-commander` (local files).
2. **Chunk it.** Split into ~500–1000 character passages on paragraph/sentence boundaries,
   with a little overlap. One row per chunk. Embedding quality degrades on very long text,
   so don't insert whole documents as a single row.
3. **Insert**, embedding inline. Parameterize the text (never string-concatenate user text
   into SQL):

   ```sql
   INSERT INTO docs (content, metadata, embedding)
   VALUES ($1, $2::jsonb, embed($1));
   ```

   Put source/title/section/chunk-index in `metadata` so you can cite and filter later, e.g.
   `{"source":"handbook.pdf","section":"Leave policy","chunk":3}`.

## Querying (retrieval + answer)

1. **Retrieve** the top matches, embedding the question inline. Report similarity as
   `1 - (embedding <=> embed($1))` (cosine similarity, 1.0 = identical):

   ```sql
   SELECT content,
          metadata,
          1 - (embedding <=> embed($1)) AS similarity
   FROM docs
   ORDER BY embedding <=> embed($1)
   LIMIT 8;
   ```

   To scope a query, add a `metadata` filter (e.g. `WHERE metadata->>'source' = $2`) BEFORE
   the `ORDER BY`.
2. **Synthesize** the answer from the retrieved `content` only, and **cite** each claim from
   `metadata`. If the top similarities are all low (say < ~0.3), say the corpus doesn't cover
   it rather than guessing — don't fall back to general knowledge and present it as retrieved.

## Notes & gotchas

- **Same model both sides.** `embed()` uses one fixed model, so ingest and query embeddings
  are always comparable. Don't introduce a second embedding path.
- **Dimension is fixed at 768.** If `embed()` errors, Ollama or its model may still be
  starting/pulling on first boot — the `nomic-embed-text` model is fetched once in the
  background; retry shortly. A dimension-mismatch error means the model changed; re-embed.
- **Keep it read-mostly.** Inserts/updates are fine; avoid schema changes — the table and
  index are managed declaratively (modules/shared/postgres-pgvector.nix).
- **Reset a corpus** with `TRUNCATE docs;` (or delete by `metadata->>'source'`) before
  re-ingesting a changed document, so you don't accumulate stale chunks.
