## 0.3.0

- Bind Zvec v0.8.0. The bound C API is unchanged; the header drops only the
  unused global Jieba dictionary accessors, and `ZvecJiebaTokenizer` keeps
  configuring dictionaries per field.
- Add macOS x64 and Windows arm64 native assets.
- Zvec v0.8.0 fixes FTS persistence and recovery, crashes and missing rows when
  reads race with a segment switch or flush, and filtered retrieval. It also
  speeds up quantized and HNSW search. Rebuild persisted collections where
  results must match a fresh build.

## 0.2.0

- Add BM25 full-text search with typed tokenizer/index settings, plain-text match
  and advanced boolean/phrase queries, AND/OR operators and scalar filtering.
- Add text-only collections and records without embeddings, alongside combined
  collections containing both text and required vectors.
- Load FTS schemas on reopen and optionally validate expected index settings.
- Generate FTS bindings from the pinned v0.7.0 header with explicit native
  ownership and error cleanup.
- Cover ranking, scope filters, mutation/deletion, persistence, read-only access,
  Unicode, English/German stemming and combined vector/text queries in native tests.
- **Breaking:** `ZvecRecord.embedding` and `ZvecCollection.dimensions` are nullable
  to represent text-only data. Vector callers must check/narrow nullable values.
  Existing required-vector collections retain their storage format and behavior.
- Nullable-vector schemas from other clients are rejected on open because native
  exact search can return rows without embeddings. Use a text-only collection
  for documents awaiting embeddings.

- Add Euclidean and inner-product metrics, explicit scalar schemas, typed scalar
  values, upsert, fetch, deletion, flush and filtered/exact search.
- Validate persisted vector configuration on open and load scalar schemas.
- Make default initialization idempotent across concurrent isolates.
- Regenerate bindings for storage operations and ownership-safe query parameters.

## 0.1.1

- Add read-only collection opens so independent readers can share a persisted
  vector index without taking an exclusive writer lock.

## 0.1.0

- Add pure Dart Zvec v0.7.0 bindings for persistent cosine HNSW collections.
- Add a checksum-verified native asset hook for macOS arm64, Linux x64/arm64, and Windows x64.
- Add a runnable Dart CLI example and native smoke test.
