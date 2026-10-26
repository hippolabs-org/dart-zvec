# dart_zvec

A pure Dart package for persistent [Zvec](https://github.com/alibaba/zvec) HNSW vector and BM25 full-text collections. It uses the Zvec v0.7.0 C API through generated `dart:ffi` bindings and a Dart native asset build hook. Flutter is not required.

```dart
import 'dart:typed_data';
import 'package:dart_zvec/dart_zvec.dart';

void main() {
  final vectors = ZvecCollection.create(
    '/path/to/vectors',
    dimensions: 3,
    metric: ZvecMetric.cosine,
    scalarFields: {'tenant': ZvecScalarType.string},
  );
  try {
    vectors.upsert([
      ZvecRecord('port', Float32List.fromList([1, 0, 0]),
          fields: {'tenant': ZvecString('demo')}),
      ZvecRecord('ultrasound', Float32List.fromList([0, 1, 0])),
    ]);
    vectors.flush();
    vectors.optimize();
    final hits = vectors.search(Float32List.fromList([0.9, 0.1, 0]));
    for (final hit in hits) {
      print('${hit.id}: ${hit.score}');
    }
  } finally {
    vectors.close();
    // Only call Zvec.shutdown() after all process-wide users have finished.
  }
}
```

The package supports macOS arm64, Linux x64/arm64, and Windows x64. The first native build downloads the corresponding upstream release archive from GitHub and verifies its pinned SHA-256 digest. The library is bundled into the compiled Dart application by native assets. The host needs network access for its first build.

This package stores vectors, searchable text and flat scalar metadata; it does
not create embeddings. Keep authoritative documents and authorization policy in the consumer.

## Storage API and guarantees

Declare nullable scalar fields at collection creation with `ZvecScalarType.string`,
`number` (finite double), or `boolean`; write `ZvecString`, `ZvecNumber` and
`ZvecBool` values. The schema is fixed and loaded on reopen. Omitted values are
absent; upsert replaces the entire record, including metadata.

Use `fetch(ids)`, `delete(ids)`, `deleteWhere(expression)` and `flush()` for storage
operations. Empty ID lists are no-ops. Batches are validated before submission,
but native write failures may leave partial effects; there is no transaction
across documents. `flush()` explicitly flushes native storage. `close()` releases
the handle and is idempotent. It does not shut down the process-wide engine.

`search(vector, filter: expression, exact: true)` uses the native expression
language and exact linear search through HNSW query parameters. Expressions are
raw backend syntax, so callers must validate/encode untrusted values. The
`dart_vector_zvec` adapter provides typed portable filters. Search hits include
scalar values. Native scores retain their original meaning:

| Metric | Score | Ordering |
| --- | --- | --- |
| cosine | cosine distance | ascending |
| euclidean | squared Euclidean distance | ascending |
| innerProduct | dot product | descending |

Open with the same dimensions, field name and metric used at creation; mismatches
are rejected and release the native handle. `readOnly: true` remains supported.
All operations are synchronous; dedicate an isolate to substantial workloads and
keep handle ownership within that isolate. Call `Zvec.shutdown()` only after all
collections and other process-wide users have finished.

## Full-text search

Create a text-only collection by omitting `dimensions`. Text fields belong in
`textIndexes`, separate from ordinary scalar fields, and contain raw Unicode
`ZvecString` values. No embedding or dummy vector is needed:

```dart
final documents = ZvecCollection.create(
  '/path/to/documents',
  scalarFields: {'scope': ZvecScalarType.string},
  textIndexes: {
    'content': ZvecTextIndex(
      tokenizer: const ZvecStandardTokenizer(),
      filters: [ZvecTokenFilter.lowercase, ZvecTokenFilter.stemmer],
      stemmerLanguage: 'english',
      nullable: false,
    ),
  },
);
try {
  documents.upsert([
    ZvecRecord.text('file-1:chunk-0', fields: {
      'scope': ZvecString('demo'),
      'content': ZvecString('Persistent vector and full-text search.'),
    }),
  ]);
  documents.flush();
  documents.optimize();
  final hits = documents.searchText(
    'content',
    const ZvecTextMatch('persistent search', operator: ZvecTextOperator.and),
    filter: "scope = 'demo'",
  );
  print(hits.first.id);
} finally {
  documents.close();
}
```

`ZvecTextMatch` treats the input as plain text. `ZvecTextExpression` explicitly
opts into native boolean/phrase syntax, for example
`ZvecTextExpression('"vector search" AND persistent')`. They are separate types,
so a query cannot accidentally supply both modes. The default operator is OR.
Empty/whitespace-only queries are rejected. A nonempty query with no matches
returns an empty list. BM25 scores are returned unchanged, **higher first**;
they are not comparable to vector distances or probabilities.

Filters remain native scalar expressions, just as in vector search. Derive scope
from trusted authorization and encode untrusted filter values in the calling
layer. This package does not implement application ACLs or a portable filter DSL.

Supported typed tokenizers are standard (Unicode word boundaries with configurable
maximum token length), whitespace, ngram (minimum/maximum length and character
classes), and Jieba (dictionary paths and cut mode). Token filters are ordered:
lowercase, ASCII folding and Snowball stemming. `stemmerLanguage` names a native
Snowball algorithm such as `english`, `german` or `porter`; unsupported algorithms
are reported by the engine. Jieba dictionaries must be supplied by the application
or native configuration; they are not bundled here. Empty `filters: []` disables
token filters. Invalid numeric settings are rejected before native calls.

Text index configuration is immutable. `textIndexes` on an open collection exposes
the persisted settings. Pass `textIndexes: expectedSettings` to `open()` to reject
schema mismatches (including tokenizer, filters and nullability). Rebuild into a
new collection to change the analyzer configuration. `scalarFields` includes the
STRING fields backing text indexes. Missing nullable text fields are allowed;
required text fields are validated before a batch is submitted.

### Combining text and vectors

Supply both `dimensions` and `textIndexes` at creation to use both query modes on
one collection. Every record in that collection must have a vector. `searchText`
and `search` execute independent ranking routes; combine their results in your
retrieval layer. This package does not perform rank fusion or generate embeddings.

For files awaiting embeddings, use a text-only collection and build a separate
vector projection when ready. Zvec v0.7.0 exact vector search can return rows with
null embeddings, so this release deliberately rejects nullable-vector schemas
instead of returning misleading vector results. This does not restrict text-only
collections. Text-only collections use the same flush, fetch, replacement,
delete, optimize, close and read-only APIs.

### Migrating from 0.1.x

Existing vector constructor calls and persisted required-vector collections still
work. `ZvecRecord.embedding` is now `Float32List?`, and collection `dimensions` is
`int?`; both are null for text-only data. Consumers reading these properties must
handle null or explicitly assert their required-vector invariant. `ZvecRecord.text`
constructs a record without a vector. Do not use an empty/zero vector as a stand-in.
When opening a vector collection, continue supplying its dimensions, field name
and metric; omit dimensions only for text-only collections.

## Development

From the workspace root, run `dart run melos run ci`. Native tests cover all
metrics, scalar round trips, BM25 ranking, scope filters, phrase queries,
Unicode/stemming, replacement, deletion, reopen and read-only collections.
Regenerate bindings from the pinned header after editing `tool/ffigen.yaml`:

```sh
cd packages/dart_zvec
dart run ffigen --config tool/ffigen.yaml
```

Do not edit generated `lib/src/bindings.dart` directly.

The included C header is from Zvec v0.7.0 and is licensed under Apache-2.0. See `THIRD_PARTY_NOTICES.md`.
