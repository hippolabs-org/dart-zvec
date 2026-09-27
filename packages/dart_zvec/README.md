# dart_zvec

A pure Dart package for persistent [Zvec](https://github.com/alibaba/zvec) HNSW vector collections. It uses the Zvec v0.7.0 C API through generated `dart:ffi` bindings and a Dart native asset build hook. Flutter is not required.

```dart
import 'dart:typed_data';
import 'package:dart_zvec/dart_zvec.dart';

void main() {
  final vectors = ZvecCollection.create('/path/to/vectors', dimensions: 3);
  try {
    vectors.insert([
      ZvecRecord('port', Float32List.fromList([1, 0, 0])),
      ZvecRecord('ultrasound', Float32List.fromList([0, 1, 0])),
    ]);
    vectors.optimize();
    final hits = vectors.search(Float32List.fromList([0.9, 0.1, 0]));
    for (final hit in hits) {
      print('${hit.id}: ${hit.score}');
    }
  } finally {
    vectors.close();
    Zvec.shutdown();
  }
}
```

The package supports macOS arm64, Linux x64/arm64, and Windows x64. The first native build downloads the corresponding upstream release archive from GitHub and verifies its pinned SHA-256 digest. The library is bundled into the compiled Dart application by native assets. The host needs network access for its first build.

This package stores and searches vectors; it does not create embeddings. Keep document or catalog metadata in its authoritative store and use Zvec IDs to join search candidates back to that store.

The included C header is from Zvec v0.7.0 and is licensed under Apache-2.0. See `THIRD_PARTY_NOTICES.md`.
