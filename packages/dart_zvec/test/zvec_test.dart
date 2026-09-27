import 'dart:io';
import 'dart:typed_data';

import 'package:dart_zvec/dart_zvec.dart';
import 'package:test/test.dart';

void main() {
  test('builds, queries, and reopens a persistent HNSW collection', () {
    final directory = Directory.systemTemp.createTempSync('dart-zvec-test-');
    final path = '${directory.path}/vectors';
    try {
      expect(Zvec.version, 'v0.7.0');
      final collection = ZvecCollection.create(path, dimensions: 4);
      collection.insert([
        ZvecRecord('port', Float32List.fromList([1, 0, 0, 0])),
        ZvecRecord('appendix', Float32List.fromList([0, 1, 0, 0])),
        ZvecRecord('heart', Float32List.fromList([0, 0, 1, 0])),
      ]);
      collection.optimize();
      expect(
        collection
            .search(Float32List.fromList([1, 0, 0, 0]), limit: 2)
            .first
            .id,
        'port',
      );
      collection.close();

      final reopened = ZvecCollection.open(path, dimensions: 4);
      expect(
        reopened.search(Float32List.fromList([1, 0, 0, 0])).first.id,
        'port',
      );
      expect(
        () => reopened.search(Float32List.fromList([1, 0])),
        throwsArgumentError,
      );
      reopened.close();
    } finally {
      Zvec.shutdown();
      directory.deleteSync(recursive: true);
    }
  });
}
