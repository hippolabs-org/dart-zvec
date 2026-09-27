import 'dart:io';
import 'dart:typed_data';

import 'package:dart_zvec/dart_zvec.dart';
import 'package:test/test.dart';

void main() {
  test('two read-only handles share a persisted collection', () {
    final directory = Directory.systemTemp.createTempSync('dart-zvec-readers-');
    final path = '${directory.path}/vectors';
    ZvecCollection? first;
    ZvecCollection? second;
    try {
      final writer = ZvecCollection.create(path, dimensions: 2);
      writer.insert([
        ZvecRecord('cholera', Float32List.fromList([1, 0])),
      ]);
      writer.optimize();
      writer.close();

      first = ZvecCollection.open(path, dimensions: 2, readOnly: true);
      second = ZvecCollection.open(path, dimensions: 2, readOnly: true);
      expect(first.search(Float32List.fromList([1, 0])).first.id, 'cholera');
      expect(second.search(Float32List.fromList([1, 0])).first.id, 'cholera');
    } finally {
      second?.close();
      first?.close();
      Zvec.shutdown();
      directory.deleteSync(recursive: true);
    }
  });
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
