# dart_zvec

A pure Dart package for persistent [Zvec](https://github.com/alibaba/zvec) HNSW vector collections. It uses the Zvec v0.7.0 C API through generated `dart:ffi` bindings and a Dart native asset build hook. Flutter is not required.

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

This package stores vectors and flat scalar metadata; it does not create
embeddings. Keep authoritative documents and authorization policy in the consumer.

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

## Development

From the workspace root, run `dart run melos run ci`. Native tests cover all
metrics, scalar round trips, filter failures, replacement, deletion and reopen.
Regenerate bindings from the pinned header after editing `tool/ffigen.yaml`:

```sh
cd packages/dart_zvec
dart run ffigen --config tool/ffigen.yaml
```

Do not edit generated `lib/src/bindings.dart` directly.

The included C header is from Zvec v0.7.0 and is licensed under Apache-2.0. See `THIRD_PARTY_NOTICES.md`.
